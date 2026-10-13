import Foundation

/// Where a popularity chart comes from. Home's "Top 10" rows try these in order (`TopTenRegion.chain`).
public enum ChartSource: Sendable, Hashable, Codable {
    /// Netflix's weekly Top 10 for one country (ISO 3166 code, e.g. "EG").
    case netflixCountry(String)
    /// Netflix's weekly global Top 10 (English and non-English lists merged by views).
    case netflixGlobal
    /// TMDB's trending titles of the week (only with the user's own TMDB key).
    case tmdbTrending
    /// Cinemeta's (Stremio) "Popular" catalogues.
    case cinemetaPopular

    /// Row key in the `popularityChart` cache.
    var cacheKey: String {
        switch self {
        case .netflixCountry(let code): "netflix-\(code.uppercased())"
        case .netflixGlobal: "netflix-global"
        case .tmdbTrending: "tmdb-trending"
        case .cinemetaPopular: "cinemeta-popular"
        }
    }

    var isNetflix: Bool {
        switch self {
        case .netflixCountry, .netflixGlobal: true
        case .tmdbTrending, .cinemetaPopular: false
        }
    }
}

/// One title on a chart, as the source names it.
public struct ChartEntry: Sendable, Hashable, Codable {
    /// "Wednesday" (a show's name, never its season), "The Equalizer 3".
    public var title: String
    /// Original-language title when the source has one (TMDB), often the Arabic name of an Arabic title.
    public var originalTitle: String?
    /// Release year (first-air year for shows); Netflix's files have none.
    public var year: Int?
    public var imdbId: String?
    public var tmdbId: String?
    /// The source's own rank when it has one (Netflix's `weekly_rank` in a country list); otherwise the entry's
    /// position in the list stands for it.
    public var rank: Int?

    public init(title: String, originalTitle: String? = nil, year: Int? = nil, imdbId: String? = nil, tmdbId: String? = nil,
                rank: Int? = nil) {
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.imdbId = imdbId
        self.tmdbId = tmdbId
        self.rank = rank
    }
}

/// A source's current movie and show lists, most popular first.
public struct PopularityChart: Sendable, Hashable, Codable {
    public var source: ChartSource
    /// Netflix: the last day (a Sunday) of the week the lists cover, "2026-10-04". nil for live lists.
    public var week: String?
    public var movies: [ChartEntry]
    public var series: [ChartEntry]

    public init(source: ChartSource, week: String? = nil, movies: [ChartEntry], series: [ChartEntry]) {
        self.source = source
        self.week = week
        self.movies = movies
        self.series = series
    }

    public func entries(_ kind: MediaMetadata.Kind) -> [ChartEntry] {
        kind == .movie ? movies : series
    }
}

/// Which chart Home's "Top 10" rows follow (Settings › AI › Home). Stored as a string preference.
public enum TopTenRegion: Sendable, Hashable {
    /// Netflix in the device's country when Netflix publishes one, else Netflix worldwide.
    case automatic
    case worldwide
    /// Netflix in one country (ISO code).
    case country(String)
    /// What's popular now: TMDB trending with the user's key, else Cinemeta.
    case popular

    public init(preference: String) {
        switch preference {
        case "", "auto": self = .automatic
        case "global": self = .worldwide
        case "popular": self = .popular
        default: self = .country(preference.uppercased())
        }
    }

    public var preference: String {
        switch self {
        case .automatic: ""
        case .worldwide: "global"
        case .popular: "popular"
        case .country(let code): code
        }
    }

    /// Sources to try, best first. A row uses the first one that matches enough of the library.
    public func chain(deviceRegion: String?, hasTMDBKey: Bool) -> [ChartSource] {
        let popular: [ChartSource] = hasTMDBKey ? [.tmdbTrending, .cinemetaPopular] : [.cinemetaPopular]
        switch self {
        case .automatic:
            if let code = deviceRegion?.uppercased(), NetflixTop10.countryCodes.contains(code) {
                return [.netflixCountry(code), .netflixGlobal] + popular
            }
            return [.netflixGlobal] + popular
        case .worldwide:
            return [.netflixGlobal] + popular
        case .country(let code):
            guard NetflixTop10.countryCodes.contains(code) else { return [.netflixGlobal] + popular }
            return [.netflixCountry(code), .netflixGlobal] + popular
        case .popular:
            return popular
        }
    }
}

