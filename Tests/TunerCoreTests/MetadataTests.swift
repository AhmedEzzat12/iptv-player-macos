import Foundation
import Testing
@testable import TunerCore

func metadataFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/metadata"))
    return try Data(contentsOf: url)
}

func metadataJSON(_ name: String) throws -> JSONObject {
    try #require(JSONObject(try JSONSerialization.jsonObject(with: try metadataFixture(name))))
}

// MARK: - Title cleaning

struct CleanCase: Sendable, CustomTestStringConvertible {
    var name: String
    var year: String? = nil
    var kind: MediaMetadata.Kind = .movie
    var title: String
    var expectedYear: Int? = nil
    var literal: String? = nil

    var testDescription: String { name }
}

@Suite("Title matcher — cleaning")
struct TitleCleaningTests {
    static let cases: [CleanCase] = [
        CleanCase(name: "EN - The Matrix (1999)", title: "The Matrix", expectedYear: 1999),
        CleanCase(name: "|AR| فيلم الرسالة", title: "الرسالة"),
        CleanCase(name: "4K-Dune Part Two 2024 HDTC", title: "Dune Part Two", expectedYear: 2024, literal: "Dune Part Two 2024"),
        CleanCase(name: "NF: Wednesday S01", kind: .series, title: "Wednesday"),
        CleanCase(name: "The Office (US) [MULTI-SUB]", kind: .series, title: "The Office"),
        CleanCase(name: "Sardar 2 ( 2026 )", title: "Sardar 2", expectedYear: 2026),
        CleanCase(name: "4K-Oppenheimer 2023", title: "Oppenheimer", expectedYear: 2023, literal: "Oppenheimer 2023"),
        CleanCase(name: "Blade Runner 2049", year: "2017", title: "Blade Runner 2049", expectedYear: 2017),
        CleanCase(name: "Ant-Man and the Wasp (2018)", title: "Ant-Man and the Wasp", expectedYear: 2018),
        CleanCase(name: "WALL-E (2008)", title: "WALL-E", expectedYear: 2008),
        CleanCase(name: "Spider-Man: No Way Home (2021) 1080p WEB-DL x264", title: "Spider-Man: No Way Home", expectedYear: 2021),
        CleanCase(name: "Matrix, The (1999)", title: "The Matrix", expectedYear: 1999),
        CleanCase(name: "[EN] Inception 2010 BluRay", title: "Inception", expectedYear: 2010, literal: "Inception 2010"),
        CleanCase(name: "Breaking Bad - Season 1", kind: .series, title: "Breaking Bad"),
        CleanCase(name: "Avatar The Way of Water (2022) Arabic Sub", title: "Avatar The Way of Water", expectedYear: 2022),
        CleanCase(name: "TOP GUN MAVERICK (2022) UHD HDR", title: "TOP GUN MAVERICK", expectedYear: 2022),
        CleanCase(name: "(500) Days of Summer (2009)", title: "(500) Days of Summer", expectedYear: 2009),
        CleanCase(name: "1917 (2019)", title: "1917", expectedYear: 2019),
        CleanCase(name: "The.Matrix.1999.1080p.BluRay.x264", title: "The Matrix", expectedYear: 1999, literal: "The Matrix 1999"),
        CleanCase(name: "Cam (2018)", title: "Cam", expectedYear: 2018),
        CleanCase(name: "Charlotte's Web (2006)", title: "Charlotte's Web", expectedYear: 2006),
        CleanCase(name: "AR: Al Risala (1976) مدبلج", title: "Al Risala", expectedYear: 1976),
        CleanCase(name: "Game of Thrones S08E06 The Iron Throne", kind: .series, title: "Game of Thrones"),
        CleanCase(name: "Kung Fu Panda 4 (2024) [MULTI-SUB]", title: "Kung Fu Panda 4", expectedYear: 2024),
        CleanCase(name: "|NF| Squid Game (2021) S02", kind: .series, title: "Squid Game", expectedYear: 2021),
        CleanCase(name: "Jaws: The Revenge (1987)", title: "Jaws: The Revenge", expectedYear: 1987),
        CleanCase(name: "The Matrix", year: "1999-03-31", title: "The Matrix", expectedYear: 1999),
        CleanCase(name: "EN | 4K | Dune (2021)", title: "Dune", expectedYear: 2021),
        CleanCase(name: "Wednesday (2022)", kind: .series, title: "Wednesday", expectedYear: 2022),
        CleanCase(name: "Uncut Gems (2019) HDRip", title: "Uncut Gems", expectedYear: 2019),
        CleanCase(name: "The Batman - EN", title: "The Batman"),
    ]

    @Test(arguments: cases)
    func cleans(_ c: CleanCase) throws {
        let q = try #require(TitleMatcher.query(name: c.name, year: c.year, kind: c.kind))
        #expect(q.title == c.title)
        #expect(q.year == c.expectedYear)
        #expect(q.literalTitle == c.literal)
    }

    @Test func nothingMeaningfulLeft() {
        #expect(TitleMatcher.query(name: "  ", kind: .movie) == nil)
        #expect(TitleMatcher.query(name: "[MULTI-SUB] ( )", kind: .movie) == nil)
        #expect(TitleMatcher.query(name: "4K HDR", kind: .movie) == nil)
        #expect(TitleMatcher.query(name: "[REC] (2007)", kind: .movie)?.title == "REC")
    }

    @Test func displayTitle() {
        #expect(TitleMatcher.cleanTitle("EN - The Matrix (1999) [4K]") == "The Matrix")
        #expect(TitleMatcher.cleanTitle("Blade Runner 2049") == "Blade Runner 2049")
    }
}

// MARK: - Scoring

