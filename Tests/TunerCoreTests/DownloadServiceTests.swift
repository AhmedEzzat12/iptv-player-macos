import Foundation
import GRDB
import Testing
@testable import TunerCore

/// A download service wired to an in-memory library, an Xtream source on a stub HTTP server (no network) and a
/// temporary downloads folder.
struct DownloadHarness {
    static let user = "user"
    static let password = "secret"

    let db: AppDatabase
    let server: StubHTTPServer
    let resolver: StreamResolver
    let service: DownloadService
    let directory: URL

    init(freeSpace: Int64? = nil, backoff: Duration = .milliseconds(20)) async throws {
        db = try AppDatabase.inMemory()
        server = StubHTTPServer()
        try await db.save(Source(id: "src", name: "Test", kind: .xtream, url: "http://\(server.host)",
                                 username: Self.user, password: Self.password))
        resolver = StreamResolver(db: db, sync: SyncService(db: db))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tuner-downloads-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        service = DownloadService(db: db, resolver: resolver, directory: directory, configuration: configuration,
                                  freeSpace: { _ in freeSpace }, freeSpaceMargin: 0, backoff: { _ in backoff })
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        server.shutDown()
    }

    static func moviePath(_ id: String, ext: String = "mkv") -> String { "/movie/\(user)/\(password)/\(id).\(ext)" }
    static func episodePath(_ id: String, ext: String = "mp4") -> String { "/series/\(user)/\(password)/\(id).\(ext)" }

    /// A movie in the library, served by the stub at its Xtream URL.
    @discardableResult
    func addMovie(_ id: String, name: String = "Big Buck Test", year: String? = "2021", ext: String = "mkv",
                  body: Data, supportsRange: Bool = true) async throws -> Movie {
        var movie = Movie(id: id, sourceId: "src", categoryId: nil, name: name, providerId: id, providerOrder: 0)
        movie.year = year
        movie.containerExtension = ext
        let row = movie
        try await db.writer.write { try AppDatabase.insertMovies($0, [row]) }
        server.serve(Self.moviePath(id, ext: ext), .init(body: body, supportsRange: supportsRange))
        return movie
    }

    static let series = Series(id: "show", sourceId: "src", categoryId: nil, name: "Signal Lost", providerId: "show", providerOrder: 0)

    /// Episodes in the library, each served by the stub.
    func addEpisodes(_ specs: [(id: String, season: Int, number: Int, title: String)], body: Data) async throws -> [Episode] {
        let episodes = specs.map { spec in
            var e = Episode(id: spec.id, seriesId: Self.series.id, sourceId: "src", season: spec.season, number: spec.number,
                            title: spec.title, providerId: spec.id)
            e.containerExtension = "mp4"
            return e
        }
        try await db.writer.write { try AppDatabase.insertSeries($0, [Self.series]) }
        try await db.replaceEpisodes(seriesId: Self.series.id, episodes: episodes)
        for e in episodes { server.serve(Self.episodePath(e.id), .init(body: body, contentType: "video/mp4")) }
        return episodes
    }

    func item(_ id: String) async -> DownloadItem? { await service.item(id: id) }

    func state(_ id: String) async -> DownloadItem.State? { await service.item(id: id)?.state }

    func insert(_ item: DownloadItem) async throws {
        try await db.writer.write { try item.insert($0) }
    }

    func moviesFolder() -> URL { directory.appendingPathComponent("Movies", isDirectory: true) }
}

