import Foundation

// iCloud Drive sync (see docs/design.md → Sync): every device writes one JSON file with its user state into a shared
// folder and reads the others. Records are keyed `"<kind>/<id>"`; ids of playlist items are written as
// `"<source fingerprint>|<suffix>"` so they mean the same thing on every device.

/// What a synced record describes; the first component of its key.
public enum CloudSyncKind: String, Sendable, CaseIterable {
    /// A playlist's settings without secrets; key `source/<fingerprint>`.
    case source
    /// Resume point of a movie or episode; key `progress/<item>`.
    case progress
    case vodFavorite
    case channelPref
    case categoryPref
    /// Recently watched channel; key `history/<channel>`.
    case history
    /// Custom channel group; key `group/<group id>` (group ids are random UUIDs, the same everywhere).
    case group
    /// Channel in a custom group; key `groupMember/<group id>/<channel>`.
    case groupMember
    /// Whitelisted preference (`CloudSyncPreferences.keys`); key `pref/<name>`.
    case pref
}

public enum CloudSyncKey {
    public static func make(_ kind: CloudSyncKind, _ rest: String) -> String { "\(kind.rawValue)/\(rest)" }

    public static func kind(of key: String) -> CloudSyncKind? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        return CloudSyncKind(rawValue: String(key[..<slash]))
    }

    /// Everything after `<kind>/`.
    public static func rest(of key: String) -> String {
        guard let slash = key.firstIndex(of: "/") else { return "" }
        return String(key[key.index(after: slash)...])
    }

    /// The synced item id a key names (`fingerprint|suffix`), or nil for keys without one.
    public static func itemId(of key: String) -> String? {
        switch kind(of: key) {
        case .progress, .vodFavorite, .channelPref, .categoryPref, .history:
            return rest(of: key)
        case .groupMember:
            let rest = rest(of: key)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            return String(rest[rest.index(after: slash)...])
        case .source, .group, .pref, nil:
            return nil
        }
    }

    /// The playlist fingerprint a key depends on (nil for groups, preferences and playlists themselves).
    public static func fingerprint(of key: String) -> String? {
        itemId(of: key).flatMap(CloudSyncSourceMap.fingerprint(ofSyncId:))
    }
}

/// One synced value (or a deletion) with the time it last changed.
public struct CloudSyncRecord: Codable, Sendable, Hashable {
    public var key: String
    /// Milliseconds since 1970 (last writer wins per key).
    public var updatedAt: Int64
    public var deleted: Bool
    public var value: SyncJSON?

    public init(key: String, updatedAt: Int64, deleted: Bool = false, value: SyncJSON?) {
        self.key = key
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.value = deleted ? nil : value
    }

    enum CodingKeys: String, CodingKey { case key, updatedAt, deleted, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        value = deleted ? nil : try c.decodeIfPresent(SyncJSON.self, forKey: .value)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(updatedAt, forKey: .updatedAt)
        if deleted { try c.encode(true, forKey: .deleted) }
        if let value, !deleted { try c.encode(value, forKey: .value) }
    }

    /// Hash of the published value ("" for a deletion).
    var valueHash: String { deleted ? "" : (value ?? .null).contentHash }
}

/// The file a device writes: `<deviceId>.json` in the sync folder.
public struct CloudSyncDeviceFile: Codable, Sendable {
    /// Bumped on incompatible changes; files with another schema are skipped (with a status message).
    public static let currentSchema = 1

    public var schema: Int
    public var deviceId: String
    public var deviceName: String
    /// "macOS" or "iOS".
    public var platform: String
    public var appVersion: String?
    public var exportedAt: Date
    public var records: [CloudSyncRecord]

    public init(deviceId: String, deviceName: String, platform: String, appVersion: String?, exportedAt: Date, records: [CloudSyncRecord]) {
        schema = Self.currentSchema
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.records = records
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public enum ReadError: Error, Equatable {
        case unreadable
        case otherSchema(Int)
    }

    /// Decodes a device file; a corrupt or partial file, or one from another schema version, throws.
    public static func decode(_ data: Data) throws(ReadError) -> CloudSyncDeviceFile {
        struct Header: Decodable { var schema: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data) else { throw .unreadable }
        guard header.schema == currentSchema else { throw .otherSchema(header.schema) }
        guard let file = try? decoder.decode(CloudSyncDeviceFile.self, from: data) else { throw .unreadable }
        return file
    }
}

/// What this device last published for a key, and what its own data looked like then (`localHash`), so the next
/// export can tell local changes from values it took from other devices. Table `syncLedger` (migration v7).
public struct CloudSyncLedgerEntry: Sendable, Hashable {
    public var key: String
    public var value: SyncJSON?
    public var localHash: String
    public var updatedAt: Int64
    public var deleted: Bool