struct ScoreCase: Sendable, CustomTestStringConvertible {
    var name: String
    var kind: MediaMetadata.Kind = .movie
    /// (titles, start year, end year)
    var candidates: [([String], Int?, Int?)]
    var expected: Int?

    var testDescription: String { name }
}

@Suite("Title matcher — scoring")
struct TitleScoringTests {
    static let cases: [ScoreCase] = [
        ScoreCase(name: "EN - The Matrix (1999)", candidates: [(["The Matrix Reloaded"], 2003, nil), (["The Matrix"], 1999, nil)], expected: 1),
        ScoreCase(name: "4K-Dune Part Two 2024 HDTC", candidates: [(["Dune: Part Three"], 2026, nil), (["Dune: Part Two"], 2024, nil), (["Dune"], 2021, nil)], expected: 1),
        ScoreCase(name: "4K-Oppenheimer 2023", candidates: [(["Oppenheimer: The Real Story"], 2023, nil), (["Oppenheimer"], 2023, nil)], expected: 1),
        ScoreCase(name: "Blade Runner 2049", candidates: [(["Blade Runner"], 1982, nil), (["Blade Runner 2049"], 2017, nil)], expected: 1),
        ScoreCase(name: "Wonder Woman 1984", candidates: [(["Wonder Woman"], 2017, nil), (["Wonder Woman 1984"], 2020, nil)], expected: 1),
        ScoreCase(name: "The Office (US)", kind: .series, candidates: [(["The Office"], 2005, 2013), (["The Office"], 2001, 2003)], expected: 0),
        ScoreCase(name: "Breaking Bad", kind: .series, candidates: [(["Breaking Bad: Original Minisodes"], 2009, 2011), (["Breaking Bad"], 2008, 2013)], expected: 1),
        ScoreCase(name: "|AR| فيلم الرسالة", candidates: [(["The Message"], 1976, nil)], expected: nil),
        ScoreCase(name: "|AR| فيلم الرسالة", candidates: [(["الرسالة", "The Message"], 1976, nil)], expected: 0),
        ScoreCase(name: "The Lion King (2019)", candidates: [(["The Lion King"], 1994, nil), (["The Lion King"], 2019, nil)], expected: 1),
        ScoreCase(name: "Inception (2023)", candidates: [(["Inception"], 2010, nil)], expected: nil),
        // A year-less placeholder entry must not win just because the real film's year disagrees.
        ScoreCase(name: "Inception (2023)", candidates: [(["Inception"], 2010, nil), (["Inception"], nil, nil)], expected: nil),
        ScoreCase(name: "Inception", candidates: [(["Inception"], nil, nil), (["Inception"], 2010, nil)], expected: 0),
        ScoreCase(name: "Avatar (2009)", candidates: [(["Avatar: The Way of Water"], 2022, nil), (["Avatar"], 2009, nil)], expected: 1),
        ScoreCase(name: "Spiderman No Way Home", candidates: [(["Spider-Man: No Way Home"], 2021, nil)], expected: 0),
        ScoreCase(name: "Rocky 2 (1979)", candidates: [(["Rocky IV"], 1985, nil), (["Rocky II"], 1979, nil)], expected: 1),
        ScoreCase(name: "Amelie (2001)", candidates: [(["Amélie", "Le Fabuleux Destin d'Amélie Poulain"], 2001, nil)], expected: 0),
        ScoreCase(name: "Fast and Furious (2009)", candidates: [(["The Fast and the Furious"], 2001, nil), (["Fast & Furious"], 2009, nil)], expected: 1),
        ScoreCase(name: "Harry Potter", candidates: [(["Harry Potter and the Philosopher's Stone"], 2001, nil)], expected: nil),
        ScoreCase(name: "Sardar (2022)", candidates: [(["Sardar 2"], 2026, nil)], expected: nil),
        ScoreCase(name: "Mission Impossible Dead Reckoning (2023)", candidates: [(["Mission: Impossible - Dead Reckoning Part One"], 2023, nil)], expected: 0),
        ScoreCase(name: "The Matrix", candidates: [(["The Matrix Reloaded"], 2003, nil)], expected: nil),
        ScoreCase(name: "Wednesday (2022)", kind: .series, candidates: [(["The Wednesday Play"], 1964, 1970), (["Wednesday"], 2022, nil)], expected: 1),
        ScoreCase(name: "Dune (2021)", candidates: [(["Dune"], 1984, nil), (["Dune"], 2021, nil)], expected: 1),
        ScoreCase(name: "The Fellowship of the Ring (2001)", candidates: [(["The Lord of the Rings: The Fellowship of the Ring"], 2001, nil)], expected: 0),
        ScoreCase(name: "Breaking Bad (2010)", kind: .series, candidates: [(["Breaking Bad"], 2008, 2013)], expected: 0),
        ScoreCase(name: "Breaking Bad (1995)", kind: .series, candidates: [(["Breaking Bad"], 2008, 2013)], expected: nil),
        // Still-running shows (no end year) listed under a later season's year — this used to trap (Int.max + 1).
        ScoreCase(name: "Severance (2025)", kind: .series, candidates: [(["Severance"], 2022, nil)], expected: 0),
        ScoreCase(name: "The Simpsons (2024)", kind: .series, candidates: [(["The Simpsons Shorts"], 1987, 1989), (["The Simpsons"], 1989, nil)], expected: 1),
    ]

    @Test(arguments: cases)
    func picksTheRightCandidate(_ c: ScoreCase) throws {
        let query = try #require(TitleMatcher.query(name: c.name, kind: c.kind))
        let candidates = c.candidates.map { TitleMatcher.Candidate(titles: $0.0, year: $0.1, endYear: $0.2) }
        #expect(TitleMatcher.bestMatch(query, candidates, kind: c.kind)?.index == c.expected)
    }