// MARK: - Netflix Top 10 files

/// Netflix's public Top 10 data (netflix.com/tudum/top10, "Download the data"): tab-separated files with every week
/// since mid-2021, newest week first.
///
/// - `all-weeks-global.tsv` (~0.9 MB): `week, category, weekly_rank, show_title, season_title, weekly_hours_viewed,
///   runtime, weekly_views, …`; four lists per week ("Films (English)", "Films (Non-English)", "TV (English)",
///   "TV (Non-English)"). The latest week is the first ~40 lines, so the download stops there.
/// - `all-weeks-countries.tsv` (~32 MB): `country_name, country_iso2, week, category ("Films"/"TV"), weekly_rank,
///   show_title, season_title, …`, grouped by country (alphabetical by name), newest week first within each. The
///   download stops right after the chosen country's latest week (Egypt ≈ 7 MB in, Saudi Arabia ≈ 25 MB).
///
/// Shows are listed per season ("Wednesday: Season 2"); `show_title` is the show itself and is what's kept.
public enum NetflixTop10 {
    static let globalURL = "https://www.netflix.com/tudum/top10/data/all-weeks-global.tsv"
    static let countriesURL = "https://www.netflix.com/tudum/top10/data/all-weeks-countries.tsv"

    /// Countries with a current weekly list (checked against the file in October 2026; Russia's ended in 2022).
    public static let countryCodes: Set<String> = [
        "AE", "AR", "AT", "AU", "BD", "BE", "BG", "BH", "BO", "BR", "BS", "CA", "CH", "CL", "CO", "CR", "CY", "CZ",
        "DE", "DK", "DO", "EC", "EE", "EG", "ES", "FI", "FR", "GB", "GP", "GR", "GT", "HK", "HN", "HR", "HU", "ID",
        "IE", "IL", "IN", "IS", "IT", "JM", "JO", "JP", "KE", "KR", "KW", "LB", "LK", "LT", "LU", "LV", "MA", "MQ",
        "MT", "MU", "MV", "MX", "MY", "NC", "NG", "NI", "NL", "NO", "NZ", "OM", "PA", "PE", "PH", "PK", "PL", "PT",
        "PY", "QA", "RE", "RO", "RS", "SA", "SE", "SG", "SI", "SK", "SV", "TH", "TR", "TT", "TW", "UA", "US", "UY",
        "VE", "VN", "ZA",
    ]

    /// Reads a Top 10 file line by line and keeps only the newest week (of one country, or the global lists).
    /// `consume` returns false once that week is complete, so the caller can stop downloading.
    public struct LatestWeekParser: Sendable {
        /// nil = the global file.
        let country: String?
        private var columns: [String: Int] = [:]
        private var week: String?
        private var films: [Row] = []
        private var shows: [Row] = []
        private(set) var finished = false

        struct Row: Sendable {
            var rank: Int
            var title: String
            var views: Double
        }

        public init(country: String?) {
            self.country = country?.uppercased()
        }

        public mutating func consume(_ rawLine: String) -> Bool {
            guard !finished else { return false }
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : Substring(rawLine)
            guard !line.isEmpty else { return true }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if columns.isEmpty {
                for (i, name) in fields.enumerated() { columns[name.trimmingCharacters(in: .whitespaces).lowercased()] = i }
                // Not a Top 10 file (an error page): stop.
                if columns["week"] == nil || columns["show_title"] == nil { finished = true }
                return !finished
            }
            func field(_ name: String) -> String? {
                guard let i = columns[name], i < fields.count else { return nil }
                let value = fields[i].trimmingCharacters(in: .whitespaces)
                return value.isEmpty || value == "N/A" ? nil : value
            }
            if let country {
                guard let code = field("country_iso2")?.uppercased() else { return true }
                if code != country {
                    // Past the country's block: done.
                    if week != nil { finished = true }
                    return !finished
                }
            }
            guard let rowWeek = field("week"), let category = field("category"), let title = field("show_title") else { return true }
            if week == nil { week = rowWeek }
            guard rowWeek == week else {
                finished = true
                return false
            }
            let row = Row(rank: field("weekly_rank").flatMap { Int($0) } ?? Int.max,
                          title: title,
                          views: field("weekly_views").flatMap { Double($0) } ?? field("weekly_hours_viewed").flatMap { Double($0) } ?? 0)
            if category.hasPrefix("Films") {
                films.append(row)
            } else if category.hasPrefix("TV") {
                shows.append(row)
            }
            return true
        }

