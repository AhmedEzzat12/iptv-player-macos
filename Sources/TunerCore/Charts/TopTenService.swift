import Foundation
import os

/// Streams a Netflix Top 10 file into a parser until the parser has its week (`.notModified` for a 304). Injected so
/// tests can serve fixture lines.
typealias NetflixLinesFetch = @Sendable (_ url: String, _ ifModifiedSince: String?, _ parser: NetflixTop10.LatestWeekParser,
                                         _ allowExpensiveNetwork: Bool) async throws -> NetflixLinesResult

enum NetflixLinesResult: Sendable {
    case notModified
    case parsed(NetflixTop10.LatestWeekParser, lastModified: String?)
}

/// Home's "Top 10 Movies" / "Top 10 TV Shows": public popularity charts matched against the library.
///
/// - Sources, best first (`TopTenRegion.chain`): Netflix's weekly Top 10 for a country, Netflix worldwide, then TMDB
///   trending (only with the user's own key) and Cinemeta's popular lists. Each row uses the first source that matches
///   at least `TopTenMatcher.minimumMatches` library titles; with none, the row is hidden.
/// - Caching: charts are stored in SQLite and reused offline. Netflix lists change weekly (published on Tuesdays), so a
///   Netflix file is only fetched again once the next week's list can exist (then at most every 12 hours, with
///   If-Modified-Since); the live lists at most every 6 hours. A failed fetch isn't retried for an hour.
/// - Only public chart files are requested; nothing about the library leaves the device. The big per-country file is
///   only read on unmetered networks (Low Data Mode and cellular fall back to the global list).
/// - Logs name the source and status codes, never URLs.
public actor TopTenService {
    public struct Settings: Sendable, Hashable {
        public var region: TopTenRegion
        /// The device's region (ISO code), for `.automatic`.
        public var deviceRegion: String?
        public var tmdbAPIKey: String?
        public var language: String
        public var hideAdultContent: Bool
        /// Use cached charts only.
        public var offline: Bool

        public init(region: TopTenRegion, deviceRegion: String?, tmdbAPIKey: String?, language: String,
                    hideAdultContent: Bool, offline: Bool) {
            self.region = region
            self.deviceRegion = deviceRegion
            self.tmdbAPIKey = tmdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.language = language
            self.hideAdultContent = hideAdultContent
            self.offline = offline
        }
    }

    /// One row: the chart it follows and the matched library items, in chart order.
    public struct Row<Item: Sendable & Hashable>: Sendable, Hashable {
        public var source: ChartSource
        public var week: String?
        public var items: [Item]
    }

    public struct Rows: Sendable, Hashable {
        public var movies: Row<Movie>?
        public var series: Row<Series>?

        public init(movies: Row<Movie>? = nil, series: Row<Series>? = nil) {
            self.movies = movies
            self.series = series
        }
    }

    static let log = Logger(subsystem: "app.tuner.macos", category: "TopTen")
    static let liveListInterval: TimeInterval = 6 * 3600
    static let netflixRetryInterval: TimeInterval = 12 * 3600
    /// The next Netflix week is published on the Tuesday after it ends (around 19:00 UTC): 9 days after the Sunday
    /// that ends the current one.
    static let netflixNextWeekDelay: TimeInterval = 9 * 86_400 + 18 * 3600
    /// A Netflix list older than this is no longer "this week" (a country Netflix stopped publishing).
    static let netflixMaxAge: TimeInterval = 35 * 86_400
    static let failureBackoff: TimeInterval = 3600

    let db: AppDatabase
    let fetchJSON: MetadataFetch
    let fetchLines: NetflixLinesFetch
    let now: @Sendable () -> Date
    private var cache: [ChartSource: CachedChart] = [:]
    private var failures: [ChartSource: Date] = [:]
    private var inFlight: [ChartSource: Task<CachedChart?, Never>] = [:]

    public init(db: AppDatabase) {
        self.init(db: db, fetchJSON: MetadataHTTP.live(), fetchLines: Self.liveNetflixLines())
    }

    /// Test seam.
    init(db: AppDatabase, fetchJSON: @escaping MetadataFetch, fetchLines: @escaping NetflixLinesFetch,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.fetchJSON = fetchJSON
        self.fetchLines = fetchLines
        self.now = now
    }

    /// The rows to show (each nil when no source matches enough of the library).
    public func rows(_ settings: Settings) async -> Rows {
        let chain = settings.region.chain(deviceRegion: settings.deviceRegion, hasTMDBKey: settings.tmdbAPIKey != nil)
        let usage = (try? await db.watchCountsBySource()) ?? [:]
        var rows = Rows()
        for kind in [MediaMetadata.Kind.movie, .series] {
            for source in chain {
                guard let chart = await chart(source, settings: settings), isCurrent(chart) else { continue }
                let entries = chart.entries(kind)
                guard entries.count >= TopTenMatcher.minimumMatches else { continue }
                let ids = await match(entries, kind: kind, hideAdult: settings.hideAdultContent, usage: usage)
                guard ids.count >= TopTenMatcher.minimumMatches else { continue }
                if kind == .movie {
                    var items: [Movie] = []
                    for id in ids { if let m = try? await db.movie(id: id) { items.append(m) } }
                    guard items.count >= TopTenMatcher.minimumMatches else { continue }
                    rows.movies = Row(source: source, week: chart.week, items: items)
                } else {
                    var items: [Series] = []
                    for id in ids { if let s = try? await db.series(id: id) { items.append(s) } }
                    guard items.count >= TopTenMatcher.minimumMatches else { continue }
                    rows.series = Row(source: source, week: chart.week, items: items)
                }
                break
            }
        }
        return rows
    }

    // MARK: - Matching

    func match(_ entries: [ChartEntry], kind: MediaMetadata.Kind, hideAdult: Bool, usage: [String: Int]) async -> [String] {
        let words = entries.flatMap { [$0.title, $0.originalTitle].compactMap { $0 } }.compactMap { TopTenMatcher.searchWord($0, kind: kind) }
        let candidates = (try? await db.topTenCandidates(kind: kind, words: words, imdbIds: entries.compactMap(\.imdbId),
                                                         tmdbIds: entries.compactMap(\.tmdbId), hideAdult: hideAdult)) ?? []
        return TopTenMatcher.match(entries, kind: kind, candidates: candidates, sourceUsage: usage)
    }

    // MARK: - Charts

    func isCurrent(_ chart: PopularityChart) -> Bool {
        guard chart.source.isNetflix else { return true }
        guard let end = NetflixTop10.weekEnd(chart.week) else { return false }
        return now().timeIntervalSince(end) < Self.netflixMaxAge
    }

    /// When a cached chart should next be checked for a newer list.
    func nextCheck(_ cached: CachedChart) -> Date {
        guard cached.chart.source.isNetflix else { return cached.checkedAt.addingTimeInterval(Self.liveListInterval) }
        let retry = cached.checkedAt.addingTimeInterval(Self.netflixRetryInterval)
        guard let end = NetflixTop10.weekEnd(cached.chart.week) else { return retry }
        return max(retry, end.addingTimeInterval(Self.netflixNextWeekDelay))
    }

    /// The cached chart, refreshed first when a newer one can exist (and the network may be used).
    func chart(_ source: ChartSource, settings: Settings) async -> PopularityChart? {
        if cache[source] == nil, let stored = try? await db.cachedChart(source) { cache[source] = stored }
        let cached = cache[source]
        if let cached, now() < nextCheck(cached) { return cached.chart }
        if settings.offline { return cached?.chart }
        if let failed = failures[source], now().timeIntervalSince(failed) < Self.failureBackoff { return cached?.chart }
        if let running = inFlight[source] { return await running.value?.chart ?? cached?.chart }
        let task = Task { await self.refresh(source, cached: cached, settings: settings) }
        inFlight[source] = task
        let result = await task.value
        inFlight[source] = nil
        return result?.chart ?? cached?.chart
    }

    private func refresh(_ source: ChartSource, cached: CachedChart?, settings: Settings) async -> CachedChart? {
        let started = now()
        do {
            var fresh: CachedChart
            switch source {
            case .netflixCountry, .netflixGlobal:
                let country: String? = if case .netflixCountry(let code) = source { code } else { nil }
                let url = country == nil ? NetflixTop10.globalURL : NetflixTop10.countriesURL
                let result = try await fetchLines(url, cached?.lastModified, NetflixTop10.LatestWeekParser(country: country), country == nil)
                switch result {
                case .notModified:
                    guard var cached else { throw HTTPError.emptyBody }
                    cached.checkedAt = started
                    try? await db.touchChart(source, at: started)
                    cache[source] = cached
                    Self.log.info("Top 10: \(Self.name(source), privacy: .public) unchanged (304)")
                    return cached
                case .parsed(let parser, let lastModified):
                    guard let chart = parser.chart() else { throw HTTPError.invalidJSON(nil) }
                    fresh = CachedChart(chart: chart, lastModified: lastModified, checkedAt: started)
                }
            case .cinemetaPopular:
                let client = CinemetaClient(fetch: fetchJSON)
                async let movies = client.popular(kind: .movie)
                async let series = client.popular(kind: .series)
                fresh = CachedChart(chart: PopularityChart(source: source, movies: try await movies, series: try await series),
                                    checkedAt: started)
            case .tmdbTrending:
                guard let client = TMDBClient(key: settings.tmdbAPIKey, language: settings.language, fetch: fetchJSON) else { return cached }
                async let movies = client.trending(kind: .movie)
                async let series = client.trending(kind: .series)
                fresh = CachedChart(chart: PopularityChart(source: source, movies: try await movies, series: try await series),
                                    checkedAt: started)
            }
            failures[source] = nil
            try? await db.saveChart(fresh)
            cache[source] = fresh
            Self.log.info("Top 10: \(Self.name(source), privacy: .public) \(fresh.chart.week ?? "now", privacy: .public) — \(fresh.chart.movies.count) movies, \(fresh.chart.series.count) shows")
            return fresh
        } catch {
            failures[source] = now()
            Self.log.error("Top 10: \(Self.name(source), privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            return cached
        }
    }

    static func name(_ source: ChartSource) -> String {
        switch source {
        case .netflixCountry(let code): "Netflix \(code)"
        case .netflixGlobal: "Netflix global"
        case .tmdbTrending: "TMDB trending"
        case .cinemetaPopular: "Cinemeta popular"
        }
    }

    /// Status code or error code only (TMDB v3 keys travel in URLs).
    static func describe(_ error: Error) -> String {
        switch error {
        case HTTPError.status(let code, _): "HTTP \(code)"
        case let error as URLError: "URLError \(error.code.rawValue)"
        case HTTPError.emptyBody: "empty response"
        case HTTPError.invalidJSON: "unexpected data"
        default: String(describing: type(of: error))
        }
    }

    // MARK: - Live Netflix fetcher

    /// Streams the file and stops reading as soon as the parser has its week (the rest is never downloaded).
    static func liveNetflixLines(session: URLSession = .tunerShared) -> NetflixLinesFetch {
        { url, ifModifiedSince, parser, allowExpensiveNetwork in
            guard let u = URL(string: url) else { throw HTTPError.badURL(url) }
            var request = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue(MetadataHTTP.userAgent, forHTTPHeaderField: "User-Agent")
            if let ifModifiedSince { request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since") }
            request.allowsExpensiveNetworkAccess = allowExpensiveNetwork
            request.allowsConstrainedNetworkAccess = allowExpensiveNetwork
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            if (response as? HTTPURLResponse)?.statusCode == 304 { return .notModified }
            try HTTPClient.check(response, url: url)
            var parser = parser
            for try await line in bytes.lines {
                if !parser.consume(line) { break }
            }
            return .parsed(parser, lastModified: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified"))
        }
    }
}

extension TopTenMatcher {
    /// The most distinctive word of a chart title, used to pick library items worth comparing (`name LIKE %word%`).
    static func searchWord(_ title: String, kind: MediaMetadata.Kind) -> String? {
        let cleaned = TitleMatcher.query(name: title, kind: kind)?.title ?? title
        let words = cleaned.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        let meaningful = words.filter { !stopWords.contains($0.lowercased()) }
        return (meaningful.isEmpty ? words : meaningful).max { $0.count < $1.count }
    }

    static let stopWords: Set<String> = ["the", "a", "an", "of", "and", "in", "on", "to", "for", "with", "la", "le", "el", "al"]
}