    @Test func similarityOrdering() {
        let exact = TitleMatcher.titleSimilarity("The Matrix", "the matrix")
        let article = TitleMatcher.titleSimilarity("Matrix", "The Matrix")
        let prefix = TitleMatcher.titleSimilarity("The Matrix", "The Matrix Reloaded")
        let overlap = TitleMatcher.titleSimilarity("Matrix Reloaded The", "The Matrix Reloaded Special")
        #expect(exact == 1)
        #expect(article > prefix)
        #expect(prefix > overlap)
        #expect(TitleMatcher.titleSimilarity("Dune", "Oppenheimer") == 0)
    }
}

// MARK: - Cinemeta

@Suite("Cinemeta")
struct CinemetaTests {
    @Test func parsesSearch() throws {
        let results = CinemetaClient.parseSearch(try metadataJSON("cinemeta_search_movie_dune.json"))
        #expect(results.count > 5)
        #expect(results[0].id == "tt15239678")
        #expect(results[0].name == "Dune: Part Two")
        #expect(results[0].releaseInfo == "2024")

        let series = CinemetaClient.parseSearch(try metadataJSON("cinemeta_search_series_breaking_bad.json"))
        #expect(series.first?.releaseInfo == "2008-2013")
        let query = try #require(TitleMatcher.query(name: "Breaking Bad", kind: .series))
        #expect(CinemetaClient.bestMatch(query, series, kind: .series)?.index == 0)
    }

    @Test func mapsMovieMeta() throws {
        let meta = try #require(try metadataJSON("cinemeta_meta_movie_dune.json").object("meta"))
        let md = try #require(CinemetaClient.map(meta, kind: .movie))
        #expect(md.source == "Cinemeta")
        #expect(md.title == "Dune: Part Two")
        #expect(md.imdbId == "tt15239678")
        #expect(md.tmdbId == "693134")
        #expect(md.year == "2024")
        #expect(md.releaseDate == "2024-03-01")
        #expect(md.runtimeMinutes == 167)
        #expect(md.rating == 8.4)
        #expect(md.genres == ["Action", "Adventure", "Drama"])
        #expect(md.cast.map(\.name) == ["Timothée Chalamet", "Zendaya", "Rebecca Ferguson"])
        #expect(md.cast.allSatisfy { $0.photoURL == nil })
        #expect(md.directors == ["Denis Villeneuve"])
        #expect(md.writers.count == 3)
        #expect(md.trailerYouTubeId == "U2Qp5pL3ovA")
        #expect(md.posterURL == "https://images.metahub.space/poster/large/tt15239678/img")
        #expect(md.backdropURL == "https://images.metahub.space/background/medium/tt15239678/img")
        #expect(md.logoURL == "https://images.metahub.space/logo/medium/tt15239678/img")
        #expect(md.country?.hasPrefix("United States") == true)
        #expect(md.overview?.isEmpty == false)
        #expect(md.episodes.isEmpty)
    }

    @Test func mapsSeriesMetaWithEpisodes() throws {
        let meta = try #require(try metadataJSON("cinemeta_meta_series_breaking_bad.json").object("meta"))
        let md = try #require(CinemetaClient.map(meta, kind: .series))
        #expect(md.title == "Breaking Bad")
        #expect(md.year == "2008–2013")
        #expect(md.directors.isEmpty)
        #expect(md.writers == ["Vince Gilligan"])
        #expect(md.runtimeMinutes == 49)
        #expect(md.episodes.count == 67)
        let ep = try #require(md.episode(season: 1, number: 2))
        #expect(ep.title == "Cat's in the Bag...")
        #expect(ep.stillURL == "https://episodes.metahub.space/tt0903747/1/2/w780.jpg")
        #expect(ep.airDate == "2008-01-28")
        #expect(ep.rating == 7.6)
        #expect(ep.overview?.isEmpty == false)
        #expect(md.episodes.first?.season == 0) // specials sort first
    }

    @Test func lenientFieldShapes() throws {
        let meta = JSONObject([
            "name": "Odd", "releaseInfo": 2001, "runtime": "1h 45min", "imdbRating": 7, "genre": "Drama, Crime",
            "director": "Someone", "cast": [["name": "A"], "B"], "trailerStreams": [["ytId": "yt1"]],
            "videos": [["season": "1", "number": "3", "title": "Third", "released": "2001-01-01T00:00:00Z"]],
        ] as [String: Any])
        let md = try #require(CinemetaClient.map(meta, kind: .series))
        #expect(md.year == "2001")
        #expect(md.runtimeMinutes == 105)
        #expect(md.rating == 7)
        #expect(md.genres == ["Drama", "Crime"])
        #expect(md.directors == ["Someone"])
        #expect(md.cast.map(\.name) == ["A", "B"])
        #expect(md.trailerYouTubeId == "yt1")
        #expect(md.episode(season: 1, number: 3)?.title == "Third")
        #expect(md.episode(season: 1, number: 3)?.airDate == "2001-01-01")
    }

    @Test func nonLatinTitlesAreNotSearched() {
        #expect(CinemetaClient.isSearchable("The Matrix"))
        #expect(CinemetaClient.isSearchable("1917"))
        #expect(CinemetaClient.isSearchable("Amélie"))
        #expect(!CinemetaClient.isSearchable("الرسالة"))
        #expect(!CinemetaClient.isSearchable("Брат"))
    }
}

// MARK: - TMDB

@Suite("TMDB")
struct TMDBTests {
    let noFetch: MetadataFetch = { _, _ in throw HTTPError.emptyBody }

