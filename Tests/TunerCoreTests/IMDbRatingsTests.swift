import Foundation
import GRDB
import Testing
@testable import TunerCore

func imdbFixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/imdb"))
}

/// What the fixtures hold for the series the tests ask about.
enum IMDbFixture {
    static let breakingBad = "tt0903747"
    static let jujutsuKaisen = "tt12343534"
    static let duplicated = "tt0108778"
    static let nothingRated = "tt7000000"
    static let absent = "tt7777777"

    static let breakingBadRatings = [
        EpisodeRating(season: 1, episode: 1, rating: 9.0, votes: 45000),
        EpisodeRating(season: 1, episode: 2, rating: 8.6, votes: 32000),
        EpisodeRating(season: 2, episode: 1, rating: 8.3, votes: 28000),
        EpisodeRating(season: 2, episode: 3, rating: 10, votes: 5),
    ]
    static let jujutsuKaisenRatings = [
        EpisodeRating(season: 1, episode: 1, rating: 8.7, votes: 12000),
        EpisodeRating(season: 1, episode: 2, rating: 8.4, votes: 11000),
        EpisodeRating(season: 3, episode: 5, rating: 9.4, votes: 30000),
    ]
    static let duplicatedRatings = [
        EpisodeRating(season: 0, episode: 12, rating: 6.25, votes: 7),
        EpisodeRating(season: 1, episode: 1, rating: 7.9, votes: 1200),
    ]
}

// MARK: - Scanner

@Suite("IMDb dataset scanner")
struct IMDbDatasetScannerTests {
    @Test func fixturesAreBundledGzip() throws {
        for name in IMDbDataset.allCases.map(\.fileName) {
            #expect(Gzip.isGzipped(fileAt: try imdbFixture(name)))
        }
    }

    @Test func episodesOfTheRequestedSeriesOnly() throws {
        let episodes = try IMDbDatasetScanner.episodes(inGzipFile: imdbFixture("title.episode.tsv.gz"), seriesNumbers: [903747])
        // `\N` seasons/episodes are skipped; look-alike parents (tt09037470, tt0903740) and the series id appearing
        // as an episode id don't match.
        let expected: [Int: IMDbDatasetScanner.EpisodeRef] = [
            959621: .init(series: 903747, season: 1, episode: 1),
            1054724: .init(series: 903747, season: 1, episode: 2),
            1054725: .init(series: 903747, season: 2, episode: 1),
            1054726: .init(series: 903747, season: 2, episode: 2),
            1232248: .init(series: 903747, season: 2, episode: 3),
        ]
        #expect(episodes == expected)
    }

    @Test func ratingsAreJoinedForRequestedSeriesOnly() throws {
        let results = try IMDbDatasetScanner.scan(
            episodesFile: imdbFixture("title.episode.tsv.gz"), ratingsFile: imdbFixture("title.ratings.tsv.gz"),
            seriesIds: [IMDbFixture.breakingBad, IMDbFixture.jujutsuKaisen, IMDbFixture.duplicated,
                        IMDbFixture.nothingRated, IMDbFixture.absent, "not-an-id"])
        let expected: [String: [EpisodeRating]] = [
            IMDbFixture.breakingBad: IMDbFixture.breakingBadRatings,
            IMDbFixture.jujutsuKaisen: IMDbFixture.jujutsuKaisenRatings,
            IMDbFixture.duplicated: IMDbFixture.duplicatedRatings,
            IMDbFixture.nothingRated: [],
            IMDbFixture.absent: [],
        ]
        #expect(results == expected)
    }

