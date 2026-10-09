import Foundation
import Testing
@testable import TunerCore

// MARK: - Netflix files

/// The global file's columns, newest week first (rows as Netflix publishes them, trimmed to a few per list).
private let globalTSV = """
week\tcategory\tweekly_rank\tshow_title\tseason_title\tweekly_hours_viewed\truntime\tweekly_views\tcumulative_weeks_in_top_10
2026-10-04\tFilms (English)\t1\tUNABOMBER\tN/A\t41500000\t1.6667\t24900000\t2
2026-10-04\tFilms (English)\t2\tDoing Life\tN/A\t16800000\t1.8\t9300000\t1
2026-10-04\tFilms (Non-English)\t1\tKill Shot\tN/A\t20000000\t1.7\t12000000\t1
2026-10-04\tFilms (Non-English)\t2\tAnora\tN/A\t8000000\t1.6\t5000000\t4
2026-10-04\tTV (English)\t1\tWednesday\tWednesday: Season 2\t50000000\t8\t6000000\t3
2026-10-04\tTV (English)\t2\tWednesday\tWednesday: Season 1\t9000000\t8\t1100000\t3
2026-10-04\tTV (Non-English)\t1\tThe Assassins\tThe Assassins: Season 1\t30000000\t6\t5000000\t1
2026-09-27\tFilms (English)\t1\tOld Week Film\tN/A\t1\t1\t99999999\t1

"""

private let countriesTSV = """
country_name\tcountry_iso2\tweek\tcategory\tweekly_rank\tshow_title\tseason_title\tcumulative_weeks_in_top_10
Argentina\tAR\t2026-10-04\tFilms\t1\tArgentine Film\tN/A\t2
Egypt\tEG\t2026-10-04\tFilms\t2\tThe Mummy\tN/A\t1
Egypt\tEG\t2026-10-04\tFilms\t1\tUNABOMBER\tN/A\t2
Egypt\tEG\t2026-10-04\tTV\t1\tNot a Stranger\tNot a Stranger: Season 1\t3
Egypt\tEG\t2026-10-04\tTV\t2\tThe Gentlemen\tThe Gentlemen: Season 2\t5
Egypt\tEG\t2026-10-04\tTV\t3\tThe Gentlemen\tThe Gentlemen: Season 1\t22
Egypt\tEG\t2026-09-27\tFilms\t1\tLast Week\tN/A\t1
Finland\tFI\t2026-10-04\tFilms\t1\tFinnish Film\tN/A\t1
"""

/// Feeds lines to a parser like the live fetcher; returns the parser and how many lines it read.
private func parse(_ text: String, country: String?) -> (NetflixTop10.LatestWeekParser, read: Int) {
    var parser = NetflixTop10.LatestWeekParser(country: country)
    var read = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        read += 1
        if !parser.consume(String(line)) { break }
    }
    return (parser, read)
}

@Suite("Top 10: Netflix files")
struct NetflixTop10Tests {
    @Test func globalKeepsTheNewestWeekMergedByViews() throws {
        let (parser, read) = parse(globalTSV, country: nil)
        let chart = try #require(parser.chart())
        #expect(chart.source == .netflixGlobal)
        #expect(chart.week == "2026-10-04")
        // English and non-English lists merged by weekly views.
        #expect(chart.movies.map(\.title) == ["UNABOMBER", "Kill Shot", "Doing Life", "Anora"])
        // One entry per show (its best season), by views.
        #expect(chart.series.map(\.title) == ["Wednesday", "The Assassins"])
        // Stopped at the first row of the previous week.
        #expect(read == 9)
    }

    @Test func countryKeepsItsNewestWeekAndStopsThere() throws {
        let (parser, read) = parse(countriesTSV, country: "eg")
        let chart = try #require(parser.chart())
        #expect(chart.source == .netflixCountry("EG"))
        #expect(chart.movies.map(\.title) == ["UNABOMBER", "The Mummy"])
        #expect(chart.series.map(\.title) == ["Not a Stranger", "The Gentlemen"])
        #expect(chart.movies.allSatisfy { $0.year == nil && $0.imdbId == nil })
        #expect(read == 8) // the older Egypt week ends it; Finland is never read
    }