    @Test func credentials() throws {
        #expect(TMDBClient.credential(for: "0123456789abcdef0123456789abcdef") == .apiKey("0123456789abcdef0123456789abcdef"))
        #expect(TMDBClient.credential(for: " eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIxMjMifQ.sig \n") == .bearer("eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIxMjMifQ.sig"))
        #expect(TMDBClient.credential(for: "  ") == nil)
        #expect(TMDBClient.credential(for: nil) == nil)
    }

    @Test func requestsCarryTheCredential() throws {
        let v3 = try #require(TMDBClient(key: "0123456789abcdef0123456789abcdef", language: "en-US", fetch: noFetch))
        let url = v3.url("/search/movie", [("query", "Fast & Furious"), ("language", "en-US")])
        #expect(url == "https://api.themoviedb.org/3/search/movie?query=Fast%20%26%20Furious&language=en-US&api_key=0123456789abcdef0123456789abcdef")
        #expect(v3.headers.isEmpty)

        let v4 = try #require(TMDBClient(key: "eyJtoken.part.sig", language: "ar_SA", fetch: noFetch))
        #expect(v4.headers["Authorization"] == "Bearer eyJtoken.part.sig")
        #expect(!v4.url("/configuration", []).contains("api_key"))
        #expect(v4.language == "ar-SA")
    }

    @Test func normalizesLanguages() {
        #expect(TMDBClient.normalizedLanguage("en-US") == "en-US")
        #expect(TMDBClient.normalizedLanguage("fr") == "fr")
        #expect(TMDBClient.normalizedLanguage("zh-Hans-CN") == "zh-CN")
        #expect(TMDBClient.normalizedLanguage("") == "en-US")
    }

    @Test func mapsMovieDetails() throws {
        let md = try #require(TMDBClient.mapMovie(try metadataJSON("tmdb_movie.json"), language: "en-US"))
        #expect(md.source == "TMDB")
        #expect(md.title == "Dune: Part Two")
        #expect(md.originalTitle == nil)
        #expect(md.tmdbId == "693134")
        #expect(md.imdbId == "tt15239678")
        #expect(md.year == "2024")
        #expect(md.releaseDate == "2024-02-27")
        #expect(md.runtimeMinutes == 167)
        #expect(md.rating == 8.2)
        #expect(md.genres == ["Science Fiction", "Adventure"])
        #expect(md.country == "United States")
        // Empty UI-language overview falls back to the US English translation.
        #expect(md.overview?.hasPrefix("Follow the mythic journey") == true)
        #expect(md.tagline == "Long live the fighters.")
        #expect(md.posterURL == "https://image.tmdb.org/t/p/w500/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg")
        #expect(md.backdropURL == "https://image.tmdb.org/t/p/w1280/xOMo8BRK7PfcJv9JCnx7s5hj0PX.jpg")
        #expect(md.logoURL == "https://image.tmdb.org/t/p/w500/logo-en.png")
        #expect(md.cast.map(\.name) == ["Timothée Chalamet", "Zendaya", "Rebecca Ferguson"])
        #expect(md.cast[0].character == "Paul Atreides")
        #expect(md.cast[0].photoURL == "https://image.tmdb.org/t/p/w185/BE2sdjpgsa2rNTFa66f7upkaOP.jpg")
        #expect(md.cast[2].photoURL == nil)
        #expect(md.directors == ["Denis Villeneuve"])
        #expect(md.writers == ["Denis Villeneuve", "Jon Spaihts", "Frank Herbert"])
        #expect(md.trailerYouTubeId == "U2Qp5pL3ovA")
    }

    @Test func prefersUILanguageArtworkAndTrailer() throws {
        let md = try #require(TMDBClient.mapMovie(try metadataJSON("tmdb_movie.json"), language: "ar-SA"))
        #expect(md.logoURL == "https://image.tmdb.org/t/p/w500/logo-ar.png")
        #expect(md.trailerYouTubeId == "arTrailer1")
        #expect(md.country == Locale(identifier: "ar-SA").localizedString(forRegionCode: "US"))
    }

    @Test func logoFallbacks() throws {
        let svgOnly = JSONObject(["id": 1, "title": "X", "images": ["logos": [
            ["file_path": "/only.svg", "iso_639_1": "en", "vote_average": 5],
            ["file_path": "/other.png", "iso_639_1": "ko", "vote_average": 9],
        ]]] as [String: Any])
        #expect(TMDBClient.mapMovie(svgOnly, language: "en-US")?.logoURL == "https://image.tmdb.org/t/p/w500/only.png")
        let foreignOnly = JSONObject(["id": 1, "title": "X", "images": ["logos": [
            ["file_path": "/other.png", "iso_639_1": "ko", "vote_average": 9],
        ]]] as [String: Any])
        #expect(TMDBClient.mapMovie(foreignOnly, language: "en-US")?.logoURL == nil)
    }

    @Test func mapsSeriesWithSeasons() throws {
        let tv = try metadataJSON("tmdb_tv.json")
        #expect(TMDBClient.seasonNumbers(tv) == [1, 2, 0])
        let seasons = try ["tmdb_season_1.json", "tmdb_season_2.json", "tmdb_season_0.json"].map(metadataJSON)
        let md = try #require(TMDBClient.mapSeries(tv, seasons: seasons, language: "en-US"))
        #expect(md.kind == .series)
        #expect(md.title == "Breaking Bad")
        #expect(md.tmdbId == "1396")
        #expect(md.imdbId == "tt0903747")
        #expect(md.year == "2008–2013")
        #expect(md.runtimeMinutes == 56)
        #expect(md.writers == ["Vince Gilligan"])
        #expect(md.directors.isEmpty)
        #expect(md.cast.first?.character == "Walter White")
        #expect(md.logoURL == "https://image.tmdb.org/t/p/w500/bb-logo.png")
        #expect(md.trailerYouTubeId == "HhesaQXLuRY")
        #expect(md.episodes.map { "\($0.season)x\($0.episode)" } == ["0x1", "1x1", "1x2", "2x1"])
        let ep = try #require(md.episode(season: 1, number: 2))
        #expect(ep.title == "Cat's in the Bag...")
        #expect(ep.stillURL == "https://image.tmdb.org/t/p/w300/tjDNvbokPLtEnpFyFPyXMOd6Zr1.jpg")
        #expect(ep.airDate == "2008-01-27")
        #expect(ep.rating == 8)
        let unrated = try #require(md.episode(season: 2, number: 1))
        #expect(unrated.rating == nil)
        #expect(unrated.stillURL == nil)
    }