    @Test func manySeriesAtOnceMatchesOneByOne() throws {
        let episodes = try imdbFixture("title.episode.tsv.gz")
        let ratings = try imdbFixture("title.ratings.tsv.gz")
        // More than a handful of series switches the parent check from direct comparison to a set lookup.
        let ids: Set<String> = [IMDbFixture.breakingBad, IMDbFixture.jujutsuKaisen, IMDbFixture.duplicated,
                                IMDbFixture.nothingRated, "tt5000000", "tt0903740", "tt9", "tt1", "tt2", "tt3"]
        let together = try IMDbDatasetScanner.scan(episodesFile: episodes, ratingsFile: ratings, seriesIds: ids)
        for id in ids {
            #expect(together[id] == (try IMDbDatasetScanner.scan(episodesFile: episodes, ratingsFile: ratings, seriesIds: [id]))[id])
        }
        #expect(together["tt5000000"] == [EpisodeRating(season: 1, episode: 1, rating: 9.5, votes: 2_400_000)])
    }

    @Test func linesSurviveTinyBuffers() throws {
        let url = try imdbFixture("title.episode.tsv.gz")
        var expected: [String] = []
        try GzipLines.forEach(inFile: url) { expected.append(String(decoding: $0, as: UTF8.self)) }
        #expect(expected.count == 20)
        #expect(expected.first == "tconst\tparentTconst\tseasonNumber\tepisodeNumber")
        #expect(expected.last == "tt3000003\ttt0108778\t0\t12") // no trailing newline in the file

        for size in [1, 7, 16, 33] {
            var lines: [String] = []
            try GzipLines.forEach(inFile: url, bufferSize: size) { lines.append(String(decoding: $0, as: UTF8.self)) }
            #expect(lines == expected)
            let results = try IMDbDatasetScanner.scan(episodesFile: url, ratingsFile: imdbFixture("title.ratings.tsv.gz"),
                                                      seriesIds: [IMDbFixture.breakingBad], bufferSize: size)
            #expect(results[IMDbFixture.breakingBad] == IMDbFixture.breakingBadRatings)
        }
    }

    @Test func plainAndTruncatedFilesAreRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tuner-imdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plain = dir.appendingPathComponent("plain.tsv.gz")
        try Data("<html>Service Unavailable</html>\n".utf8).write(to: plain)
        #expect(throws: IMDbDatasetError.notGzip) { try GzipLines.forEach(inFile: plain) { _ in } }

        let gz = try Data(contentsOf: imdbFixture("title.episode.tsv.gz"))
        let truncated = dir.appendingPathComponent("truncated.tsv.gz")
        try gz.prefix(gz.count - 12).write(to: truncated)
        #expect(throws: IMDbDatasetError.corrupt) { try GzipLines.forEach(inFile: truncated) { _ in } }

        #expect(throws: IMDbDatasetError.unreadable) {
            try GzipLines.forEach(inFile: dir.appendingPathComponent("missing.gz")) { _ in }
        }
    }

    @Test func titleIds() {
        #expect(IMDbDatasetScanner.titleNumber("tt0903747") == 903747)
        #expect(IMDbDatasetScanner.titleNumber("tt12343534") == 12343534)
        #expect(IMDbDatasetScanner.titleNumber("tt") == nil)
        #expect(IMDbDatasetScanner.titleNumber("nm0000001") == nil)
        #expect(IMDbDatasetScanner.titleNumber("tt0903747x") == nil)
        #expect(IMDbDatasetScanner.titleNumber("tt1234567890123") == nil)
        #expect(IMDbRatingsService.normalizedId(" TT0903747\n") == "tt0903747")
        #expect(IMDbRatingsService.normalizedId("https://www.imdb.com/title/tt0903747/") == nil)
    }
}

// MARK: - Service (stubbed downloads)

/// Serves the fixture datasets instead of the network; counts downloads per file. Can fail or serve other bytes.
final class StubDatasets: @unchecked Sendable {
    private let lock = NSLock()
    private var _downloads: [String] = []
    private var _failing = false
    private var _overrides: [String: Data] = [:]
    let delay: Duration

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    var downloads: [String] { lock.withLock { _downloads } }
    func downloads(of dataset: IMDbDataset) -> Int { downloads.filter { $0 == dataset.fileName }.count }

    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    func serve(_ data: Data?, for dataset: IMDbDataset) {
        lock.withLock { _overrides[dataset.fileName] = data }
    }