/// Distinct bytes at every offset, so a misplaced resume shows up as a content mismatch.
func testBody(_ size: Int) -> Data {
    Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) })
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(_ timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func fileData(_ path: String?) -> Data? {
    path.flatMap { FileManager.default.contents(atPath: $0) }
}

func fileSize(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
}

@Suite("Downloads: queue and transfer")
struct DownloadQueueTests {
    @Test func runsOneDownloadAtATimeInQueueOrder() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let body = testBody(40_000)
        var movies: [Movie] = []
        for id in ["m1", "m2", "m3"] { movies.append(try await h.addMovie(id, name: "Movie \(id)", body: body)) }
        h.server.hold(DownloadHarness.moviePath("m1"), at: 10_000)
        for movie in movies { try await h.service.enqueue(movie: movie) }

        #expect(await eventually { await h.item("m1")?.receivedBytes == 10_000 })
        #expect(await h.state("m1") == .downloading)
        #expect(await h.state("m2") == .queued)
        #expect(await h.state("m3") == .queued)
        #expect(h.server.requests.count == 1)

        h.server.release(DownloadHarness.moviePath("m1"))
        #expect(await eventually { await h.service.items().allSatisfy { $0.state == .completed } })
        #expect(h.server.requests.map(\.path) == ["m1", "m2", "m3"].map { DownloadHarness.moviePath($0) })
        #expect(h.server.maxConcurrent == 1)
        // Newest first.
        #expect(await h.service.items().map(\.id) == ["m3", "m2", "m1"])
    }

    @Test func writesProgressThenMovesTheFinishedFileIntoPlace() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let body = testBody(64_000)
        let movie = try await h.addMovie("m1", name: "Big Buck Test", year: "2021", body: body)
        h.server.hold(DownloadHarness.moviePath("m1"), at: 20_000)
        try await h.service.enqueue(movie: movie)

        let final = h.moviesFolder().appendingPathComponent("Big Buck Test (2021).mkv").path
        #expect(await eventually { await h.item("m1")?.receivedBytes == 20_000 })
        let running = try #require(await h.item("m1"))
        #expect(running.state == .downloading)
        #expect(running.totalBytes == 64_000)
        #expect(running.filePath == final)
        #expect(fileSize(final + ".part") == 20_000)
        #expect(!FileManager.default.fileExists(atPath: final))
        #expect(await h.service.localFile(mediaId: "m1") == nil)

        h.server.release(DownloadHarness.moviePath("m1"))
        #expect(await eventually { await h.state("m1") == .completed })
        let done = try #require(await h.item("m1"))
        #expect(done.receivedBytes == 64_000)
        #expect(done.fraction == 1)
        #expect(done.error == nil)
        #expect(done.subtitle == "2021")
        #expect(fileData(final) == body)
        #expect(!FileManager.default.fileExists(atPath: final + ".part"))
        #expect(await h.service.localFile(mediaId: "m1")?.path == final)

        // The request carried the source's User-Agent and asked for the bytes as they are.
        let request = try #require(h.server.requests.first)
        #expect(request.userAgent == HTTPClient.defaultUserAgent)
        #expect(request.acceptEncoding == "identity")
        #expect(request.range == nil)
    }

    @Test func enqueueingAgainIsANoOp() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let movie = try await h.addMovie("m1", body: testBody(5_000))
        try await h.service.enqueue(movie: movie)
        #expect(await eventually { await h.state("m1") == .completed })
        try await h.service.enqueue(movie: movie)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await h.state("m1") == .completed)
        #expect(h.server.requests.count == 1)
    }

    @Test func episodesQueueInWatchOrderAndSkipKnownOnes() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let body = testBody(8_000)
        let episodes = try await h.addEpisodes([
            ("e21", 2, 1, "Signal Lost - S02E01 - Static"),
            ("e12", 1, 2, "S01E02 - The Cut"),
            ("e11", 1, 1, "Pilot"),
            ("e13", 1, 3, "Episode 3"),
        ], body: body)
        // S1E1 is already on disk.
        let existing = h.directory.appendingPathComponent("existing.mp4")
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: existing)
        try await h.insert(DownloadItem(id: "e11", kind: .episode, sourceId: "src", seriesId: "show", title: "Signal Lost",
                                        state: .completed, receivedBytes: 1, totalBytes: 1, filePath: existing.path))

        try await h.service.enqueue(episodes: episodes, of: DownloadHarness.series)
        #expect(await eventually { await h.service.items().allSatisfy { $0.state == .completed } })
        #expect(h.server.requests.map(\.path) == ["e12", "e13", "e21"].map { DownloadHarness.episodePath($0) })

        let e12 = try #require(await h.item("e12"))
        #expect(e12.title == "Signal Lost")
        #expect(e12.subtitle == "S1, E2 · The Cut")
        #expect(e12.season == 1 && e12.episode == 2 && e12.seriesId == "show")
        let show = h.directory.appendingPathComponent("TV Shows/Signal Lost")
        #expect(e12.filePath == show.appendingPathComponent("Season 1/Signal Lost - S01E02 - The Cut.mp4").path)
        #expect(await h.item("e13")?.filePath == show.appendingPathComponent("Season 1/Signal Lost - S01E03.mp4").path)
        #expect(await h.item("e13")?.subtitle == "S1, E3")
        #expect(await h.item("e21")?.filePath == show.appendingPathComponent("Season 2/Signal Lost - S02E01 - Static.mp4").path)
        #expect(fileData(e12.filePath) == body)

        // Asking again adds nothing.
        try await h.service.enqueue(episodes: episodes, of: DownloadHarness.series)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.server.requests.count == 3)
    }

    @Test func sameNameGetsANumberedFile() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let a = try await h.addMovie("a", name: "Twin", year: "2020", body: testBody(3_000))
        let b = try await h.addMovie("b", name: "Twin", year: "2020", body: testBody(4_000))
        try await h.service.enqueue(movie: a)
        try await h.service.enqueue(movie: b)
        #expect(await eventually { await h.state("b") == .completed })
        #expect(await h.item("a")?.filePath == h.moviesFolder().appendingPathComponent("Twin (2020).mkv").path)
        #expect(await h.item("b")?.filePath == h.moviesFolder().appendingPathComponent("Twin (2020) (2).mkv").path)
    }

    @Test func followsRedirectsKeepingHeaders() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let cdn = StubHTTPServer()
        defer { cdn.shutDown() }
        let body = testBody(30_000)
        cdn.serve("/vod/abc.mkv", .init(body: body))
        cdn.hold("/vod/abc.mkv", at: 12_000)
        let movie = try await h.addMovie("m1", body: Data())
        h.server.serve(DownloadHarness.moviePath("m1"), .init(body: Data(), redirect: cdn.url("/vod/abc.mkv")))

        try await h.service.enqueue(movie: movie)
        #expect(await eventually { await h.item("m1")?.receivedBytes == 12_000 })
        await h.service.pause(id: "m1")
        cdn.release("/vod/abc.mkv")
        await h.service.resume(id: "m1")
        #expect(await eventually { await h.state("m1") == .completed })
        #expect(fileData(await h.item("m1")?.filePath) == body)
        // Both hops of both attempts; the CDN got the User-Agent and, on resume, the Range.
        #expect(h.server.requests.count == 2)
        #expect(cdn.requests.map(\.userAgent) == [HTTPClient.defaultUserAgent, HTTPClient.defaultUserAgent])
        #expect(cdn.requests.map(\.range) == [nil, "bytes=12000-"])
    }

    @Test func requestCarriesStreamHeaders() {
        let stream = PlayableStream(url: URL(string: "http://example.test/movie/u/p/1.mkv")!, userAgent: "TunerTestKit/1.0",
                                    referrer: "http://tuner.test/", kind: .vod)
        let request = DownloadService.request(for: stream, offset: 1_234)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "TunerTestKit/1.0")
        #expect(request.value(forHTTPHeaderField: "Referer") == "http://tuner.test/")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=1234-")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(DownloadService.request(for: stream, offset: 0).value(forHTTPHeaderField: "Range") == nil)
    }
}