        /// The newest week's lists; nil when the file had no rows for it.
        public func chart() -> PopularityChart? {
            guard let week, !(films.isEmpty && shows.isEmpty) else { return nil }
            let source: ChartSource = country.map { .netflixCountry($0) } ?? .netflixGlobal
            return PopularityChart(source: source, week: week, movies: Self.ranked(films, global: country == nil),
                                   series: Self.ranked(shows, global: country == nil))
        }

        /// Country lists by rank; the global file's English and non-English lists merged by views. A show listed
        /// with two seasons appears once, where its best season is.
        static func ranked(_ rows: [Row], global: Bool) -> [ChartEntry] {
            let sorted = rows.enumerated().sorted { a, b in
                if global, a.element.views != b.element.views { return a.element.views > b.element.views }
                if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
                return a.offset < b.offset
            }
            var seen = Set<String>()
            return sorted.compactMap { item in
                guard seen.insert(item.element.title.lowercased()).inserted else { return nil }
                // Country lists keep Netflix's rank (a show's best season); the merged global list has no single one.
                return ChartEntry(title: item.element.title, rank: global || item.element.rank == .max ? nil : item.element.rank)
            }
        }
    }

    /// The Sunday a week string names ("2026-10-04"), in UTC.
    static func weekEnd(_ week: String?) -> Date? {
        guard let week else { return nil }
        let parts = week.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - Cinemeta and TMDB lists

extension CinemetaClient {
    /// Cinemeta's "Popular" catalogue (redirects to cinemeta-catalogs.strem.io; ~50 titles with IMDb ids).
    func popular(kind: MediaMetadata.Kind) async throws -> [ChartEntry] {
        Self.parsePopular(try await fetch("\(Self.base)/catalog/\(kind.cinemetaType)/top.json", [:]))
    }

    static func parsePopular(_ json: JSONObject) -> [ChartEntry] {
        json.objects("metas").compactMap { m in
            guard let name = m.string("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            let imdb = [m.string("imdb_id"), m.string("id")].compactMap { $0 }.first { $0.hasPrefix("tt") }
            let tmdb = m.string("moviedb_id").flatMap { $0 == "0" ? nil : $0 }
            return ChartEntry(title: name, year: TitleMatcher.parseYearRange(m.string("releaseInfo") ?? m.string("year")).start,
                              imdbId: imdb, tmdbId: tmdb)
        }
    }
}

extension TMDBClient {
    /// TMDB's trending movies or shows of the week (20 titles, TMDB ids, original titles).
    func trending(kind: MediaMetadata.Kind) async throws -> [ChartEntry] {
        Self.parseTrending(try await get("/trending/\(kind == .movie ? "movie" : "tv")/week", [("language", language)]), kind: kind)
    }

    static func parseTrending(_ json: JSONObject, kind: MediaMetadata.Kind) -> [ChartEntry] {
        json.objects("results").compactMap { r in
            let title = (kind == .movie ? r.string("title") : r.string("name")) ?? r.string("title") ?? r.string("name")
            guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
            let original = (kind == .movie ? r.string("original_title") : r.string("original_name"))?
                .trimmingCharacters(in: .whitespaces)
            let date = kind == .movie ? r.string("release_date") : r.string("first_air_date")
            return ChartEntry(title: title, originalTitle: original == title ? nil : original?.nilIfEmpty,
                              year: date.flatMap(TitleMatcher.parseYear), tmdbId: r.int("id").map(String.init) ?? r.string("id"))
        }
    }
}