    var download: @Sendable (URL, URL) async throws -> Void {
        { url, destination in
            let name = url.lastPathComponent
            let (fail, override) = self.lock.withLock {
                self._downloads.append(name)
                return (self._failing, self._overrides[name])
            }
            if self.delay > .zero { try await Task.sleep(for: self.delay) }
            if fail { throw URLError(.notConnectedToInternet) }
            if let override {
                try override.write(to: destination)
            } else {
                try FileManager.default.copyItem(at: try imdbFixture(name), to: destination)
            }
        }
    }
}

/// A clock the tests move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    func advance(days: Double) { lock.withLock { current += days * 86_400 } }

    var now: @Sendable () -> Date { { self.lock.withLock { self.current } } }
}

@Suite("IMDb ratings service")
final class IMDbRatingsServiceTests: Sendable {
    let db: AppDatabase
    let directory: URL
    let clock = TestClock()

    init() throws {
        db = try AppDatabase.inMemory()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tuner-imdb-\(UUID().uuidString)")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func service(_ stub: StubDatasets) -> IMDbRatingsService {
        IMDbRatingsService(db: db, directory: directory, download: stub.download, now: clock.now)
    }

    @Test func downloadsScansAndCaches() async throws {
        let stub = StubDatasets()
        let service = service(stub)
        #expect(await service.cachedRatings(seriesIMDbId: IMDbFixture.breakingBad) == [])

        #expect(await service.ratings(seriesIMDbId: IMDbFixture.breakingBad) == IMDbFixture.breakingBadRatings)
        #expect(stub.downloads(of: .episodes) == 1)
        #expect(stub.downloads(of: .ratings) == 1)
        #expect(await service.scanCount == 1)
        #expect(await service.cachedRatings(seriesIMDbId: IMDbFixture.breakingBad) == IMDbFixture.breakingBadRatings)
        // Files are kept in the directory, with no partial downloads left behind.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == ["title.episode.tsv.gz", "title.ratings.tsv.gz"])
    }

    @Test func cacheHitNeedsNoScanOrDownload() async throws {
        let stub = StubDatasets()
        let service = service(stub)
        _ = await service.ratings(seriesIMDbId: IMDbFixture.breakingBad)
        // Without the files, only the cache can answer.
        try FileManager.default.removeItem(at: directory)
        clock.advance(days: 6.9)

        #expect(await service.ratings(seriesIMDbId: IMDbFixture.breakingBad) == IMDbFixture.breakingBadRatings)
        #expect(await service.ratings(seriesIMDbId: " TT0903747 ") == IMDbFixture.breakingBadRatings)
        #expect(stub.downloads.count == 2)
        #expect(await service.scanCount == 1)

        // The cache survives the service (it's in the database).
        let fresh = IMDbRatingsService(db: db, directory: directory, download: stub.download, now: clock.now)
        #expect(await fresh.ratings(seriesIMDbId: IMDbFixture.breakingBad) == IMDbFixture.breakingBadRatings)
        #expect(await fresh.scanCount == 0)
    }