@Suite("Downloads: pause, resume, cancel")
struct DownloadControlTests {
    @Test func resumesWithARangeWhenTheServerAllowsIt() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let body = testBody(50_000)
        let movie = try await h.addMovie("m1", body: body)
        let path = DownloadHarness.moviePath("m1")
        h.server.hold(path, at: 25_000)
        try await h.service.enqueue(movie: movie)
        #expect(await eventually { await h.item("m1")?.receivedBytes == 25_000 })

        await h.service.pause(id: "m1")
        let paused = try #require(await h.item("m1"))
        #expect(paused.state == .paused)
        #expect(paused.pausedByUser)
        #expect(paused.receivedBytes == 25_000)
        let final = try #require(paused.filePath)
        #expect(fileSize(final + ".part") == 25_000)

        h.server.release(path)
        await h.service.resume(id: "m1")
        #expect(await eventually { await h.state("m1") == .completed })
        #expect(h.server.requests.map(\.range) == [nil, "bytes=25000-"])
        #expect(fileData(final) == body)
        #expect(await h.item("m1")?.pausedByUser == false)
    }

    @Test func startsOverWhenTheServerIgnoresTheRange() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let body = testBody(50_000)
        let movie = try await h.addMovie("m1", body: body, supportsRange: false)
        let path = DownloadHarness.moviePath("m1")
        h.server.hold(path, at: 25_000)
        try await h.service.enqueue(movie: movie)
        #expect(await eventually { await h.item("m1")?.receivedBytes == 25_000 })
        await h.service.pause(id: "m1")
        h.server.release(path)
        await h.service.resume(id: "m1")
        #expect(await eventually { await h.state("m1") == .completed })
        // Asked for the rest, got a 200 with the whole file: written from the start, not appended.
        #expect(h.server.requests.map(\.range) == [nil, "bytes=25000-"])
        #expect(fileData(await h.item("m1")?.filePath) == body)
    }

    @Test func pausedQueuedDownloadIsSkippedUntilResumed() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let m1 = try await h.addMovie("m1", name: "One", body: testBody(20_000))
        let m2 = try await h.addMovie("m2", name: "Two", body: testBody(20_000))
        let m3 = try await h.addMovie("m3", name: "Three", body: testBody(20_000))
        h.server.hold(DownloadHarness.moviePath("m1"), at: 5_000)
        for movie in [m1, m2, m3] { try await h.service.enqueue(movie: movie) }
        #expect(await eventually { await h.item("m1")?.receivedBytes == 5_000 })

        await h.service.pause(id: "m2")
        #expect(await h.state("m2") == .paused)
        h.server.release(DownloadHarness.moviePath("m1"))
        #expect(await eventually { await h.state("m3") == .completed })
        #expect(await h.state("m2") == .paused)
        #expect(!h.server.requests.contains { $0.path == DownloadHarness.moviePath("m2") })

        await h.service.resume(id: "m2")
        #expect(await eventually { await h.state("m2") == .completed })
    }

    @Test func cancelRemovesThePartialFileAndTheRow() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let m1 = try await h.addMovie("m1", name: "One", body: testBody(30_000))
        let m2 = try await h.addMovie("m2", name: "Two", body: testBody(30_000))
        h.server.hold(DownloadHarness.moviePath("m1"), at: 10_000)
        try await h.service.enqueue(movie: m1)
        try await h.service.enqueue(movie: m2)
        #expect(await eventually { await h.item("m1")?.receivedBytes == 10_000 })
        let part = try #require(await h.item("m1")?.filePath) + ".part"
        #expect(FileManager.default.fileExists(atPath: part))

        await h.service.cancel(id: "m1")
        #expect(await h.item("m1") == nil)
        #expect(!FileManager.default.fileExists(atPath: part))
        // The next one runs.
        #expect(await eventually { await h.state("m2") == .completed })
        // A finished download isn't cancelled (that's delete).
        await h.service.cancel(id: "m2")
        #expect(await h.state("m2") == .completed)
    }

    @Test func deleteRemovesTheFileTheRowAndEmptyFolders() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let episodes = try await h.addEpisodes([("e11", 1, 1, "Pilot")], body: testBody(6_000))
        try await h.service.enqueue(episodes: episodes, of: DownloadHarness.series)
        #expect(await eventually { await h.state("e11") == .completed })
        let file = try #require(await h.item("e11")?.filePath)
        #expect(FileManager.default.fileExists(atPath: file))

        await h.service.delete(id: "e11")
        #expect(await h.item("e11") == nil)
        #expect(!FileManager.default.fileExists(atPath: file))
        let shows = h.directory.appendingPathComponent("TV Shows")
        #expect(!FileManager.default.fileExists(atPath: shows.appendingPathComponent("Signal Lost").path))
        #expect(FileManager.default.fileExists(atPath: shows.path))
    }

    @Test func suspendPausesWithoutMarkingUserPaused() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let body = testBody(30_000)
        let m1 = try await h.addMovie("m1", name: "One", body: body)
        let m2 = try await h.addMovie("m2", name: "Two", body: body)
        let m3 = try await h.addMovie("m3", name: "Three", body: body)
        h.server.hold(DownloadHarness.moviePath("m1"), at: 10_000)
        for movie in [m1, m2, m3] { try await h.service.enqueue(movie: movie) }
        await h.service.pause(id: "m3")
        #expect(await eventually { await h.item("m1")?.receivedBytes == 10_000 })

        await h.service.suspend()
        let suspended = try #require(await h.item("m1"))
        #expect(suspended.state == .paused)
        #expect(!suspended.pausedByUser)
        #expect(suspended.receivedBytes == 10_000)
        h.server.release(DownloadHarness.moviePath("m1"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await h.state("m2") == .queued) // nothing starts while suspended
        #expect(h.server.requests.count == 1)

        await h.service.unsuspend()
        #expect(await eventually { await h.state("m2") == .completed })
        #expect(await h.state("m1") == .completed)
        #expect(h.server.requests.first { $0.path == DownloadHarness.moviePath("m1") && $0.range != nil }?.range == "bytes=10000-")
        #expect(fileData(await h.item("m1")?.filePath) == body)
        // The user's pause outlives the suspension.
        #expect(await h.item("m3")?.state == .paused)
        #expect(await h.item("m3")?.pausedByUser == true)
    }
}