    public init(key: String, value: SyncJSON?, localHash: String, updatedAt: Int64, deleted: Bool) {
        self.key = key
        self.value = deleted ? nil : value
        self.localHash = localHash
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    var record: CloudSyncRecord { CloudSyncRecord(key: key, updatedAt: updatedAt, deleted: deleted, value: value) }
    var valueHash: String { record.valueHash }
}

/// Maps local playlist ids (`"<sourceId>_<suffix>"`) to synced ids (`"<fingerprint>|<suffix>"`) and back.
/// When the same playlist was added twice on one device, the oldest copy is the one that syncs.
public struct CloudSyncSourceMap: Sendable {
    public private(set) var fingerprintBySourceId: [String: String] = [:]
    public private(set) var sourceIdByFingerprint: [String: String] = [:]
    /// Source ids by length (longest first) for prefix matching ids whose source id contains `_`.
    private var orderedIds: [String] = []

    public init(sources: [Source]) {
        for source in sources.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            let fp = SourceFingerprint.of(source)
            guard sourceIdByFingerprint[fp] == nil else { continue }
            sourceIdByFingerprint[fp] = source.id
            fingerprintBySourceId[source.id] = fp
        }
        orderedIds = fingerprintBySourceId.keys.sorted { $0.count > $1.count }
    }

    public var fingerprints: Set<String> { Set(sourceIdByFingerprint.keys) }

    public func hasFingerprint(_ fp: String) -> Bool { sourceIdByFingerprint[fp] != nil }

    /// The local source id an item id starts with (nil when it belongs to no syncing playlist).
    public func sourceId(ofLocalId id: String) -> String? {
        if let underscore = id.firstIndex(of: "_") {
            let head = String(id[..<underscore])
            if fingerprintBySourceId[head] != nil { return head }
        }
        return orderedIds.first { id.hasPrefix($0 + "_") }
    }

    public func syncId(_ localId: String) -> String? {
        guard let sid = sourceId(ofLocalId: localId), let fp = fingerprintBySourceId[sid] else { return nil }
        return fp + "|" + localId.dropFirst(sid.count + 1)
    }

    public func localId(_ syncId: String) -> String? {
        guard let bar = syncId.firstIndex(of: "|"), let sid = sourceIdByFingerprint[String(syncId[..<bar])] else { return nil }
        return sid + "_" + syncId[syncId.index(after: bar)...]
    }

    public static func fingerprint(ofSyncId id: String) -> String? {
        guard let bar = id.firstIndex(of: "|") else { return nil }
        return String(id[..<bar])
    }
}

/// The preferences that sync (app settings that mean the same on every device). Device-specific ones — engine,
/// buffers, paths, user agents, the TMDB key, shortcuts, volume, the last channel — never do.
public enum CloudSyncPreferences {
    public static let keys: [String] = [
        "recentSearches", "pinnedCategoryIds", "categoryNameStyle", "hideAdultContent", "episodeThumbnails",
        "autoplayNextEpisode", "upNextCountdown", "resumePlayback", "metadataEnabled", "metadataLanguage", "accent",
        "aiGuideMatching", "aiRecommendations", "aiNaturalLanguageSearch",
        "homeTopTen", "homeTopTenRegion",
    ]

    /// Preferences holding lists of playlist item ids (translated like record ids).
    public static let idListKeys: Set<String> = ["pinnedCategoryIds"]
}

/// Another device seen in the sync folder.
public struct CloudSyncPeer: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var exportedAt: Date
    public var recordCount: Int
}

/// The outcome of one sync pass.
public struct CloudSyncReport: Sendable {
    public var finishedAt: Date
    /// Why the pass failed (folder unreadable, file not written); nil when it worked.
    public var error: String?
    /// Files that were skipped or are still on their way from iCloud.
    public var notices: [String] = []
    public var peers: [CloudSyncPeer] = []
    /// Preferences other devices changed, with local ids, to apply in the app.
    public var preferences: [String: SyncJSON] = [:]
    /// Database records changed by the import.
    public var appliedCount = 0
    /// Playlists created from other devices that can be refreshed straight away (no password needed).
    public var readySourceIds: [String] = []
    /// Playlists created from other devices that wait for their password.
    public var sourcesNeedingPassword = 0
    public var wroteFile = false

    public init(finishedAt: Date, error: String? = nil) {
        self.finishedAt = finishedAt
        self.error = error
    }
}

extension Date {
    /// Milliseconds since 1970 (sync timestamps).
    var syncMillis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(syncMillis: Int64) { self.init(timeIntervalSince1970: Double(syncMillis) / 1000) }
}
