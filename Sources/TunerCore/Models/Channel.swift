import Foundation

public enum CategoryKind: String, Codable, Sendable {
    case live
    case movie
    case series
}

public struct Category: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var sourceId: String
    public var kind: CategoryKind
    public var name: String
    public var providerOrder: Int

    // User state (joined from categoryPref)
    public var isHidden: Bool = false
    public var alias: String?
    public var sortIndex: Int?
    /// Number of visible items (filled by list queries).
    public var itemCount: Int = 0

    public init(id: String, sourceId: String, kind: CategoryKind, name: String, providerOrder: Int) {
        self.id = id
        self.sourceId = sourceId
        self.kind = kind
        self.name = name
        self.providerOrder = providerOrder
    }

    public var displayName: String { alias?.nilIfEmpty ?? name }
}

/// How a channel's archive (catchup) is addressed.
public enum CatchupType: String, Codable, Sendable {
    /// Xtream `timeshift/` endpoint.
    case xtream
    /// `?utc=START&lutc=NOW`
    case append
    /// `?utc=START` (also "siptv").
    case shift
    /// Flussonic `video-START-DURATION.m3u8`.
    case flussonic
    /// `?start=START` or a `catchup-source` template.
    case `default`
    /// Stalker `tv_archive` create_link.
    case stalker

    public init(m3uValue: String) {
        switch m3uValue.lowercased() {
        case "append": self = .append
        case "shift", "siptv", "timeshift": self = .shift
        case "flussonic", "flussonic-hls", "flussonic-ts", "fs": self = .flussonic
        case "xc": self = .xtream
        default: self = .default
        }
    }
}

public struct Channel: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var sourceId: String
    public var categoryId: String?
    public var name: String
    public var number: Int?
    public var providerOrder: Int
    public var logoURL: String?
    /// The provider's EPG channel id (`tvg-id`, Xtream `epg_channel_id`, Stalker `xmltv_id`).
    public var tvgId: String?
    /// Direct playable URL, or an opaque `stalker:` locator resolved at play time.
    /// For Xtream this is empty and the URL is built from `providerStreamId`.
    public var streamURL: String
    /// Raw provider id (Xtream stream_id, Stalker channel id).
    public var providerStreamId: String?
    public var catchupType: CatchupType?
    public var catchupSource: String?
    public var catchupDays: Int?
    /// Per-channel HTTP headers from `#EXTVLCOPT` (user-agent, referrer).
    public var userAgent: String?
    public var referrer: String?
    public var isAdult: Bool

    /// Resolved EPG key (`feedId|xmltvId`) computed after guide ingestion.
    public var epgKey: String?

    // User state (joined from channelPref)
    public var isFavorite: Bool = false
    public var favoriteOrder: Int?
    public var isHidden: Bool = false
    public var alias: String?
    public var epgIdOverride: String?

    public init(
        id: String,
        sourceId: String,
        categoryId: String?,
        name: String,
        number: Int? = nil,
        providerOrder: Int,
        logoURL: String? = nil,
        tvgId: String? = nil,
        streamURL: String,
        providerStreamId: String? = nil,
        catchupType: CatchupType? = nil,
        catchupSource: String? = nil,
        catchupDays: Int? = nil,
        userAgent: String? = nil,
        referrer: String? = nil,
        isAdult: Bool = false
    ) {
        self.id = id
        self.sourceId = sourceId
        self.categoryId = categoryId
        self.name = name
        self.number = number
        self.providerOrder = providerOrder
        self.logoURL = logoURL
        self.tvgId = tvgId
        self.streamURL = streamURL
        self.providerStreamId = providerStreamId
        self.catchupType = catchupType
        self.catchupSource = catchupSource
        self.catchupDays = catchupDays
        self.userAgent = userAgent
        self.referrer = referrer
        self.isAdult = isAdult
    }

    public var displayName: String { alias?.nilIfEmpty ?? name }
    public var hasCatchup: Bool { catchupType != nil && (catchupDays ?? 1) > 0 }
}

extension String {
    public var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