    @Test func searchMatchingUsesOriginalTitles() throws {
        let results = TMDBClient.parseSearch(try metadataJSON("tmdb_search_movie.json"), kind: .movie)
        #expect(results.map(\.id) == ["693134", "1170608", "438631"])
        let query = try #require(TitleMatcher.query(name: "4K-Dune Part Two 2024 HDTC", kind: .movie))
        #expect(TMDBClient.bestMatch(query, results, kind: .movie)?.index == 0)
        let dune = try #require(TitleMatcher.query(name: "Dune (2021)", kind: .movie))
        #expect(TMDBClient.bestMatch(dune, results, kind: .movie)?.index == 2)
    }

    @Test func scriptLanguages() {
        #expect(TMDBClient.scriptLanguage(of: "الرسالة") == "ar-SA")
        #expect(TMDBClient.scriptLanguage(of: "Брат") == "ru-RU")
        #expect(TMDBClient.scriptLanguage(of: "The Matrix") == nil)
    }
}

// MARK: - Service (stubbed network)

/// Serves fixtures by URL and records requests.
final class StubNetwork: @unchecked Sendable {
    typealias Handler = @Sendable (String) throws -> JSONObject
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    let delay: Duration
    let handler: Handler

    init(delay: Duration = .zero, handler: @escaping Handler) {
        self.delay = delay
        self.handler = handler
    }

    var requests: [String] { lock.withLock { _requests } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }

    var fetch: MetadataFetch {
        { url, headers in
            self.lock.withLock {
                self._requests.append(url)
                self._inFlight += 1
                self._maxInFlight = max(self._maxInFlight, self._inFlight)
            }
            defer { self.lock.withLock { self._inFlight -= 1 } }
            if self.delay > .zero { try await Task.sleep(for: self.delay) }
            return try self.handler(url)
        }
    }

    static func json(_ object: [String: Any]) -> JSONObject { JSONObject(object) }

    /// Cinemeta fixtures; anything else is an empty search / 404.
    static func cinemeta(_ rawURL: String) throws -> JSONObject {
        let url = rawURL.lowercased()
        if url.contains("/catalog/movie/top/search=dune") { return try metadataJSON("cinemeta_search_movie_dune.json") }
        if url.contains("/catalog/series/top/search=breaking") { return try metadataJSON("cinemeta_search_series_breaking_bad.json") }
        if url.contains("/catalog/series/top/search=the%20office") { return try metadataJSON("cinemeta_search_series_the_office.json") }
        if url.hasSuffix("/meta/movie/tt15239678.json") { return try metadataJSON("cinemeta_meta_movie_dune.json") }
        if url.hasSuffix("/meta/series/tt0903747.json") { return try metadataJSON("cinemeta_meta_series_breaking_bad.json") }
        if url.contains("/catalog/") { return JSONObject(["metas": [Any]()]) }
        throw HTTPError.status(404, url: rawURL)
    }
}