    @Test func aCountryAtTheEndOfTheFileIsFound() throws {
        let (parser, _) = parse(countriesTSV, country: "FI")
        #expect(try #require(parser.chart()).movies.map(\.title) == ["Finnish Film"])
        #expect(parse(countriesTSV, country: "US").0.chart() == nil)
    }

    @Test func somethingElseIsNotAChart() {
        let (parser, read) = parse("<!DOCTYPE html>\n<html>\n<body>Blocked</body>", country: nil)
        #expect(parser.chart() == nil)
        #expect(read == 1)
    }

    @Test func weekEndIsTheSunday() throws {
        let end = try #require(NetflixTop10.weekEnd("2026-10-04"))
        #expect(end == Date(timeIntervalSince1970: 1_791_072_000)) // 2026-10-04T00:00:00Z
        #expect(NetflixTop10.weekEnd("soon") == nil)
    }
}

// MARK: - Other lists

@Suite("Top 10: Cinemeta, TMDB and regions")
struct PopularListTests {
    @Test func cinemetaPopularCarriesIMDbIdsAndYears() {
        let json = JSONObject(["metas": [
            ["imdb_id": "tt6933238", "id": "tt6933238", "name": "Unabomber", "releaseInfo": "2026", "moviedb_id": 123],
            ["id": "tt26545992", "name": "Lanterns", "releaseInfo": "2026–"],
            ["id": "x", "name": ""],
        ]])
        let entries = CinemetaClient.parsePopular(json)
        #expect(entries == [
            ChartEntry(title: "Unabomber", year: 2026, imdbId: "tt6933238", tmdbId: "123"),
            ChartEntry(title: "Lanterns", year: 2026, imdbId: "tt26545992"),
        ])
    }

    @Test func tmdbTrendingKeepsOriginalTitles() {
        let movies = JSONObject(["results": [
            ["id": 1, "title": "The Assassins", "original_title": "الحشاشين", "release_date": "2024-03-11"],
            ["id": 2, "title": "Dune", "original_title": "Dune", "release_date": ""],
        ]])
        #expect(TMDBClient.parseTrending(movies, kind: .movie) == [
            ChartEntry(title: "The Assassins", originalTitle: "الحشاشين", year: 2024, tmdbId: "1"),
            ChartEntry(title: "Dune", tmdbId: "2"),
        ])
        let shows = JSONObject(["results": [["id": 7, "name": "Wednesday", "original_name": "Wednesday", "first_air_date": "2022-11-23"]]])
        #expect(TMDBClient.parseTrending(shows, kind: .series) == [ChartEntry(title: "Wednesday", year: 2022, tmdbId: "7")])
    }

    @Test func regionsTryNetflixFirstThenPopularLists() {
        #expect(TopTenRegion.automatic.chain(deviceRegion: "EG", hasTMDBKey: false) == [.netflixCountry("EG"), .netflixGlobal, .cinemetaPopular])
        // No Netflix list for the region: worldwide.
        #expect(TopTenRegion.automatic.chain(deviceRegion: "SY", hasTMDBKey: true) == [.netflixGlobal, .tmdbTrending, .cinemetaPopular])
        #expect(TopTenRegion.automatic.chain(deviceRegion: nil, hasTMDBKey: false) == [.netflixGlobal, .cinemetaPopular])
        #expect(TopTenRegion(preference: "sa").chain(deviceRegion: "US", hasTMDBKey: false) == [.netflixCountry("SA"), .netflixGlobal, .cinemetaPopular])
        #expect(TopTenRegion(preference: "popular").chain(deviceRegion: "EG", hasTMDBKey: true) == [.tmdbTrending, .cinemetaPopular])
        #expect(TopTenRegion(preference: "global") == .worldwide)
        #expect(TopTenRegion(preference: "") == .automatic)
        #expect(TopTenRegion.country("AE").preference == "AE")
    }
}

// MARK: - Matching