@Suite("Downloads: relaunch and errors")
struct DownloadRecoveryTests {
    @Test func startRequeuesWhatWasInterruptedByAQuit() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let body = testBody(40_000)
        try await h.addMovie("c1", name: "Crashed", body: body)
        try await h.addMovie("c2", name: "Auto Paused", body: body)
        try await h.addMovie("c3", name: "User Paused", body: body)
        // The app quit mid-transfer: a row still "downloading" and 10 000 bytes in its part file.
        let final = h.moviesFolder().appendingPathComponent("Crashed (2021).mkv")
        try FileManager.default.createDirectory(at: h.moviesFolder(), withIntermediateDirectories: true)
        try body.prefix(10_000).write(to: URL(fileURLWithPath: final.path + ".part"))
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try await h.insert(DownloadItem(id: "c1", kind: .movie, sourceId: "src", title: "Crashed", state: .downloading,
                                        receivedBytes: 8_000, totalBytes: 40_000, filePath: final.path, createdAt: t0))
        try await h.insert(DownloadItem(id: "c2", kind: .movie, sourceId: "src", title: "Auto Paused", state: .paused,
                                        createdAt: t0.addingTimeInterval(1)))
        try await h.insert(DownloadItem(id: "c3", kind: .movie, sourceId: "src", title: "User Paused", state: .paused,
                                        pausedByUser: true, createdAt: t0.addingTimeInterval(2)))