@Suite("Metadata service")
struct MetadataServiceTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    func movie(_ id: String, _ name: String, year: String? = nil, tmdbId: String? = nil) -> Movie {
        var m = Movie(id: id, sourceId: "src", categoryId: nil, name: name, providerId: id, providerOrder: 0)
        m.year = year
        m.tmdbId = tmdbId
        return m
    }

    @Test func cinemetaMatchIsCachedAndReused() async throws {
        let net = StubNetwork(handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        let md = try #require(await service.metadata(for: movie("m1", "4K-Dune Part Two 2024 HDTC")))
        #expect(md.source == "Cinemeta")
        #expect(md.imdbId == "tt15239678")
        #expect(net.requests.count == 2) // search + meta

        #expect(await service.metadata(for: movie("m1", "4K-Dune Part Two 2024 HDTC")) == md)
        #expect(await service.cachedMetadata(mediaId: "m1") == md)
        #expect(await service.cachedMetadata(mediaIds: ["m1", "nope"]).keys.sorted() == ["m1"])
        #expect(net.requests.count == 2)
    }

    @Test func concurrentRequestsShareOneLookup() async throws {
        let net = StubNetwork(delay: .milliseconds(50), handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        let m = movie("m1", "Dune: Part Two", year: "2024")
        let results = await withTaskGroup(of: MediaMetadata?.self) { group in
            for _ in 0..<6 { group.addTask { await service.metadata(for: m) } }
            return await group.reduce(into: [MediaMetadata?]()) { $0.append($1) }
        }
        #expect(results.count == 6)
        #expect(results.allSatisfy { $0?.imdbId == "tt15239678" })
        #expect(net.requests.count == 2)
    }

    @Test func networkLookupsAreLimited() async throws {
        let net = StubNetwork(delay: .milliseconds(40), handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<9 {
                let m = movie("m\(i)", "Unknown Film Number \(i)")
                group.addTask { _ = await service.metadata(for: m) }
            }
        }
        #expect(net.requests.count == 9)
        #expect(net.maxInFlight <= MetadataService.maxConcurrentLookups)
    }

    @Test func nonLatinMissIsCachedWithoutNetwork() async throws {
        let net = StubNetwork(handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        #expect(await service.metadata(for: movie("ar1", "|AR| فيلم الرسالة")) == nil)
        #expect(net.requests.isEmpty)
        let entry = try #require(try await db.metadataCacheEntry(mediaId: "ar1"))
        #expect(entry.notFound)
        #expect(entry.isFresh())
    }

    @Test func missIsCachedAsNotFound() async throws {
        let net = StubNetwork(handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        #expect(await service.metadata(for: movie("x", "Some Unknown Film (2011)")) == nil)
        let first = net.requests.count
        #expect(first >= 1)
        #expect(await service.metadata(for: movie("x", "Some Unknown Film (2011)")) == nil)
        #expect(net.requests.count == first)
        #expect(try await db.metadataCacheEntry(mediaId: "x")?.notFound == true)
    }

    @Test func disabledServesCacheOnly() async throws {
        let net = StubNetwork(handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        await service.configure(MetadataSettings(enabled: false))
        #expect(await service.metadata(for: movie("m1", "Dune: Part Two (2024)")) == nil)
        #expect(net.requests.isEmpty)

        // A stale cached match is still served while disabled.
        var cached = MediaMetadata(kind: .movie, source: "Cinemeta", title: "Dune: Part Two", fetchedAt: Date(timeIntervalSinceNow: -90 * 86_400))
        cached.imdbId = "tt15239678"
        try await db.saveMetadata(cached, mediaId: "m1")
        #expect(await service.metadata(for: movie("m1", "Dune: Part Two (2024)"))?.title == "Dune: Part Two")
        #expect(net.requests.isEmpty)
    }

    @Test func expiredEntriesAreRefetched() async throws {
        let net = StubNetwork(handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        let old = MediaMetadata(kind: .movie, source: "Cinemeta", title: "Old", fetchedAt: Date(timeIntervalSinceNow: -31 * 86_400))
        try await db.saveMetadata(old, mediaId: "m1")
        try await db.saveMetadataNotFound(mediaId: "m2", kind: .movie, at: Date(timeIntervalSinceNow: -8 * 86_400))
        try await db.saveMetadataNotFound(mediaId: "m3", kind: .movie, at: Date(timeIntervalSinceNow: -6 * 86_400))

        #expect(await service.metadata(for: movie("m1", "Dune Part Two (2024)"))?.title == "Dune: Part Two")
        #expect(await service.metadata(for: movie("m2", "Dune Part Two (2024)"))?.title == "Dune: Part Two")
        let count = net.requests.count
        #expect(await service.metadata(for: movie("m3", "Dune Part Two (2024)")) == nil) // fresh "not found"
        #expect(net.requests.count == count)
    }

    @Test func refreshMissKeepsEarlierMatch() async throws {
        let net = StubNetwork(handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        let old = MediaMetadata(kind: .movie, source: "Cinemeta", title: "Earlier Match", fetchedAt: Date(timeIntervalSinceNow: -40 * 86_400))
        try await db.saveMetadata(old, mediaId: "m1")
        #expect(await service.metadata(for: movie("m1", "Nothing Matches This"))?.title == "Earlier Match")
        let entry = try #require(try await db.metadataCacheEntry(mediaId: "m1"))
        #expect(!entry.notFound)
        #expect(entry.isFresh())
    }

    @Test func networkFailureIsNotCached() async throws {
        let net = StubNetwork { _ in throw URLError(.notConnectedToInternet) }
        let service = MetadataService(db: db, fetch: net.fetch)
        #expect(await service.metadata(for: movie("m1", "Dune Part Two (2024)")) == nil)
        #expect(try await db.metadataCacheEntry(mediaId: "m1") == nil)
        let count = net.requests.count
        // Backed off: no immediate retry.
        #expect(await service.metadata(for: movie("m1", "Dune Part Two (2024)")) == nil)
        #expect(net.requests.count == count)
    }

    @Test func tmdbIsPreferredAndUsesProviderId() async throws {
        let net = StubNetwork { url in
            if url.contains("api.themoviedb.org/3/movie/693134?") { return try metadataJSON("tmdb_movie.json") }
            if url.contains("api.themoviedb.org/3/search/movie?") { return try metadataJSON("tmdb_search_movie.json") }
            return try StubNetwork.cinemeta(url)
        }
        let service = MetadataService(db: db, fetch: net.fetch)
        await service.configure(MetadataSettings(tmdbAPIKey: "0123456789abcdef0123456789abcdef"))

        let direct = try #require(await service.metadata(for: movie("m1", "Whatever Name", tmdbId: "693134")))
        #expect(direct.source == "TMDB")
        #expect(net.requests.count == 1)
        #expect(net.requests[0].contains("append_to_response=credits,videos,images,external_ids"))
        #expect(net.requests[0].contains("include_image_language=en,null"))

        let searched = try #require(await service.metadata(for: movie("m2", "EN - Dune: Part Two (2024)")))
        #expect(searched.tmdbId == "693134")
        #expect(net.requests.contains { $0.contains("/search/movie?query=Dune:%20Part%20Two&") })
        #expect(!net.requests.contains { $0.contains("cinemeta") })
    }

    @Test func tmdbSeriesFetchesSeasons() async throws {
        let net = StubNetwork { url in
            if url.contains("/3/search/tv?") { return try metadataJSON("tmdb_search_tv.json") }
            if url.contains("/3/tv/1396/season/0?") { return try metadataJSON("tmdb_season_0.json") }
            if url.contains("/3/tv/1396/season/1?") { return try metadataJSON("tmdb_season_1.json") }
            if url.contains("/3/tv/1396/season/2?") { return try metadataJSON("tmdb_season_2.json") }
            if url.contains("/3/tv/1396?") { return try metadataJSON("tmdb_tv.json") }
            throw HTTPError.status(404, url: url)
        }
        let service = MetadataService(db: db, fetch: net.fetch)
        await service.configure(MetadataSettings(tmdbAPIKey: "eyJhbGciOiJIUzI1NiJ9.e30.sig"))
        let series = Series(id: "s1", sourceId: "src", categoryId: nil, name: "NF: Breaking Bad S01", providerId: "1", providerOrder: 0)
        let md = try #require(await service.metadata(for: series))
        #expect(md.source == "TMDB")
        #expect(md.episodes.count == 4)
        #expect(md.episode(season: 1, number: 2)?.stillURL?.hasSuffix("/w300/tjDNvbokPLtEnpFyFPyXMOd6Zr1.jpg") == true)
        #expect(!net.requests.contains { $0.contains("season/6") })
        #expect(!net.requests.contains { $0.contains("api_key") })
    }

    @Test func rejectedTMDBKeyFallsBackToCinemeta() async throws {
        let net = StubNetwork { url in
            if url.contains("themoviedb") { throw HTTPError.status(401, url: url) }
            return try StubNetwork.cinemeta(url)
        }
        let service = MetadataService(db: db, fetch: net.fetch)
        await service.configure(MetadataSettings(tmdbAPIKey: "bad"))
        let md = try #require(await service.metadata(for: movie("m1", "Dune Part Two (2024)")))
        #expect(md.source == "Cinemeta")
    }

    @Test func tmdbOutageMakesMissInconclusive() async throws {
        let net = StubNetwork { url in
            if url.contains("themoviedb") { throw HTTPError.status(503, url: url) }
            return try StubNetwork.cinemeta(url)
        }
        let service = MetadataService(db: db, fetch: net.fetch)
        await service.configure(MetadataSettings(tmdbAPIKey: "0123456789abcdef0123456789abcdef"))
        #expect(await service.metadata(for: movie("m1", "Some Unknown Film")) == nil)
        #expect(try await db.metadataCacheEntry(mediaId: "m1") == nil)
    }

    @Test func changingTheKeyMarksCacheStale() async throws {
        let net = StubNetwork(handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        await service.configure(MetadataSettings())
        _ = await service.metadata(for: movie("m1", "Dune Part Two (2024)"))
        let count = net.requests.count
        await service.configure(MetadataSettings()) // unchanged: no invalidation
        _ = await service.metadata(for: movie("m1", "Dune Part Two (2024)"))
        #expect(net.requests.count == count)

        await service.configure(MetadataSettings(tmdbAPIKey: "0123456789abcdef0123456789abcdef"))
        _ = await service.metadata(for: movie("m1", "Dune Part Two (2024)"))
        #expect(net.requests.count > count)
    }

    @Test func clearCacheRemovesEverything() async throws {
        let net = StubNetwork(handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        _ = await service.metadata(for: movie("m1", "Dune Part Two (2024)"))
        _ = await service.metadata(for: movie("m2", "Nothing Here"))
        await service.clearCache()
        #expect(try await db.metadataCacheEntry(mediaId: "m1") == nil)
        #expect(try await db.metadataCacheEntry(mediaId: "m2") == nil)
    }

    @Test func seriesFromCinemetaIncludesEpisodes() async throws {
        let net = StubNetwork(handler: StubNetwork.cinemeta)
        let service = MetadataService(db: db, fetch: net.fetch)
        let office = Series(id: "s2", sourceId: "src", categoryId: nil, name: "The Office (US) [MULTI-SUB]", providerId: "2", providerOrder: 0)
        // No /meta fixture for this id: the search hit itself is used.
        let officeMeta = try #require(await service.metadata(for: office))
        #expect(officeMeta.imdbId == "tt0386676")
        #expect(officeMeta.year == "2005–2013")
        #expect(officeMeta.posterURL?.hasSuffix("@._V1_SX780.jpg") == true)
        let bb = Series(id: "s1", sourceId: "src", categoryId: nil, name: "Breaking Bad", providerId: "1", providerOrder: 0)
        let md = try #require(await service.metadata(for: bb))
        #expect(md.episode(season: 1, number: 2)?.stillURL != nil)
    }

    @Test func metaThatContradictsTheSearchHitIsRejected() async throws {
        let net = StubNetwork { url in
            if url.contains("/catalog/movie/top/search=") {
                return JSONObject(["metas": [["id": "tt5581256", "name": "Inception", "type": "movie"]]])
            }
            if url.hasSuffix("/meta/movie/tt5581256.json") {
                return JSONObject(["meta": ["id": "tt5581256", "name": "Untitled Project", "releaseInfo": "2017"]])
            }
            throw HTTPError.status(404, url: url)
        }
        let service = MetadataService(db: db, fetch: net.fetch)
        #expect(await service.metadata(for: movie("m1", "Inception")) == nil)
        #expect(try await db.metadataCacheEntry(mediaId: "m1")?.notFound == true)
    }

    @Test func validatesKeys() async throws {
        let net = StubNetwork { url in
            if url.contains("api_key=good") || url.contains("/configuration") && !url.contains("api_key") {
                return JSONObject(["images": [String: Any]()])
            }
            throw HTTPError.status(401, url: url)
        }
        let service = MetadataService(db: db, fetch: net.fetch)
        #expect(await service.validateTMDBKey("good") == nil)
        #expect(await service.validateTMDBKey("eyJ.a.b") == nil)
        #expect(await service.validateTMDBKey("bad")?.contains("401") == true)
        #expect(await service.validateTMDBKey("   ") != nil)
    }
}

// MARK: - Online guide catalogue

@Suite("Online guide catalogue")
struct OnlineGuideCatalogTests {
    let guides: [OnlineGuide]

    init() throws {
        let html = String(decoding: try metadataFixture("epgshare01_listing.html"), as: UTF8.self)
        guides = OnlineGuideCatalog.parse(listing: html, baseURL: OnlineGuideCatalog.indexURL)
    }

    func guide(_ id: String) throws -> OnlineGuide {
        try #require(guides.first { $0.id == id })
    }

    @Test func listsEveryGuideFile() throws {
        let html = String(decoding: try metadataFixture("epgshare01_listing.html"), as: UTF8.self)
        let expected = Set(html.components(separatedBy: "href=\"").dropFirst().compactMap { part -> String? in
            let href = String(part.prefix { $0 != "\"" })
            return href.hasSuffix(".xml.gz") ? href : nil
        })
        #expect(guides.count == expected.count)
        #expect(guides.count > 80)
        #expect(Set(guides.map(\.id)) == expected)
    }

    @Test func countries() throws {
        let sa = try guide("epg_ripper_SA1.xml.gz")
        #expect(sa.name == "Saudi Arabia")
        #expect(sa.countryCode == "SA")
        #expect(sa.variant == "1")
        #expect(sa.url == "https://epgshare01.online/epgshare01/epg_ripper_SA1.xml.gz")
        #expect(try guide("epg_ripper_SA2.xml.gz").variant == "2")
        let uk = try guide("epg_ripper_UK1.xml.gz")
        #expect(uk.name == "United Kingdom")
        #expect(uk.countryCode == "GB")
        #expect(uk.variant == nil) // only one UK file
        #expect(try guide("epg_ripper_BE2.xml.gz").variant == nil)
    }

    @Test func specialSources() throws {
        #expect(try guide("epg_ripper_BEIN1.xml.gz").name == "beIN Sports")
        #expect(try guide("epg_ripper_BEIN1.xml.gz").countryCode == nil)
        #expect(try guide("epg_ripper_ALJAZEERA1.xml.gz").name == "Al Jazeera")
        let locals = try guide("epg_ripper_US_LOCALS1.xml.gz")
        #expect(locals.name == "United States — Locals")
        #expect(locals.countryCode == "US")
        #expect(try guide("epg_ripper_US_SPORTS1.xml.gz").name == "United States — Sports")
        #expect(try guide("epg_ripper_ALL_SOURCES1.xml.gz").name == "All Sources (very large)")
        #expect(try guide("epg_ripper_DUMMY_CHANNELS.xml.gz").name == "Dummy Channels")
        #expect(try guide("epg_ripper_viva-russia.ru.xml.gz").name == "Viva Russia")
    }

    /// Every non-country file in the real listing has a hand-picked display name.
    @Test func everyCodeHasAFriendlyName() {
        for g in guides where g.countryCode == nil || g.id.contains("_US_") {
            var code = String(g.id.dropFirst("epg_ripper_".count).dropLast(".xml.gz".count))
            while code.last?.isNumber == true { code.removeLast() }
            #expect(OnlineGuideCatalog.specialNames[code.uppercased()] != nil, "\(g.id) → \(g.name)")
        }
    }

    @Test func sortedByNameThenVariant() {
        for (a, b) in zip(guides, guides.dropFirst()) {
            let order = a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
            #expect(order != .orderedDescending, "\(a.name) before \(b.name)")
            if order == .orderedSame { #expect(Int(a.variant ?? "0")! < Int(b.variant ?? "0")!) }
        }
        let names = guides.map(\.name)
        #expect(names.firstIndex(of: "United States")! < names.firstIndex(of: "United States — Locals")!)
    }

    @Test func parsesOtherListingStyles() {
        let html = """
            <a href='./epg_ripper_FR1.xml.gz'>x</a> <a HREF="https://mirror.example/x/epg_ripper_NEWSOURCE2.xml.gz">y</a>
            <a href="epg%20ripper_DE1.xml.gz">z</a> <a href="epg_ripper_FR1.txt">t</a>
            """
        let parsed = OnlineGuideCatalog.parse(listing: html, baseURL: "https://host/dir/")
        #expect(parsed.map(\.name) == ["EPG Ripper DE", "France", "Newsource"])
        #expect(parsed.first { $0.name == "France" }?.url == "https://host/dir/epg_ripper_FR1.xml.gz")
        #expect(parsed.first { $0.name == "Newsource" }?.url == "https://mirror.example/x/epg_ripper_NEWSOURCE2.xml.gz")
        #expect(parsed.first { $0.name == "Newsource" }?.variant == nil)
    }
}

// MARK: - Cache storage

@Suite("Metadata cache")
struct MetadataCacheTests {
    @Test func roundTripsAndClears() async throws {
        let db = try AppDatabase.inMemory()
        var md = MediaMetadata(kind: .series, source: "TMDB", title: "Breaking Bad")
        md.episodes = [EpisodeMetadata(season: 1, episode: 1, title: "Pilot")]
        md.cast = [CastMember(name: "Bryan Cranston", character: "Walter White")]
        try await db.saveMetadata(md, mediaId: "s1")
        try await db.saveMetadataNotFound(mediaId: "s2", kind: .series)

        let entry = try #require(try await db.metadataCacheEntry(mediaId: "s1"))
        #expect(entry.metadata == md)
        #expect(entry.kind == .series)
        #expect(entry.isFresh())
        let miss = try #require(try await db.metadataCacheEntry(mediaId: "s2"))
        #expect(miss.notFound && miss.metadata == nil && miss.isFresh())

        try await db.markMetadataStale()
        #expect(try await db.metadataCacheEntry(mediaId: "s1")?.isFresh() == false)
        #expect(try await db.metadataCacheEntry(mediaId: "s1")?.metadata == md)

        try await db.clearMetadataCache()
        #expect(try await db.metadataCacheEntry(mediaId: "s1") == nil)
    }
}