private func candidate(_ id: String, _ name: String, year: String? = nil, source: String = "src", imdb: String? = nil,
                       tmdb: String? = nil, artwork: Bool = true) -> TopTenMatcher.Candidate {
    TopTenMatcher.Candidate(mediaId: id, name: name, year: year, sourceId: source, imdbId: imdb, tmdbId: tmdb, hasArtwork: artwork)
}

@Suite("Top 10: matching")
struct TopTenMatcherTests {
    @Test func providerNamesMatchAfterCleaning() {
        let library = [candidate("a", "EN - Anora (2024) 4K"), candidate("b", "|AR| UNABOMBER"), candidate("c", "Matrix, The")]
        let ids = TopTenMatcher.match([ChartEntry(title: "Unabomber"), ChartEntry(title: "Anora"), ChartEntry(title: "The Matrix")],
                                      kind: .movie, candidates: library)
        #expect(ids == ["b", "a", "c"])
    }

    @Test func showsMatchWhateverTheSeasonSuffix() {
        let library = [candidate("w", "Wednesday S02"), candidate("g", "The Gentlemen - Season 1")]
        let ids = TopTenMatcher.match([ChartEntry(title: "The Gentlemen"), ChartEntry(title: "Wednesday: Season 2")],
                                      kind: .series, candidates: library)
        #expect(ids == ["g", "w"])
    }

    @Test func partialTitlesNeverMatch() {
        let library = [candidate("s", "Stranger Things"), candidate("m", "Mission: Impossible - Dead Reckoning")]
        let entries = [ChartEntry(title: "Not a Stranger"), ChartEntry(title: "Mission: Impossible"), ChartEntry(title: "Stranger")]
        #expect(TopTenMatcher.match(entries, kind: .movie, candidates: library).isEmpty)
    }

    @Test func aTitleWithoutYearMatchingSeveralFilmsIsSkipped() {
        let library = [candidate("old", "The Mummy (1999)"), candidate("new", "The Mummy 2026")]
        #expect(TopTenMatcher.match([ChartEntry(title: "The Mummy")], kind: .movie, candidates: library).isEmpty)
        // With a year, the right one.
        #expect(TopTenMatcher.match([ChartEntry(title: "The Mummy", year: 2026)], kind: .movie, candidates: library) == ["new"])
    }

    @Test func yearsMustAgree() {
        let library = [candidate("old", "The Mummy", year: "1999")]
        #expect(TopTenMatcher.match([ChartEntry(title: "The Mummy", year: 2026)], kind: .movie, candidates: library).isEmpty)
        #expect(TopTenMatcher.match([ChartEntry(title: "The Mummy", year: 2000)], kind: .movie, candidates: library) == ["old"])
        // A show's later season is still the show.
        let show = [candidate("s", "The Gentlemen S02", year: "2026")]
        #expect(TopTenMatcher.match([ChartEntry(title: "The Gentlemen", year: 2024)], kind: .series, candidates: show) == ["s"])
        #expect(TopTenMatcher.match([ChartEntry(title: "The Gentlemen", year: 2030)], kind: .series, candidates: show).isEmpty)
    }

    @Test func idsWinAndRuleOutNamesakes() {
        let library = [
            candidate("arabic", "مسلسل الحشاشين", imdb: "tt31000000"),
            candidate("namesake", "The Mummy", imdb: "tt0120616"),
            candidate("provider", "Some Film", tmdb: "42"),
        ]
        let entries = [
            ChartEntry(title: "The Assassins", imdbId: "tt31000000"),
            ChartEntry(title: "The Mummy", imdbId: "tt99999999"),
            ChartEntry(title: "Another Name", tmdbId: "42"),
        ]
        #expect(TopTenMatcher.match(entries, kind: .series, candidates: library) == ["arabic", "provider"])
    }

    @Test func bilingualAndArabicNamesMatch() {
        let library = [candidate("bi", "The Assassins | الحشاشين"), candidate("ar", "جعفر العمدة"), candidate("mix", "الحريفة The Harifa 2")]
        let entries = [
            ChartEntry(title: "Jaafar Al Omda", originalTitle: "جعفر العمدة"),
            ChartEntry(title: "The Assassins"),
            ChartEntry(title: "The Harifa 2"),
        ]
        #expect(TopTenMatcher.match(entries, kind: .series, candidates: library) == ["ar", "bi", "mix"])
    }