        await h.service.start()
        #expect(await eventually { await h.state("c2") == .completed })
        #expect(await h.state("c1") == .completed)
        #expect(h.server.requests.map(\.path) == [DownloadHarness.moviePath("c1"), DownloadHarness.moviePath("c2")])
        #expect(h.server.requests.first?.range == "bytes=10000-") // from the part file, not the stale row
        #expect(fileData(final.path) == body)
        #expect(await h.state("c3") == .paused)
    }

    @Test func completePartFileIsFinishedOn416() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let body = testBody(20_000)
        try await h.addMovie("m1", body: body)
        let final = h.moviesFolder().appendingPathComponent("Big Buck Test (2021).mkv")
        try FileManager.default.createDirectory(at: h.moviesFolder(), withIntermediateDirectories: true)
        try body.write(to: URL(fileURLWithPath: final.path + ".part"))
        try await h.insert(DownloadItem(id: "m1", kind: .movie, sourceId: "src", title: "Big Buck Test", state: .downloading,
                                        receivedBytes: 20_000, totalBytes: 20_000, filePath: final.path))
        await h.service.start()
        #expect(await eventually { await h.state("m1") == .completed })
        #expect(h.server.requests.map(\.range) == ["bytes=20000-"])
        #expect(fileData(final.path) == body)
    }

    @Test func oversizedPartFileStartsOverOn416() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let body = testBody(20_000)
        try await h.addMovie("m1", body: body)
        let final = h.moviesFolder().appendingPathComponent("Big Buck Test (2021).mkv")
        try FileManager.default.createDirectory(at: h.moviesFolder(), withIntermediateDirectories: true)
        try testBody(25_000).write(to: URL(fileURLWithPath: final.path + ".part"))
        try await h.insert(DownloadItem(id: "m1", kind: .movie, sourceId: "src", title: "Big Buck Test", state: .downloading,
                                        receivedBytes: 25_000, filePath: final.path))
        await h.service.start()
        #expect(await eventually { await h.state("m1") == .completed })
        #expect(h.server.requests.map(\.range) == ["bytes=25000-", nil])
        #expect(fileData(final.path) == body)
    }

    @Test(arguments: [
        (503, "lists this title but has no playable copy"),
        (404, "no longer has this title"),
        (401, "username or password"),
        (403, "refused this download (HTTP 403)"),
    ])
    func httpErrorsFailWithWhatTheProviderDid(status: Int, message: String) async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let movie = try await h.addMovie("m1", body: Data())
        h.server.serve(DownloadHarness.moviePath("m1"), .init(body: Data(), status: status))
        try await h.service.enqueue(movie: movie)
        #expect(await eventually { await h.state("m1") == .failed })
        let failed = try #require(await h.item("m1"))
        #expect(failed.error?.contains(message) == true)
        #expect(failed.error?.contains("later") == false)
        #expect(failed.filePath == nil)
        #expect(h.server.requests.count == 1)

        // "Try Again" queues it again.
        h.server.serve(DownloadHarness.moviePath("m1"), .init(body: testBody(1_000)))
        await h.service.resume(id: "m1")
        #expect(await eventually { await h.state("m1") == .completed })
        #expect(await h.item("m1")?.error == nil)
    }

    @Test func networkLossWaitsToRetryInsteadOfFailing() async throws {
        let h = try await DownloadHarness(backoff: .seconds(3600))
        defer { h.cleanUp() }
        let body = testBody(60_000)
        let movie = try await h.addMovie("m1", body: body)
        h.server.hold(DownloadHarness.moviePath("m1"), at: 30_000)
        try await h.service.enqueue(movie: movie)
        #expect(await eventually { await h.item("m1")?.receivedBytes == 30_000 })
        h.server.cut(DownloadHarness.moviePath("m1"))

        #expect(await eventually {
            let item = await h.item("m1")
            return item?.state == .queued && item?.error != nil
        })
        #expect(h.server.requests.count == 1)
        let waiting = try #require(await h.item("m1"))
        #expect(waiting.error == DownloadService.connectionLostMessage)
        #expect(waiting.receivedBytes == 30_000)
        #expect(fileSize(try #require(waiting.filePath) + ".part") == 30_000)
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.server.requests.count == 1) // still waiting out the backoff

        // "Resume" retries right away, from where it stopped.
        await h.service.resume(id: "m1")
        #expect(await eventually { await h.state("m1") == .completed })
        #expect(h.server.requests.map(\.range) == [nil, "bytes=30000-"])
        #expect(fileData(waiting.filePath) == body)
    }

    @Test func networkLossRetriesOnItsOwn() async throws {
        let h = try await DownloadHarness(backoff: .milliseconds(10))
        defer { h.cleanUp() }
        let body = testBody(60_000)
        let movie = try await h.addMovie("m1", body: body)
        h.server.hold(DownloadHarness.moviePath("m1"), at: 20_000)
        try await h.service.enqueue(movie: movie)
        #expect(await eventually { await h.item("m1")?.receivedBytes == 20_000 })
        h.server.cut(DownloadHarness.moviePath("m1"))
        #expect(await eventually { await h.state("m1") == .completed })
        #expect(h.server.requests.map(\.range) == [nil, "bytes=20000-"])
        #expect(fileData(await h.item("m1")?.filePath) == body)
        #expect(await h.item("m1")?.error == nil)
    }

    @Test func notEnoughDiskSpaceFailsBeforeWriting() async throws {
        let h = try await DownloadHarness(freeSpace: 1_000)
        defer { h.cleanUp() }
        let movie = try await h.addMovie("m1", body: testBody(50_000))
        try await h.service.enqueue(movie: movie)
        #expect(await eventually { await h.state("m1") == .failed })
        let failed = try #require(await h.item("m1"))
        #expect(failed.error?.contains("Not enough disk space") == true)
        #expect(failed.receivedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: try #require(failed.filePath) + ".part"))
    }

    @Test func titleMissingFromTheLibraryFails() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        var gone = Movie(id: "gone", sourceId: "src", categoryId: nil, name: "Gone", providerId: "gone", providerOrder: 0)
        gone.containerExtension = "mkv"
        // Not in the library, but the service keeps what enqueue was given for this launch.
        h.server.serve(DownloadHarness.moviePath("gone"), .init(body: testBody(2_000)))
        try await h.service.enqueue(movie: gone)
        #expect(await eventually { await h.state("gone") == .completed })

        // After a relaunch (new service), a queued title the library no longer has fails clearly.
        try await h.insert(DownloadItem(id: "lost", kind: .movie, sourceId: "src", title: "Lost"))
        let fresh = DownloadService(db: h.db, resolver: h.resolver, directory: h.directory)
        await fresh.start()
        #expect(await eventually { await fresh.item(id: "lost")?.state == .failed })
        #expect(await fresh.item(id: "lost")?.error == "This title is no longer in your playlist.")
    }
}

