import Foundation
import os

/// Intro/recap/credits timings from the public crowd-sourced databases, cached per movie/episode in SQLite.
///
/// - TheIntroDB (`https://api.theintrodb.org/v4/media`, by IMDb or TMDB id + season/episode) and IntroDB
///   (`https://api.introdb.app/segments`, by IMDb id + season/episode) are asked together, without keys. Both answer
///   anonymous reads (TheIntroDB: 30 requests per 10 s and 5,000 a day per IP).
/// - Only the title's id and the season/episode numbers are sent. Nothing about the provider or the library.
/// - Results, including "not found", are cached (`skipSegmentCache`, migration `v8-skipSegments`): found for 30 days,
///   not found for 7. A network failure caches nothing, so the next playback asks again; offline the cache is used.
/// - Timings are kept as the databases give them; `SkipSegments.merge` checks them against the playing file.
/// - Logs name the database and status codes, never URLs.
public actor SkipSegmentService {
    /// What to look up: the provider's movie/episode id (the cache key) and the title's public ids.
    public struct Lookup: Sendable, Hashable {
        public var mediaId: String
        public var imdbId: String?
        public var tmdbId: String?
        /// nil for movies.
        public var season: Int?
        public var episode: Int?

        public init(mediaId: String, imdbId: String?, tmdbId: String?, season: Int? = nil, episode: Int? = nil) {
            self.mediaId = mediaId
            self.imdbId = imdbId.flatMap(SkipSegmentService.validIMDbId)
            self.tmdbId = tmdbId.flatMap { $0.allSatisfy(\.isNumber) && !$0.isEmpty && $0 != "0" ? $0 : nil }
            self.season = season
            self.episode = episode
        }

        var isEpisode: Bool { season != nil && episode != nil }
        var canLookUp: Bool { imdbId != nil || tmdbId != nil }
    }

    public static let foundTTL: TimeInterval = 30 * 86_400
    public static let notFoundTTL: TimeInterval = 7 * 86_400
    /// Online lookups never hold anything up for long.
    static let timeout: TimeInterval = 8

    static let log = Logger(subsystem: "app.tuner.macos", category: "SkipSegments")

    let db: AppDatabase
    let fetch: MetadataFetch
    let now: @Sendable () -> Date
    private var inFlight: [String: Task<[SkipSegment], Never>] = [:]

    public init(db: AppDatabase) {
        self.init(db: db, fetch: Self.liveFetch())
    }

    /// Test seam.
    init(db: AppDatabase, fetch: @escaping MetadataFetch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.fetch = fetch
        self.now = now
    }

    /// One attempt, short timeout: a slow database just means no button this time.
    static func liveFetch() -> MetadataFetch {
        let http = HTTPClient(userAgent: MetadataHTTP.userAgent, timeout: timeout)
        return { url, headers in
            let data = try await http.data(from: url, headers: headers.merging(["Accept": "application/json"]) { a, _ in a },
                                           retries: 0)
            guard let object = JSONObject(HTTPClient.parseJSONLeniently(data)) else {
                throw HTTPError.invalidJSON(HTTPClient.preview(of: data))
            }
            return object
        }
    }

    // MARK: Online timings

    /// Cached or freshly fetched timings for a title (raw, unsanitised, from both databases). With `allowNetwork`
    /// false (offline, or online lookups turned off) only the cache is read, stale or not.
    public func segments(for lookup: Lookup, allowNetwork: Bool) async -> [SkipSegment] {
        let cached = try? await db.skipSegmentCache(mediaId: lookup.mediaId)
        if let cached, !allowNetwork || cached.isFresh(at: now(), foundTTL: Self.foundTTL, notFoundTTL: Self.notFoundTTL) {
            return cached.segments
        }
        guard allowNetwork, lookup.canLookUp else { return cached?.segments ?? [] }
        if let task = inFlight[lookup.mediaId] { return await task.value }
        let task = Task { await self.fetchAndCache(lookup, fallback: cached?.segments ?? []) }
        inFlight[lookup.mediaId] = task
        let result = await task.value
        inFlight[lookup.mediaId] = nil
        return result
    }

    private func fetchAndCache(_ lookup: Lookup, fallback: [SkipSegment]) async -> [SkipSegment] {
        async let theIntroDB = query(.theIntroDB, url: Self.theIntroDBURL(lookup))
        async let introDB = query(.introDB, url: Self.introDBURL(lookup))
        let results = await [theIntroDB, introDB]
        let segments = results.flatMap { $0.segments }
        let failed = results.contains { $0.failed }
        // A failure caches nothing unless the other database answered with timings.
        if failed, segments.isEmpty { return fallback }
        try? await db.saveSkipSegments(segments, mediaId: lookup.mediaId, at: now())
        return segments
    }

    private struct QueryResult {
        var segments: [SkipSegment] = []
        var failed = false
    }

    private func query(_ source: SkipSegment.Source, url: String?) async -> QueryResult {
        guard let url else { return QueryResult() }
        do {
            let json = try await fetch(url, [:])
            let segments = source == .theIntroDB ? Self.parseTheIntroDB(json) : Self.parseIntroDB(json)
            Self.log.info("\(source.rawValue, privacy: .public): \(segments.count, privacy: .public) segments")
            return QueryResult(segments: segments)
        } catch {
            if case HTTPError.status(let code, _) = error {
                // 404: the database doesn't know the title or episode ("not found", cached).
                if code == 404 { return QueryResult() }
                Self.log.notice("\(source.rawValue, privacy: .public): HTTP \(code, privacy: .public)")
            } else {
                Self.log.notice("\(source.rawValue, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
            }
            return QueryResult(failed: true)
        }
    }

    // MARK: Requests

    static func validIMDbId(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.range(of: #"^tt\d{7,8}$"#, options: .regularExpression) != nil ? trimmed : nil
    }

    /// `GET https://api.theintrodb.org/v4/media?imdb_id=…[&season=…&episode=…]` (TMDB id when there's no IMDb id).
    static func theIntroDBURL(_ lookup: Lookup) -> String? {
        var items: [URLQueryItem]
        if let imdb = lookup.imdbId {
            items = [URLQueryItem(name: "imdb_id", value: imdb)]
        } else if let tmdb = lookup.tmdbId {
            items = [URLQueryItem(name: "tmdb_id", value: tmdb)]
        } else {
            return nil
        }
        if lookup.isEpisode, let season = lookup.season, let episode = lookup.episode {
            items += [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "episode", value: String(episode))]
        }
        var comps = URLComponents(string: "https://api.theintrodb.org/v4/media")
        comps?.queryItems = items
        return comps?.string
    }

    /// `GET https://api.introdb.app/segments?imdb_id=…&season=…&episode=…` or `…&is_movie=true` (IMDb ids only).
    static func introDBURL(_ lookup: Lookup) -> String? {
        guard let imdb = lookup.imdbId else { return nil }
        var items = [URLQueryItem(name: "imdb_id", value: imdb)]
        if lookup.isEpisode, let season = lookup.season, let episode = lookup.episode {
            items += [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "episode", value: String(episode))]
        } else {
            items.append(URLQueryItem(name: "is_movie", value: "true"))
        }
        var comps = URLComponents(string: "https://api.introdb.app/segments")
        comps?.queryItems = items
        return comps?.string
    }

    // MARK: Parsing

    /// TheIntroDB v4: `{"intro":[{"start_ms":null,"end_ms":46000}],"recap":[…],"credits":[{"start_ms":1359000,"end_ms":null}]}`.
    /// A null start means the very beginning, a null end the end of the media. Previews are ignored.
    static func parseTheIntroDB(_ json: JSONObject) -> [SkipSegment] {
        var out: [SkipSegment] = []
        for (key, kind) in [("recap", SkipSegment.Kind.recap), ("intro", .intro), ("credits", .credits)] {
            for entry in json.objects(key) {
                let start = entry.double("start_ms").map { $0 / 1000 } ?? 0
                let end = entry.double("end_ms").map { $0 / 1000 }
                out.append(SkipSegment(kind: kind, start: start, end: end, source: .theIntroDB))
            }
        }
        return out
    }

    /// IntroDB: `{"intro":{"start_ms":0,"end_ms":47000,…},"recap":null,"outro":{…},"no_intro":false,…}`; `outro` is
    /// the credits. Post-credits scenes are ignored.
    static func parseIntroDB(_ json: JSONObject) -> [SkipSegment] {
        var out: [SkipSegment] = []
        for (key, kind) in [("recap", SkipSegment.Kind.recap), ("intro", .intro), ("outro", .credits)] {
            guard let entry = json.object(key) else { continue }
            let start = entry.double("start_ms").map { $0 / 1000 } ?? entry.double("start_sec")
            let end = entry.double("end_ms").map { $0 / 1000 } ?? entry.double("end_sec")
            guard let start else { continue }
            out.append(SkipSegment(kind: kind, start: start, end: end, source: .introDB))
        }
        return out
    }

    // MARK: Learned intros

    /// The show's learned intro (see `SkipLearner`), if two episodes agree on one.
    public func learnedIntro(seriesId: String) async -> SkipSegment? {
        let spans = (try? await db.learnedSkipSpans(seriesId: seriesId)) ?? []
        return SkipLearner.suggestedIntro(from: spans)
    }

    /// Remembers a span the user skipped (or a learned intro they confirmed) in an episode.
    public func record(_ span: LearnedSkipSpan, seriesId: String) async {
        try? await db.saveLearnedSkipSpan(span, seriesId: seriesId, at: now())
    }
}