    @Test func duplicatesComeFromTheMostWatchedPlaylist() {
        let library = [
            candidate("a1", "Anora", source: "a"),
            candidate("b1", "Anora", source: "b"),
            candidate("b2", "4K: Anora", source: "b", artwork: false),
        ]
        #expect(TopTenMatcher.match([ChartEntry(title: "Anora")], kind: .movie, candidates: library, sourceUsage: ["b": 5, "a": 1]) == ["b1"])
        #expect(TopTenMatcher.match([ChartEntry(title: "Anora")], kind: .movie, candidates: library) == ["a1"])
    }

    @Test func eachItemOnceAndAtMostTheLimit() {
        let library = (1...12).map { candidate("m\($0)", "Film Number \($0)") } + [candidate("w", "Wednesday")]
        let entries = [ChartEntry(title: "Wednesday"), ChartEntry(title: "Wednesday")] + (1...12).map { ChartEntry(title: "Film Number \($0)") }
        let ids = TopTenMatcher.match(entries, kind: .movie, candidates: library)
        #expect(ids.count == 10)
        #expect(ids.first == "w")
        #expect(Set(ids).count == 10)
    }

    @Test func searchWordsAreDistinctive() {
        #expect(TopTenMatcher.searchWord("Not a Stranger", kind: .series) == "Stranger")
        #expect(TopTenMatcher.searchWord("The Gentlemen: Season 2", kind: .series) == "Gentlemen")
        #expect(TopTenMatcher.searchWord("F1", kind: .movie) == "F1")
        #expect(TopTenMatcher.searchWord("الحشاشين", kind: .series) == "الحشاشين")
    }
}

// MARK: - Service

/// Serves Netflix files from strings and counts requests per URL.
final class StubNetflix: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _conditional: [String?] = []
    var files: [String: String]
    var notModified = false
    var failing = false

    init(files: [String: String]) { self.files = files }

    var requests: [String] { lock.withLock { _requests } }
    var conditional: [String?] { lock.withLock { _conditional } }

    var fetch: NetflixLinesFetch {
        { url, ifModifiedSince, parser, _ in
            self.lock.withLock {
                self._requests.append(url)
                self._conditional.append(ifModifiedSince)
            }
            if self.failing { throw URLError(.timedOut) }
            if self.notModified, ifModifiedSince != nil { return .notModified }
            guard let text = self.files[url] else { throw HTTPError.status(404, url: url) }
            var parser = parser
            for line in text.split(separator: "\n") where !parser.consume(String(line)) { break }
            return .parsed(parser, lastModified: "Tue, 06 Oct 2026 18:55:55 GMT")
        }
    }
}

final class ChartClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

@Suite("Top 10: service")
struct TopTenServiceTests {
    let db: AppDatabase
    /// Thursday after the week ending 2026-10-04.
    let clock = ChartClock(Date(timeIntervalSince1970: 1_791_072_000 + 4 * 86_400))

    init() async throws {
        db = try AppDatabase.inMemory()
        try await db.save(Source(id: "src", name: "Test", kind: .m3u, url: "http://example.com/list.m3u"))
        let films = Category(id: "src_films", sourceId: "src", kind: .movie, name: "Films", providerOrder: 0)
        let hidden = Category(id: "src_hidden", sourceId: "src", kind: .movie, name: "Hidden", providerOrder: 1)
        let movies = [
            movie("m-unabomber", "UNABOMBER (2026)"),
            movie("m-mummy", "The Mummy", year: "2026"),
            movie("m-kill", "Kill Shot"),
            movie("m-doing", "Doing Life", category: "src_hidden"),
            movie("m-anora", "EN - Anora [4K]"),
        ]
        let shows = [series("s-wed", "Wednesday S01"), series("s-gent", "The Gentlemen")]
        try await db.replaceVOD(sourceId: "src", movieCategories: [films, hidden], movies: movies, seriesCategories: [], series: shows)
        try await db.setCategoryHidden(categoryId: "src_hidden", true)
    }