@Suite("Downloads: offline playback")
struct DownloadPlaybackTests {
    @Test func resolverPrefersACompletedDownload() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let movie = try await h.addMovie("m1", body: testBody(4_000))
        try await h.service.enqueue(movie: movie)
        #expect(await eventually { await h.state("m1") == .completed })
        let file = try #require(await h.item("m1")?.filePath)

        let local = try await h.resolver.movie(movie)
        #expect(local.url == URL(fileURLWithPath: file))
        #expect(local.url.isFileURL)
        #expect(local.userAgent == HTTPClient.defaultUserAgent)
        #expect(local.kind == .vod)
        // Plays even when the playlist is gone.
        try await h.db.deleteSource(id: "src")
        #expect(try await h.resolver.movie(movie).url.isFileURL)
    }

    @Test func resolverStreamsAndFlagsTheDownloadWhenTheFileIsGone() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let episodes = try await h.addEpisodes([("e11", 1, 1, "Pilot")], body: testBody(4_000))
        try await h.service.enqueue(episodes: episodes, of: DownloadHarness.series)
        #expect(await eventually { await h.state("e11") == .completed })
        let file = try #require(await h.item("e11")?.filePath)
        #expect(try await h.resolver.episode(episodes[0]).url.isFileURL)

        try FileManager.default.removeItem(atPath: file)
        let streamed = try await h.resolver.episode(episodes[0])
        #expect(streamed.url.absoluteString == "http://\(h.server.host)\(DownloadHarness.episodePath("e11"))")
        let flagged = try #require(await h.item("e11"))
        #expect(flagged.state == .failed)
        #expect(flagged.error == "File was moved or deleted")
        #expect(await h.service.localFile(mediaId: "e11") == nil)

        // Downloading it again is allowed.
        try await h.service.enqueue(episodes: episodes, of: DownloadHarness.series)
        #expect(await eventually { await h.state("e11") == .completed })
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func unfinishedDownloadDoesNotReplaceTheStream() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        let movie = try await h.addMovie("m1", body: testBody(4_000))
        try await h.insert(DownloadItem(id: "m1", kind: .movie, sourceId: "src", title: "Big Buck Test", state: .paused,
                                        pausedByUser: true))
        #expect(try await h.resolver.movie(movie).url.isFileURL == false)
    }

    @Test func startFlagsCompletedDownloadsWhoseFileIsGone() async throws {
        let h = try await DownloadHarness()
        defer { h.cleanUp() }
        try await h.insert(DownloadItem(id: "m1", kind: .movie, sourceId: "src", title: "Moved", state: .completed,
                                        receivedBytes: 10, totalBytes: 10, filePath: h.directory.appendingPathComponent("nope.mkv").path))
        await h.service.start()
        #expect(await h.state("m1") == .failed)
        #expect(await h.item("m1")?.error == "File was moved or deleted")
    }
}