    @Test func noRatedEpisodesIsCachedToo() async throws {
        let stub = StubDatasets()
        let service = service(stub)
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.nothingRated) == [])
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.absent) == [])
        #expect(await service.scanCount == 2)

        #expect(await service.ratings(seriesIMDbId: IMDbFixture.nothingRated) == [])
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.absent) == [])
        #expect(await service.scanCount == 2)
        #expect(try await db.imdbRatingsCacheEntry(seriesId: IMDbFixture.nothingRated)?.ratings == [])
    }

    @Test func staleAfterSevenDays() async throws {
        let stub = StubDatasets()
        let service = service(stub)
        _ = await service.ratings(seriesIMDbId: IMDbFixture.breakingBad)
        clock.advance(days: 6)
        _ = await service.ratings(seriesIMDbId: IMDbFixture.breakingBad)
        #expect(stub.downloads.count == 2)
        #expect(await service.scanCount == 1)

        // Day 8: the files are stale, so a new series refreshes them first.
        clock.advance(days: 2)
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.jujutsuKaisen) == IMDbFixture.jujutsuKaisenRatings)
        #expect(stub.downloads(of: .episodes) == 2)
        #expect(stub.downloads(of: .ratings) == 2)
        #expect(await service.scanCount == 2)

        // The day-0 scan is stale too; the files are fresh now, so it's rescanned without a download.
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.breakingBad) == IMDbFixture.breakingBadRatings)
        #expect(stub.downloads.count == 4)
        #expect(await service.scanCount == 3)
        let entry = try #require(try await db.imdbRatingsCacheEntry(seriesId: IMDbFixture.breakingBad))
        #expect(entry.scannedAt == clock.now())
    }

    @Test func concurrentCallsShareDownloads() async throws {
        let stub = StubDatasets(delay: .milliseconds(150))
        let service = service(stub)
        let ids = [IMDbFixture.breakingBad, IMDbFixture.jujutsuKaisen, IMDbFixture.breakingBad, IMDbFixture.duplicated,
                   IMDbFixture.jujutsuKaisen, IMDbFixture.breakingBad, IMDbFixture.nothingRated, IMDbFixture.breakingBad]
        let results = await withTaskGroup(of: (String, [EpisodeRating]).self) { group in
            for id in ids {
                group.addTask { (id, await service.ratings(seriesIMDbId: id)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == ids.count)
        let expected = [IMDbFixture.breakingBad: IMDbFixture.breakingBadRatings,
                        IMDbFixture.jujutsuKaisen: IMDbFixture.jujutsuKaisenRatings,
                        IMDbFixture.duplicated: IMDbFixture.duplicatedRatings,
                        IMDbFixture.nothingRated: []]
        for (id, ratings) in results {
            #expect(ratings == expected[id])
        }
        #expect(stub.downloads(of: .episodes) == 1)
        #expect(stub.downloads(of: .ratings) == 1)
        // Series requested while a scan runs are batched into the next one.
        #expect(await service.scanCount <= 2)
    }

    @Test func failedDownloadReturnsEmptyAndCachesNothing() async throws {
        let stub = StubDatasets()
        stub.failing = true
        let service = service(stub)
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.breakingBad) == [])
        #expect(await service.scanCount == 0)
        #expect(try await db.imdbRatingsCacheEntry(seriesId: IMDbFixture.breakingBad) == nil)
        #expect(await service.cachedRatings(seriesIMDbId: IMDbFixture.breakingBad) == [])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("title.episode.tsv.gz.download").path))

        // Without a previous copy, the next request tries again.
        stub.failing = false
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.breakingBad) == IMDbFixture.breakingBadRatings)
        #expect(stub.downloads.count == 4)
    }

    @Test func failedRefreshKeepsUsingThePreviousFiles() async throws {
        let stub = StubDatasets()
        let service = service(stub)
        _ = await service.ratings(seriesIMDbId: IMDbFixture.breakingBad)
        clock.advance(days: 8)
        stub.failing = true

        #expect(await service.ratings(seriesIMDbId: IMDbFixture.jujutsuKaisen) == IMDbFixture.jujutsuKaisenRatings)
        #expect(stub.downloads.count == 4)
        // A failed refresh isn't retried for a while; the old files keep answering.
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.duplicated) == IMDbFixture.duplicatedRatings)
        #expect(stub.downloads.count == 4)
        clock.advance(days: 0.1)
        stub.failing = false
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.nothingRated) == [])
        #expect(stub.downloads.count == 6)
    }

    @Test func staleCacheIsReturnedWhenDatasetsAreUnavailable() async throws {
        let stub = StubDatasets()
        let service = service(stub)
        _ = await service.ratings(seriesIMDbId: IMDbFixture.breakingBad)
        try FileManager.default.removeItem(at: directory)
        clock.advance(days: 10)
        stub.failing = true
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.breakingBad) == IMDbFixture.breakingBadRatings)
        let entry = try #require(try await db.imdbRatingsCacheEntry(seriesId: IMDbFixture.breakingBad))
        #expect(entry.scannedAt < clock.now()) // still stale: retried next time
    }

    @Test func damagedDatasetIsDownloadedAgain() async throws {
        let stub = StubDatasets()
        let gz = try Data(contentsOf: imdbFixture("title.episode.tsv.gz"))
        stub.serve(gz.prefix(gz.count - 12), for: .episodes) // gzip header intact, stream truncated
        let service = service(stub)
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.breakingBad) == [])
        #expect(try await db.imdbRatingsCacheEntry(seriesId: IMDbFixture.breakingBad) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("title.episode.tsv.gz").path))

        stub.serve(nil, for: .episodes)
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.breakingBad) == IMDbFixture.breakingBadRatings)
        #expect(stub.downloads(of: .episodes) == 2)
        #expect(stub.downloads(of: .ratings) == 1)
    }

    @Test func nonGzipDownloadIsRejected() async throws {
        let stub = StubDatasets()
        stub.serve(Data("<html>Rate limited</html>".utf8), for: .ratings)
        let service = service(stub)
        #expect(await service.ratings(seriesIMDbId: IMDbFixture.breakingBad) == [])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("title.ratings.tsv.gz").path))
        #expect(await service.scanCount == 0)
    }

    @Test func invalidIdsNeverDownload() async throws {
        let stub = StubDatasets()
        let service = service(stub)
        for id in ["", "tt", "nm0000001", "0903747", "tt0903747/"] {
            #expect(await service.ratings(seriesIMDbId: id) == [])
            #expect(await service.cachedRatings(seriesIMDbId: id) == [])
        }
        #expect(stub.downloads.isEmpty)
    }
}