    func movie(_ id: String, _ name: String, year: String? = nil, category: String = "src_films") -> Movie {
        var m = Movie(id: id, sourceId: "src", categoryId: category, name: name, providerId: id, providerOrder: 0)
        m.year = year
        return m
    }

    func series(_ id: String, _ name: String) -> Series {
        Series(id: id, sourceId: "src", categoryId: nil, name: name, providerId: id, providerOrder: 0)
    }

    func settings(_ region: TopTenRegion = .country("EG"), offline: Bool = false) -> TopTenService.Settings {
        TopTenService.Settings(region: region, deviceRegion: "US", tmdbAPIKey: nil, language: "en-US",
                               hideAdultContent: false, offline: offline)
    }

    func service(_ netflix: StubNetflix, json: StubNetwork = StubNetwork { _ in JSONObject(["metas": [Any]()]) }) -> TopTenService {
        let clock = clock
        return TopTenService(db: db, fetchJSON: json.fetch, fetchLines: netflix.fetch, now: { clock.now })
    }

    @Test func rowsFollowTheFirstChartThatMatchesEnough() async throws {
        let netflix = StubNetflix(files: [NetflixTop10.countriesURL: countriesTSV, NetflixTop10.globalURL: globalTSV])
        let rows = await service(netflix).rows(settings())
        // Egypt matches only two films and one show: the global list is used, without the hidden "Doing Life".
        let movies = try #require(rows.movies)
        #expect(movies.source == .netflixGlobal)
        #expect(movies.week == "2026-10-04")
        #expect(movies.items.map(\.id) == ["m-unabomber", "m-kill", "m-anora"])
        #expect(rows.series == nil) // Wednesday alone
        #expect(netflix.requests == [NetflixTop10.countriesURL, NetflixTop10.globalURL])
    }

    @Test func aCountryListThatMatchesIsUsedAndCached() async throws {
        let egypt = countriesTSV.replacingOccurrences(of: "Egypt\tEG\t2026-10-04\tTV\t3\tThe Gentlemen\tThe Gentlemen: Season 1\t22",
                                                      with: "Egypt\tEG\t2026-10-04\tTV\t3\tWednesday\tWednesday: Season 1\t22\nEgypt\tEG\t2026-10-04\tTV\t4\tKill Shot\tN/A\t1")
            .replacingOccurrences(of: "Egypt\tEG\t2026-10-04\tFilms\t1\tUNABOMBER\tN/A\t2",
                                  with: "Egypt\tEG\t2026-10-04\tFilms\t1\tUNABOMBER\tN/A\t2\nEgypt\tEG\t2026-10-04\tFilms\t3\tKill Shot\tN/A\t2")
        let netflix = StubNetflix(files: [NetflixTop10.countriesURL: egypt, NetflixTop10.globalURL: globalTSV])
        let service = service(netflix)
        let rows = await service.rows(settings())
        let movies = try #require(rows.movies)
        #expect(movies.source == .netflixCountry("EG"))
        #expect(movies.items.map(\.id) == ["m-unabomber", "m-mummy", "m-kill"])
        #expect(rows.series == nil) // "Kill Shot" is a film here; Wednesday + The Gentlemen are only two shows

        // Same week: no new requests, even from a new service (the chart is in the database).
        let before = netflix.requests.count
        _ = await service.rows(settings())
        _ = await self.service(netflix).rows(settings())
        #expect(netflix.requests.count == before)
    }

