import Foundation

/// A playlist provider configured by the user.
public struct Source: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case m3u
        case xtream
        case stalker

        public var displayName: String {
            switch self {
            case .m3u: "M3U Playlist"
            case .xtream: "Xtream Codes"
            case .stalker: "Stalker Portal"
            }
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Playlist URL (M3U), server base URL (Xtream) or portal URL (Stalker).
    /// Local M3U files are stored as `file://` URLs.
    public var url: String
    public var username: String?
    public var password: String?
    /// Stalker MAC address, e.g. `00:1A:79:12:34:56`.
    public var mac: String?

    /// Manual EPG URL; when set it replaces the provider-discovered one.
    public var epgURL: String?
    /// Use the provider's EPG (Xtream `xmltv.php`, M3U `url-tvg`, Stalker `get_epg_info`).
    public var autoLoadEPG: Bool
    /// Extra XMLTV feeds used to fill gaps after the primary feed.
    public var extraEPGURLs: [String]
    /// Shift applied to this source's guide data, for providers with wrong timezones.
    public var epgTimeshiftHours: Double

    public var userAgent: String?
    /// Alternate server URLs tried in order when the primary fails during sync.
    public var backupURLs: [String]

    public var enabled: Bool
    public var includeLive: Bool
    public var includeVOD: Bool
    /// Refresh interval in hours; `nil` uses the global setting, `0` means manual only.
    public var refreshHours: Int?
    public var sortIndex: Int
    public var createdAt: Date

    // MARK: Sync status (written by SyncService)
    public var lastSyncedAt: Date?
    public var lastVODSyncedAt: Date?
    public var lastError: String?
    public var expiresAt: Date?
    public var activeConnections: Int?
    public var maxConnections: Int?
    /// EPG URL discovered from the provider (Xtream server_info, M3U header).
    public var discoveredEPGURL: String?
    public var channelCount: Int
    public var movieCount: Int
    public var seriesCount: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: Kind,
        url: String,
        username: String? = nil,
        password: String? = nil,
        mac: String? = nil,
        epgURL: String? = nil,
        autoLoadEPG: Bool = true,
        extraEPGURLs: [String] = [],
        epgTimeshiftHours: Double = 0,
        userAgent: String? = nil,
        backupURLs: [String] = [],
        enabled: Bool = true,
        includeLive: Bool = true,
        includeVOD: Bool = true,
        refreshHours: Int? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.username = username
        self.password = password
        self.mac = mac
        self.epgURL = epgURL
        self.autoLoadEPG = autoLoadEPG
        self.extraEPGURLs = extraEPGURLs
        self.epgTimeshiftHours = epgTimeshiftHours
        self.userAgent = userAgent
        self.backupURLs = backupURLs
        self.enabled = enabled
        self.includeLive = includeLive
        self.includeVOD = includeVOD
        self.refreshHours = refreshHours
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.channelCount = 0
        self.movieCount = 0
        self.seriesCount = 0
    }

    /// Server base URL without trailing slashes (Xtream/Stalker).
    public var baseURL: String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public var supportsVOD: Bool { kind != .m3u }
}
