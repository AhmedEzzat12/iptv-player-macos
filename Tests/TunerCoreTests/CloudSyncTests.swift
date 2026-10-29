import Foundation
import Testing
@testable import TunerCore

@Suite("iCloud sync: fingerprints and ids")
struct CloudSyncFingerprintTests {
    @Test func passwordIsNeverPartOfTheFingerprint() {
        let a = Source(name: "A", kind: .xtream, url: "http://Provider.example.com:8080/", username: "Ahmed", password: "first-secret")
        let b = Source(name: "B", kind: .xtream, url: "http://provider.example.com:8080", username: "ahmed", password: "other-secret")
        #expect(SourceFingerprint.of(a) == SourceFingerprint.of(b))
        let otherUser = Source(name: "C", kind: .xtream, url: "http://provider.example.com:8080", username: "someone", password: "x")
        #expect(SourceFingerprint.of(a) != SourceFingerprint.of(otherUser))
        let otherKind = Source(name: "D", kind: .m3u, url: "http://provider.example.com:8080", username: "ahmed")
        #expect(SourceFingerprint.of(a) != SourceFingerprint.of(otherKind))
    }

    @Test func m3uQuerySecretsAreStripped() {
        let url = "http://h.example.com/get.php?username=u1&password=SECRET1&type=m3u_plus&token=TOK"
        let normalized = SourceFingerprint.normalizedURL(url)
        #expect(!normalized.contains("SECRET1"))
        #expect(!normalized.contains("TOK"))
        #expect(normalized.contains("username=u1"))
        let fp1 = SourceFingerprint.of(kind: .m3u, url: url, username: nil, mac: nil)
        let fp2 = SourceFingerprint.of(kind: .m3u, url: "http://h.example.com/get.php?type=m3u_plus&password=OTHER&username=u1", username: nil, mac: nil)
        #expect(fp1 == fp2)

        let pub = SourceFingerprint.publicURL(url)
        #expect(pub.removedSecret)
        #expect(!pub.url.contains("SECRET1") && !pub.url.contains("TOK"))
        #expect(pub.url.contains("username=u1") && pub.url.contains("type=m3u_plus"))
        #expect(SourceFingerprint.of(kind: .m3u, url: pub.url, username: nil, mac: nil) == fp1)
    }

    @Test func normalisation() {
        #expect(SourceFingerprint.normalizedURL(" HTTP://Example.COM:80/list/ ") == "http://example.com/list")
        #expect(SourceFingerprint.normalizedURL("https://example.com:443/a//") == "https://example.com/a")
        #expect(SourceFingerprint.normalizedURL("http://example.com/a?b=2&a=1") == SourceFingerprint.normalizedURL("http://example.com/a?a=1&b=2"))
        #expect(!SourceFingerprint.normalizedURL("http://user:pw123@example.com/x").contains("pw123"))
        let pub = SourceFingerprint.publicURL("http://user:pw123@example.com/x")
        #expect(pub.removedSecret && !pub.url.contains("pw123"))
        #expect(SourceFingerprint.publicURL("http://example.com/list.m3u") == ("http://example.com/list.m3u", false))
    }