@Suite("Downloads: files and schema")
struct DownloadFilesTests {
    @Test func movieAndEpisodeLocations() {
        let movie = DownloadFiles.Naming.movie(title: "Mission: Impossible / Fallout", year: "2018").location
        #expect(movie.folders == ["Movies"])
        #expect(movie.name == "Mission - Impossible - Fallout (2018)")
        #expect(DownloadFiles.Naming.movie(title: "Dune (2021)", year: "2021").location.name == "Dune (2021)")
        #expect(DownloadFiles.Naming.movie(title: "Untitled Project", year: nil).location.name == "Untitled Project")

        let episode = DownloadFiles.Naming.episode(show: "Law & Order: SVU", season: 1, number: 3, title: "Who's \"There\"?").location
        #expect(episode.folders == ["TV Shows", "Law & Order - SVU", "Season 1"])
        #expect(episode.name == "Law & Order - SVU - S01E03 - Who's 'There'")
        #expect(DownloadFiles.Naming.episode(show: "Show", season: 12, number: 104, title: nil).location.name == "Show - S12E104")
    }

    @Test func namesAreSafeAndBounded() {
        #expect(DownloadFiles.sanitized("..hidden") == "hidden")
        #expect(DownloadFiles.sanitized("a\tb\nc") == "a b c")
        #expect(DownloadFiles.sanitized("  trailing dots... ") == "trailing dots")
        #expect(DownloadFiles.sanitized("<>*?") == "Untitled")
        #expect(DownloadFiles.sanitized("a\\b|c") == "a-b-c")
        let long = DownloadFiles.sanitized(String(repeating: "é", count: 300), maxBytes: 101)
        #expect(long.utf8.count == 100) // whole characters only (é is 2 bytes)
    }

