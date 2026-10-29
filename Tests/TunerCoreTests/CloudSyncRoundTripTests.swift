import Foundation
import GRDB
import Testing
@testable import TunerCore

/// Two devices (in-memory libraries) syncing through a temporary folder.
@Suite("iCloud sync: round trips")
struct CloudSyncRoundTripTests {
    let folder: URL
    let a: AppDatabase
    let b: AppDatabase
    let engineA: CloudSyncEngine
    let engineB: CloudSyncEngine
    /// Later than any timestamp the database helpers take from the clock.
    let t0 = Date().addingTimeInterval(1000)

    static let xtreamURL = "http://xtream.example.com:8080"
    static let m3uURL = "http://lists.example.com/public.m3u"

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TunerSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        a = try AppDatabase.inMemory()
        b = try AppDatabase.inMemory()
        engineA = CloudSyncEngine(db: a, device: .init(id: "device-A", name: "Mac", platform: "macOS", appVersion: "1.5.0"))
        engineB = CloudSyncEngine(db: b, device: .init(id: "device-B", name: "iPhone", platform: "iOS", appVersion: "1.5.0"))
    }

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func xtream(id: String, password: String = "pw-A-secret") -> Source {
        Source(id: id, name: "My Provider", kind: .xtream, url: Self.xtreamURL, username: "ahmed", password: password)
    }

    func progress(_ id: String, source: String, position: Double, at date: Date) -> WatchProgress {
        WatchProgress(mediaId: id, kind: .movie, sourceId: source, title: "A Movie", position: position, duration: 6000, updatedAt: date)
    }

    @Test func userStateTravelsAndDeletionsFollow() async throws {
        try await a.save(xtream(id: "SA"))
        try await b.save(xtream(id: "SB", password: "pw-B-secret"))

        try await a.setFavorite(channelId: "SA_101", true)
        try await a.setVODFavorite(mediaId: "SA_vod_7", kind: .movie, true)
        try await a.saveProgress(progress("SA_vod_7", source: "SA", position: 1200, at: at(1)))
        try await a.setCategoryHidden(categoryId: "SA_series_4", true)
        let group = try await a.createGroup(name: "Sports")
        try await a.addToGroup(groupId: group.id, channelId: "SA_101")
        try await a.recordWatched(channelId: "SA_101", at: at(2))

        _ = await engineA.sync(folder: folder, preferences: [:], now: at(10))
        let report = await engineB.sync(folder: folder, preferences: [:], now: at(11))
        #expect(report.error == nil)
        #expect(report.peers.map(\.name) == ["Mac"])
        #expect(report.appliedCount >= 6)

        let favorite = try await b.writer.read { try Bool.fetchOne($0, sql: "SELECT isFavorite FROM channelPref WHERE channelId = 'SB_101'") }
        #expect(favorite == true)
        #expect(try await b.isVODFavorite(mediaId: "SB_vod_7"))
        let p = try #require(try await b.progress(mediaId: "SB_vod_7"))
        #expect(p.position == 1200 && p.sourceId == "SB")
        #expect(abs(p.updatedAt.timeIntervalSince(at(1))) < 0.002)
        let hidden = try await b.writer.read { try Bool.fetchOne($0, sql: "SELECT isHidden FROM categoryPref WHERE categoryId = 'SB_series_4'") }
        #expect(hidden == true)
        #expect(try await b.customGroups().map(\.id) == [group.id])
        #expect(try await b.groupCounts()[group.id] == 1)
        let watched = try await b.writer.read { try Date.fetchOne($0, sql: "SELECT watchedAt FROM history WHERE channelId = 'SB_101'") }
        #expect(watched != nil)

        // Neither password is ever written to a file.
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("pw-A-secret") && !text.contains("pw-B-secret"))
            #expect(!text.contains("\"SA_") && !text.contains("\"SB_"))
        }

        // Deletions on A reach B.
        try await a.setVODFavorite(mediaId: "SA_vod_7", kind: .movie, false)
        try await a.deleteProgress(mediaId: "SA_vod_7")
        try await a.deleteGroup(id: group.id)
        try await a.clearHistory()
        _ = await engineA.sync(folder: folder, preferences: [:], now: at(20))
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(21))
        #expect(try await b.isVODFavorite(mediaId: "SB_vod_7") == false)
        #expect(try await b.progress(mediaId: "SB_vod_7") == nil)
        #expect(try await b.customGroups().isEmpty)
        let historyCount = try await b.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM history") }
        #expect(historyCount == 0)
        // B's favourite channel is still there (A didn't change it).
        let still = try await b.writer.read { try Bool.fetchOne($0, sql: "SELECT isFavorite FROM channelPref WHERE channelId = 'SB_101'") }
        #expect(still == true)
    }

    @Test func newerProgressWinsBothWays() async throws {
        try await a.save(xtream(id: "SA"))
        try await b.save(xtream(id: "SB"))
        try await a.saveProgress(progress("SA_vod_1", source: "SA", position: 100, at: at(1)))
        try await b.saveProgress(progress("SB_vod_1", source: "SB", position: 900, at: at(5)))
        _ = await engineA.sync(folder: folder, preferences: [:], now: at(10))
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(11))
        _ = await engineA.sync(folder: folder, preferences: [:], now: at(12))
        #expect(try await a.progress(mediaId: "SA_vod_1")?.position == 900)
        #expect(try await b.progress(mediaId: "SB_vod_1")?.position == 900)

        // A watches further later on: B follows.
        try await a.saveProgress(progress("SA_vod_1", source: "SA", position: 1500, at: at(30)))
        _ = await engineA.sync(folder: folder, preferences: [:], now: at(31))
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(32))
        #expect(try await b.progress(mediaId: "SB_vod_1")?.position == 1500)
    }

    @Test func playlistsArriveWithoutPasswords() async throws {
        try await a.save(xtream(id: "SA"))
        try await a.save(Source(id: "MA", name: "Free List", kind: .m3u, url: Self.m3uURL, sortIndex: 1))
        try await a.setFavorite(channelId: "SA_5", true)
        _ = await engineA.sync(folder: folder, preferences: [:], now: at(10))
        let report = await engineB.sync(folder: folder, preferences: [:], now: at(11))

        let sources = try await b.sources()
        #expect(sources.count == 2)
        let x = try #require(sources.first { $0.kind == .xtream })
        #expect(x.needsPassword && !x.enabled && x.password == nil)
        #expect(x.username == "ahmed" && x.url == Self.xtreamURL && x.name == "My Provider")
        let m = try #require(sources.first { $0.kind == .m3u })
        #expect(!m.needsPassword && m.enabled)
        #expect(report.readySourceIds == [m.id])
        #expect(report.sourcesNeedingPassword == 1)
        // The waiting playlist's favourites are already in place under its new local id.
        let favorite = try await b.writer.read { try Bool.fetchOne($0, sql: "SELECT isFavorite FROM channelPref WHERE channelId = ?", arguments: [x.id + "_5"]) }
        #expect(favorite == true)

        // The password is entered on B: the playlist turns on and nothing changes for A.
        var withPassword = x
        withPassword.password = "pw-B"
        withPassword.needsPassword = false
        withPassword.enabled = true
        try await b.save(withPassword)
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(20))
        _ = await engineA.sync(folder: folder, preferences: [:], now: at(21))
        let onA = try #require(try await a.source(id: "SA"))
        #expect(onA.enabled && onA.password == "pw-A-secret")
        #expect(try await a.sources().count == 2)
    }

    @Test func m3uWithTokenNeedsItsLinkAgain() async throws {
        try await a.save(Source(id: "MA", name: "Tokened", kind: .m3u, url: "http://lists.example.com/get.php?username=u&password=topsecret&type=m3u"))
        _ = await engineA.sync(folder: folder, preferences: [:], now: at(10))
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(11))
        let m = try #require(try await b.sources().first)
        #expect(m.needsPassword && !m.enabled)
        #expect(!m.url.contains("topsecret") && m.url.contains("username=u"))
    }

    @Test func recordsWaitForTheirPlaylist() async throws {
        // Another device's file with a favourite of a playlist this device doesn't have (and no playlist record).
        let fp = SourceFingerprint.of(xtream(id: "any"))
        let file = CloudSyncDeviceFile(deviceId: "device-C", deviceName: "iPad", platform: "iOS", appVersion: nil, exportedAt: Date(),
                                       records: [CloudSyncRecord(key: "channelPref/\(fp)|77", updatedAt: at(1).syncMillis, value: .object([
                                           "isFavorite": .bool(true), "favoriteOrder": .number(1), "isHidden": .bool(false),
                                           "alias": .null, "epgIdOverride": .string("bbc1.uk"),
                                       ]))])
        try CloudSyncFolder.write(file, to: folder)
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(10))
        #expect(try await b.cloudSyncLedger()["channelPref/\(fp)|77"] == nil)

        try await b.save(xtream(id: "SB"))
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(20))
        let row = try await b.writer.read { db -> (Bool?, String?) in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM channelPref WHERE channelId = 'SB_77'")
            return (row?["isFavorite"], row?["epgIdOverride"])
        }
        #expect(row.0 == true)
        #expect(row.1 == "bbc1.uk")
    }

    @Test func deletingAPlaylistStaysLocal() async throws {
        try await a.save(xtream(id: "SA"))
        try await b.save(xtream(id: "SB"))
        try await a.setFavorite(channelId: "SA_1", true)
        _ = await engineA.sync(folder: folder, preferences: [:], now: at(10))
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(11))

        try await b.deleteSource(id: "SB")
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(20))
        _ = await engineA.sync(folder: folder, preferences: [:], now: at(21))
        #expect(try await a.source(id: "SA") != nil)
        let favorite = try await a.writer.read { try Bool.fetchOne($0, sql: "SELECT isFavorite FROM channelPref WHERE channelId = 'SA_1'") }
        #expect(favorite == true)
        // And A's copy doesn't bring it back on B.
        _ = await engineB.sync(folder: folder, preferences: [:], now: at(30))
        #expect(try await b.sources().isEmpty)
    }

    @Test func preferencesWhitelistAndPinnedIds() async throws {
        try await a.save(xtream(id: "SA"))
        try await a.save(Source(id: "MA", name: "Only on A", kind: .m3u, url: Self.m3uURL))
        try await b.save(xtream(id: "SB"))
        let prefsA: [String: SyncJSON] = [
            "accent": .string("purple"),
            "volume": .number(30),
            "tmdbAPIKey": .string("key-never-synced"),
            "pinnedCategoryIds": SyncJSON(["SA_vod_3", "MA_movies", "SA_series_9"]),
            "recentSearches": SyncJSON(["batman"]),
        ]
        _ = await engineA.sync(folder: folder, preferences: prefsA, now: at(10))
        let text = try String(contentsOf: folder.appendingPathComponent("device-A.json"), encoding: .utf8)
        #expect(!text.contains("key-never-synced") && !text.contains("volume"))

        // First sync on B: A's settings win over B's defaults.
        let prefsB: [String: SyncJSON] = ["accent": .string("cyan"), "pinnedCategoryIds": SyncJSON([String]())]
        let report = await engineB.sync(folder: folder, preferences: prefsB, now: at(11))
        #expect(report.preferences["accent"] == .string("purple"))
        #expect(report.preferences["recentSearches"] == SyncJSON(["batman"]))
        // The free M3U list came over too (new local id on B).
        let m3uOnB = try #require(try await b.sources().first { $0.kind == .m3u })
        #expect(report.preferences["pinnedCategoryIds"] == SyncJSON(["SB_vod_3", m3uOnB.id + "_movies", "SB_series_9"]))
        #expect(report.preferences["volume"] == nil)

        // B removes that list and pins another category: A's pin of the list B no longer has survives.
        try await b.deleteSource(id: m3uOnB.id)
        var applied = prefsB.merging(report.preferences) { _, new in new }
        applied["pinnedCategoryIds"] = SyncJSON(["SB_vod_3", "SB_series_9", "SB_vod_12"])
        _ = await engineB.sync(folder: folder, preferences: applied, now: at(20))
        let back = await engineA.sync(folder: folder, preferences: prefsA, now: at(21))
        #expect(back.preferences["pinnedCategoryIds"] == SyncJSON(["SA_vod_3", "SA_series_9", "SA_vod_12", "MA_movies"]))
        #expect(back.preferences["accent"] == nil)
    }

    @Test func corruptFilesAreSkippedAndUnchangedStateIsNotRewritten() async throws {
        try Data("{\"schema\": 1, \"deviceId\": \"x\", \"rec".utf8).write(to: folder.appendingPathComponent("broken.json"))
        try Data(#"{"schema": 9, "deviceId": "future"}"#.utf8).write(to: folder.appendingPathComponent("future.json"))
        try await a.save(xtream(id: "SA"))
        let first = await engineA.sync(folder: folder, preferences: [:], now: at(10))
        #expect(first.error == nil)
        #expect(first.notices.count == 2)
        #expect(first.wroteFile)
        let second = await engineA.sync(folder: folder, preferences: [:], now: at(20))
        #expect(!second.wroteFile)
        // A fresh engine (app relaunch) reads its own file and doesn't rewrite it either.
        let relaunched = CloudSyncEngine(db: a, device: .init(id: "device-A", name: "Mac", platform: "macOS", appVersion: "1.5.0"))
        #expect(!(await relaunched.sync(folder: folder, preferences: [:], now: at(30))).wroteFile)
    }

    @Test func missingFolderIsReported() async throws {
        let report = await engineA.sync(folder: folder.appendingPathComponent("nope"), preferences: [:], now: at(1))
        #expect(report.error != nil)
    }
}