    @Test func stalkerIncludesTheMAC() {
        let a = SourceFingerprint.of(kind: .stalker, url: "http://portal.example.com/c/", username: nil, mac: "00:1A:79:00:00:01")
        let b = SourceFingerprint.of(kind: .stalker, url: "http://portal.example.com/c", username: nil, mac: "00:1a:79:00:00:01")
        let c = SourceFingerprint.of(kind: .stalker, url: "http://portal.example.com/c", username: nil, mac: "00:1A:79:00:00:02")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func idsTranslateBothWays() {
        let here = Source(id: "LOCAL-1", name: "X", kind: .xtream, url: "http://x.example.com", username: "u", password: "p")
        let there = Source(id: "REMOTE-9", name: "X", kind: .xtream, url: "http://x.example.com/", username: "U", password: "q")
        let mapHere = CloudSyncSourceMap(sources: [here])
        let mapThere = CloudSyncSourceMap(sources: [there])
        let fp = SourceFingerprint.of(here)
        for suffix in ["123", "vod_55", "series_7", "ep_901", "series_cat_3", "cnn.us_ab12"] {
            let synced = mapHere.syncId("LOCAL-1_" + suffix)
            #expect(synced == fp + "|" + suffix)
            #expect(synced.flatMap(mapThere.localId) == "REMOTE-9_" + suffix)
        }
        #expect(mapHere.syncId("OTHER_1") == nil)
        #expect(mapHere.localId("ffff|1") == nil)
    }

    @Test func sourceIdsWithUnderscoresAndDuplicates() {
        let old = Source(id: "my_src", name: "A", kind: .m3u, url: "http://a.example.com/l.m3u", createdAt: Date(timeIntervalSince1970: 1))
        let dup = Source(id: "dup", name: "B", kind: .m3u, url: "http://A.example.com/l.m3u", createdAt: Date(timeIntervalSince1970: 2))
        let map = CloudSyncSourceMap(sources: [dup, old])
        let fp = SourceFingerprint.of(old)
        #expect(map.sourceIdByFingerprint[fp] == "my_src")
        #expect(map.syncId("my_src_news") == fp + "|news")
        #expect(map.syncId("dup_news") == nil)
    }

    @Test func keysNameTheirPlaylist() {
        #expect(CloudSyncKey.fingerprint(of: "channelPref/abc|1") == "abc")
        #expect(CloudSyncKey.fingerprint(of: "groupMember/G-1/abc|x/y") == "abc")
        #expect(CloudSyncKey.itemId(of: "groupMember/G-1/abc|x/y") == "abc|x/y")
        #expect(CloudSyncKey.fingerprint(of: "group/G-1") == nil)
        #expect(CloudSyncKey.fingerprint(of: "pref/accent") == nil)
        #expect(CloudSyncKey.kind(of: "future/thing") == nil)
    }

    @Test func jsonValuesKeepTheirTypes() throws {
        let data = Data(#"[1, true, "x", null, 2.5, {"a": [false]}]"#.utf8)
        let value = try JSONDecoder().decode(SyncJSON.self, from: data)
        #expect(value == .array([.number(1), .bool(true), .string("x"), .null, .number(2.5), .object(["a": .array([.bool(false)])])]))
        let again = try JSONDecoder().decode(SyncJSON.self, from: try JSONEncoder().encode(value))
        #expect(again.contentHash == value.contentHash)
        #expect(SyncJSON.object(["b": .number(1), "a": .null]).contentHash == SyncJSON.object(["a": .null, "b": .number(1)]).contentHash)
    }
}

@Suite("iCloud sync: diff and merge")
struct CloudSyncMergeTests {
    func entry(_ key: String, _ value: SyncJSON?, at stamp: Int64, deleted: Bool = false) -> CloudSyncLedgerEntry {
        CloudSyncLedgerEntry(key: key, value: value, localHash: value?.contentHash ?? "", updatedAt: stamp, deleted: deleted)
    }

    @Test func newChangedAndDeletedValues() {
        let ledger = [
            "channelPref/f|same": entry("channelPref/f|same", .bool(true), at: 100),
            "channelPref/f|changed": entry("channelPref/f|changed", .bool(true), at: 100),
            "channelPref/f|gone": entry("channelPref/f|gone", .bool(true), at: 100),
        ]
        let snapshot: [String: CloudSyncLocalValue] = [
            "channelPref/f|same": .init(.bool(true)),
            "channelPref/f|changed": .init(.bool(false)),
            "channelPref/f|new": .init(.string("n")),
        ]
        let out = CloudSyncMerge.diff(snapshot: snapshot, ledger: ledger, firstSync: false, now: 500)
        #expect(out["channelPref/f|same"]?.updatedAt == 100)
        #expect(out["channelPref/f|changed"]?.updatedAt == 500)
        #expect(out["channelPref/f|changed"]?.value == .bool(false))
        #expect(out["channelPref/f|new"]?.updatedAt == 500)
        #expect(out["channelPref/f|gone"]?.deleted == true)
        #expect(out["channelPref/f|gone"]?.updatedAt == 500)
        #expect(out["channelPref/f|gone"]?.value == nil)
    }

    @Test func ownTimestampsAndFirstSync() {
        let snapshot: [String: CloudSyncLocalValue] = [
            "progress/f|1": .init(.number(10), ownStamp: 42),
            "channelPref/f|2": .init(.bool(true)),
        ]
        let first = CloudSyncMerge.diff(snapshot: snapshot, ledger: [:], firstSync: true, now: 500)
        #expect(first["progress/f|1"]?.updatedAt == 42)
        #expect(first["channelPref/f|2"]?.updatedAt == CloudSyncMerge.provisionalStamp)
        let later = CloudSyncMerge.diff(snapshot: snapshot, ledger: [:], firstSync: false, now: 500)
        #expect(later["channelPref/f|2"]?.updatedAt == 500)
    }

    @Test func missingPlaylistsPrefsAndOldTombstones() {
        let day: Int64 = 24 * 3600 * 1000
        let now = 100 * day
        let ledger = [
            "channelPref/gone|1": entry("channelPref/gone|1", .bool(true), at: 1),
            "pref/accent": entry("pref/accent", .string("gold"), at: 1),
            "history/f|old": entry("history/f|old", nil, at: now - 61 * day, deleted: true),
            "history/f|recent": entry("history/f|recent", nil, at: now - 10 * day, deleted: true),
            "source/abc": entry("source/abc", nil, at: 1, deleted: true),
            "source/def": entry("source/def", .string("x"), at: 1),
        ]
        let out = CloudSyncMerge.diff(snapshot: [:], ledger: ledger, frozen: ["source/def"],
                                      isLocal: { CloudSyncKey.fingerprint(of: $0) != "gone" }, firstSync: false, now: now)
        #expect(out["channelPref/gone|1"] == nil)          // playlist removed here: no deletion published
        #expect(out["pref/accent"]?.deleted == false)       // preferences are never deleted
        #expect(out["history/f|old"] == nil)                // pruned after 60 days
        #expect(out["history/f|recent"]?.deleted == true)
        #expect(out["source/abc"]?.deleted == true)          // playlist deletions are kept for good
        #expect(out["source/def"] == ledger["source/def"])   // frozen: published unchanged
    }

    @Test func lastWriterWinsWithDeterministicTies() {
        let local = ["k/a": entry("k/a", .number(1), at: 100), "k/b": entry("k/b", .number(1), at: 100),
                     "k/c": entry("k/c", .number(1), at: 100), "k/d": entry("k/d", .number(1), at: 100)]
        let remote: [String: CloudSyncRemoteRecord] = [
            "k/a": .init(CloudSyncRecord(key: "k/a", updatedAt: 101, value: .number(2)), deviceId: "B"),
            "k/b": .init(CloudSyncRecord(key: "k/b", updatedAt: 99, value: .number(2)), deviceId: "B"),
            "k/c": .init(CloudSyncRecord(key: "k/c", updatedAt: 100, value: .number(2)), deviceId: "B"),
            "k/d": .init(CloudSyncRecord(key: "k/d", updatedAt: 100, value: .number(2)), deviceId: "0"),
        ]
        let decided = CloudSyncMerge.decide(local: local, remote: remote, localDeviceId: "A")
        #expect(Set(decided.keys) == ["k/a", "k/c"])
    }

    @Test func tombstonesBeatOlderValues() {
        let local = ["k/a": entry("k/a", .number(1), at: 100), "source/s": entry("source/s", .number(1), at: 100)]
        let remote: [String: CloudSyncRemoteRecord] = [
            "k/a": .init(CloudSyncRecord(key: "k/a", updatedAt: 200, deleted: true, value: nil), deviceId: "B"),
            "k/never": .init(CloudSyncRecord(key: "k/never", updatedAt: 200, deleted: true, value: nil), deviceId: "B"),
            "source/s": .init(CloudSyncRecord(key: "source/s", updatedAt: 200, deleted: true, value: nil), deviceId: "B"),
        ]
        let decided = CloudSyncMerge.decide(local: local, remote: remote, localDeviceId: "A")
        #expect(Set(decided.keys) == ["k/a"])
        // An older value doesn't bring back a newer deletion.
        let deletedHere = ["k/a": entry("k/a", nil, at: 300, deleted: true)]
        let older = ["k/a": CloudSyncRemoteRecord(CloudSyncRecord(key: "k/a", updatedAt: 250, value: .number(5)), deviceId: "B")]
        #expect(CloudSyncMerge.decide(local: deletedHere, remote: older, localDeviceId: "A").isEmpty)
    }

    @Test func sameValuesAreNotReapplied() {
        let local = ["k/a": entry("k/a", .number(1), at: 100)]
        let remote = ["k/a": CloudSyncRemoteRecord(CloudSyncRecord(key: "k/a", updatedAt: 500, value: .number(1)), deviceId: "B")]
        #expect(CloudSyncMerge.decide(local: local, remote: remote, localDeviceId: "A").isEmpty)
    }

    @Test func newestRecordAcrossDevices() {
        func file(_ id: String, _ stamp: Int64, _ value: Double) -> CloudSyncDeviceFile {
            CloudSyncDeviceFile(deviceId: id, deviceName: id, platform: "macOS", appVersion: nil, exportedAt: Date(),
                                records: [CloudSyncRecord(key: "k/a", updatedAt: stamp, value: .number(value))])
        }
        let best = CloudSyncMerge.newest([file("B", 10, 1), file("C", 20, 2), file("D", 20, 3)])
        #expect(best["k/a"]?.deviceId == "D")
        #expect(best["k/a"]?.record.value == .number(3))
    }

    @Test func deviceFilesRejectCorruptAndOtherSchemas() throws {
        #expect(throws: CloudSyncDeviceFile.ReadError.unreadable) { try CloudSyncDeviceFile.decode(Data("{\"schema\": 1, \"devi".utf8)) }
        #expect(throws: CloudSyncDeviceFile.ReadError.otherSchema(2)) { try CloudSyncDeviceFile.decode(Data(#"{"schema": 2}"#.utf8)) }
        let file = CloudSyncDeviceFile(deviceId: "A", deviceName: "Mac", platform: "macOS", appVersion: "1.5.0", exportedAt: Date(),
                                       records: [CloudSyncRecord(key: "k/a", updatedAt: 5, deleted: true, value: .number(1))])
        let back = try CloudSyncDeviceFile.decode(try file.encoded())
        #expect(back.records == [CloudSyncRecord(key: "k/a", updatedAt: 5, deleted: true, value: nil)])
    }
}