    @Test func netflixIsCheckedAgainOnlyWhenTheNextWeekCanExist() async throws {
        let netflix = StubNetflix(files: [NetflixTop10.globalURL: globalTSV])
        let service = service(netflix)
        let movieCount = { (rows: TopTenService.Rows) in rows.movies?.items.count ?? 0 }
        #expect(movieCount(await service.rows(settings(.worldwide))) == 3)
        #expect(netflix.requests.count == 1)

        clock.now = clock.now.addingTimeInterval(86_400) // Friday: the next week isn't out until Tuesday
        _ = await service.rows(settings(.worldwide))
        #expect(netflix.requests.count == 1)

        clock.now = Date(timeIntervalSince1970: 1_791_072_000 + 9 * 86_400 + 19 * 3600) // Tuesday evening
        netflix.notModified = true
        #expect(movieCount(await service.rows(settings(.worldwide))) == 3)
        #expect(netflix.requests.count == 2)
        #expect(netflix.conditional.last == "Tue, 06 Oct 2026 18:55:55 GMT")

        // Not modified: asked again 12 hours later at the earliest.
        clock.now = clock.now.addingTimeInterval(6 * 3600)
        _ = await service.rows(settings(.worldwide))
        #expect(netflix.requests.count == 2)
    }

    @Test func offlineAndFailuresUseTheLastList() async throws {
        let netflix = StubNetflix(files: [NetflixTop10.globalURL: globalTSV])
        let service = service(netflix)
        #expect(await service.rows(settings(.worldwide, offline: true)).movies == nil)
        #expect(netflix.requests.isEmpty)

        _ = await service.rows(settings(.worldwide))
        clock.now = Date(timeIntervalSince1970: 1_791_072_000 + 10 * 86_400)
        netflix.failing = true
        #expect(await service.rows(settings(.worldwide)).movies?.items.count == 3)
        #expect(netflix.requests.count == 2)
        // Not retried right away after a failure.
        _ = await service.rows(settings(.worldwide))
        #expect(netflix.requests.count == 2)
    }

    @Test func adultCategoriesAreLeftOutWhenHidden() async throws {
        let adult = Category(id: "src_adult", sourceId: "src", kind: .movie, name: "XXX Adults +18", providerOrder: 2)
        try await db.replaceMovies(sourceId: "src", categories: [adult], movies: [
            movie("m-unabomber", "UNABOMBER"), movie("m-kill", "Kill Shot"), movie("m-anora", "Anora", category: "src_adult"),
        ])
        let service = service(StubNetflix(files: [NetflixTop10.globalURL: globalTSV]))
        var hiding = settings(.worldwide)
        hiding.hideAdultContent = true
        #expect(await service.rows(hiding).movies == nil)
        #expect(await service.rows(settings(.worldwide)).movies?.items.map(\.id) == ["m-unabomber", "m-kill", "m-anora"])
    }

    @Test func aListFromWeeksAgoIsNotThisWeek() async throws {
        let netflix = StubNetflix(files: [NetflixTop10.globalURL: globalTSV])
        let service = service(netflix)
        _ = await service.rows(settings(.worldwide))
        clock.now = clock.now.addingTimeInterval(60 * 86_400)
        #expect(await service.rows(settings(.worldwide, offline: true)).movies == nil)
    }

    @Test func idsFromCachedMetadataMatchCinemetaLists() async throws {
        var md = MediaMetadata(kind: .series, source: "Cinemeta", title: "The Gentlemen")
        md.imdbId = "tt13210838"
        try await db.saveMetadata(md, mediaId: "s-gent")
        let metas: [[String: Any]] = [
            ["imdb_id": "tt13210838", "name": "Gentlemen, The (Series)", "releaseInfo": "2024–"],
            ["imdb_id": "tt13443470", "name": "Wednesday", "releaseInfo": "2022–"],
            ["imdb_id": "tt0000001", "name": "Unknown Show", "releaseInfo": "2020"],
        ]
        let list = JSONObject(["metas": metas])
        let json = StubNetwork { url in
            url.contains("/catalog/series/") ? list : JSONObject(["metas": [Any]()])
        }
        let rows = await service(StubNetflix(files: [:]), json: json).rows(settings(.popular))
        // Two matches are not enough for a row.
        #expect(rows.series == nil)
        #expect(json.requests.count == 2)
        let entries = CinemetaClient.parsePopular(list)
        let ids = await service(StubNetflix(files: [:]), json: json).match(entries, kind: .series, hideAdult: false, usage: [:])
        #expect(ids == ["s-gent", "s-wed"])
    }
}