    @Test func episodeTitlesLoseRepeatedShowAndCode() {
        #expect(DownloadFiles.episodeTitle("Signal Lost - S01E03 - The Cut", season: 1, number: 3) == "The Cut")
        #expect(DownloadFiles.episodeTitle("S01E03 - The Cut", season: 1, number: 3) == "The Cut")
        #expect(DownloadFiles.episodeTitle("The Cut", season: 1, number: 3) == "The Cut")
        #expect(DownloadFiles.episodeTitle("Episode 3", season: 1, number: 3) == nil)
        #expect(DownloadFiles.episodeTitle("Signal Lost - S01E03", season: 1, number: 3) == nil)
    }

    @Test func extensionComesFromTheServer() {
        let url = URL(string: "http://cdn.test/file.mp4?token=1")!
        let mp4 = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp4"])
        let mkvType = HTTPURLResponse(url: URL(string: "http://cdn.test/get")!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": "video/x-matroska"])
        #expect(DownloadFiles.fileExtension(declared: "MKV", response: mp4, requested: nil) == "mkv")
        #expect(DownloadFiles.fileExtension(declared: nil, response: mp4, requested: nil) == "mp4")
        #expect(DownloadFiles.fileExtension(declared: nil, response: mkvType, requested: nil) == "mkv")
        #expect(DownloadFiles.fileExtension(declared: nil, response: nil, requested: URL(string: "http://x.test/a/1.ts")) == "ts")
        #expect(DownloadFiles.fileExtension(declared: "rmvb", response: nil, requested: nil) == "rmvb")
        #expect(DownloadFiles.fileExtension(declared: nil, response: nil, requested: nil) == "mp4")
    }

    @Test func contentRangeParsing() {
        #expect(ContentRange("bytes 100-999/1000") == ContentRange(start: 100, total: 1000))
        #expect(ContentRange("bytes 100-999/*") == ContentRange(start: 100, total: nil))
        #expect(ContentRange("bytes */1000") == ContentRange(start: nil, total: 1000))
        #expect(ContentRange("items 1-2/3") == nil)
        #expect(ContentRange(nil) == nil)
    }

    @Test func migrationV5CreatesTheDownloadTable() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4")
        #expect(try queue.read { try $0.tableExists("download") } == false)
        try AppDatabase.migrator.migrate(queue)

        let columns = try queue.read { db in try db.columns(in: "download").map(\.name) }
        #expect(Set(columns) == ["id", "kind", "sourceId", "seriesId", "title", "subtitle", "season", "episode", "artworkURL",
                                 "state", "receivedBytes", "totalBytes", "filePath", "error", "pausedByUser", "createdAt", "updatedAt"])
        let indexes = try queue.read { db in try db.indexes(on: "download").map(\.name) }
        #expect(Set(indexes).isSuperset(of: ["download_state_created", "download_series", "download_filePath"]))
        #expect(try queue.read { try $0.primaryKey("download").columns } == ["id"])

        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let item = DownloadItem(id: "ep1", kind: .episode, sourceId: "src", seriesId: "show", title: "Show", subtitle: "S1, E1 · Pilot",
                                season: 1, episode: 1, artworkURL: "http://img", state: .paused, receivedBytes: 5, totalBytes: 10,
                                filePath: "/tmp/x.mp4", error: nil, pausedByUser: true, createdAt: t, updatedAt: t)
        try queue.write { try item.insert($0) }
        #expect(try queue.read { try DownloadItem.fetchOne($0, key: "ep1") } == item)
    }
}