// MARK: - Database

@Suite("IMDb ratings cache")
struct IMDbRatingsCacheTests {
    @Test func v4CreatesTheTables() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3")
        #expect(try queue.read { try $0.tableExists("imdbEpisodeRating") } == false)

        try AppDatabase.migrator.migrate(queue)
        let (applied, ratingColumns, ratingKey, scanColumns, scanKey) = try queue.read { db in
            (try AppDatabase.migrator.appliedIdentifiers(db),
             try db.columns(in: "imdbEpisodeRating").map(\.name), try db.primaryKey("imdbEpisodeRating").columns,
             try db.columns(in: "imdbRatingScan").map(\.name), try db.primaryKey("imdbRatingScan").columns)
        }
        #expect(applied.contains("v4"))
        #expect(ratingColumns == ["seriesId", "season", "episode", "rating", "votes"])
        #expect(ratingKey == ["seriesId", "season", "episode"])
        #expect(scanColumns == ["seriesId", "scannedAt"])
        #expect(scanKey == ["seriesId"])
    }

    @Test func rescanReplacesASeriesRows() async throws {
        let db = try AppDatabase.inMemory()
        let first = Date(timeIntervalSince1970: 1_000_000)
        let a = EpisodeRating(season: 1, episode: 1, rating: 8.1, votes: 10)
        let b = EpisodeRating(season: 1, episode: 2, rating: 7.4, votes: 9)
        try await db.saveIMDbRatings(["tt1": [b, a], "tt2": [a]], scannedAt: first)
        #expect(try await db.imdbEpisodeRatings(seriesId: "tt1") == [a, b])

        let second = first + 3600
        try await db.saveIMDbRatings(["tt1": [b]], scannedAt: second)
        #expect(try await db.imdbRatingsCacheEntry(seriesId: "tt1") == IMDbRatingsCacheEntry(scannedAt: second, ratings: [b]))
        #expect(try await db.imdbEpisodeRatings(seriesId: "tt2") == [a])

        try await db.clearIMDbRatingsCache()
        #expect(try await db.imdbRatingsCacheEntry(seriesId: "tt2") == nil)
    }
}
