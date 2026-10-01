import Foundation

/// A guide entry (XMLTV `<programme>`).
public struct Program: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64?
    /// `feedId|xmltvId`
    public var epgKey: String
    public var start: Date
    public var end: Date
    public var title: String
    public var subtitle: String?
    public var summary: String?
    public var category: String?
    public var iconURL: String?
    public var episode: String?

    public init(id: Int64? = nil, epgKey: String, start: Date, end: Date, title: String, subtitle: String? = nil, summary: String? = nil, category: String? = nil, iconURL: String? = nil, episode: String? = nil) {
        self.id = id
        self.epgKey = epgKey
        self.start = start
        self.end = end
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.category = category
        self.iconURL = iconURL
        self.episode = episode
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func isLive(at date: Date = Date()) -> Bool { start <= date && date < end }

    public func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / duration))
    }

    /// Stable identity independent of the database row id (used for reminders).
    public var stableKey: String { "\(epgKey)@\(Int(start.timeIntervalSince1970))" }
}

/// An XMLTV feed tracked by the guide service.
public struct EPGFeed: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var url: String
    /// Owning source, or nil for a global feed.
    public var sourceId: String?
    public var priority: Int
    public var lastFetchedAt: Date?
    public var lastError: String?
    public var channelCount: Int
    public var programCount: Int

    public init(id: String, url: String, sourceId: String?, priority: Int) {
        self.id = id
        self.url = url
        self.sourceId = sourceId
        self.priority = priority
        self.channelCount = 0
        self.programCount = 0
    }
}

public struct EPGChannel: Codable, Sendable, Hashable {
    public var key: String
    public var feedId: String
    public var xmltvId: String
    public var displayName: String
    public var normalizedName: String
    public var iconURL: String?

    public init(feedId: String, xmltvId: String, displayName: String, iconURL: String?) {
        self.key = "\(feedId)|\(xmltvId)"
        self.feedId = feedId
        self.xmltvId = xmltvId
        self.displayName = displayName
        self.normalizedName = ChannelNameNormalizer.normalize(displayName)
        self.iconURL = iconURL
    }
}
