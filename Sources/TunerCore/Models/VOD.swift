import Foundation

public struct Movie: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var sourceId: String
    public var categoryId: String?
    public var name: String
    public var year: String?
    public var posterURL: String?
    public var backdropURL: String?
    /// Raw provider id (Xtream stream_id / Stalker video id).
    public var providerId: String
    public var containerExtension: String?
    /// Direct URL (M3U VOD / Stalker locator); empty for Xtream (built at play time).
    public var streamURL: String
    public var rating: Double?
    public var plot: String?
    public var genre: String?
    public var cast: String?
    public var director: String?
    public var releaseDate: String?
    public var durationSeconds: Int?
    public var addedAt: Date?
    public var providerOrder: Int
    public var trailer: String?
    public var tmdbId: String?

    public init(id: String, sourceId: String, categoryId: String?, name: String, providerId: String, streamURL: String = "", providerOrder: Int) {
        self.id = id
        self.sourceId = sourceId
        self.categoryId = categoryId
        self.name = name
        self.providerId = providerId
        self.streamURL = streamURL
        self.providerOrder = providerOrder
    }
}

public struct Series: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var sourceId: String
    public var categoryId: String?
    public var name: String
    public var year: String?
    public var coverURL: String?
    public var backdropURL: String?
    public var providerId: String
    public var rating: Double?
    public var plot: String?
    public var genre: String?
    public var cast: String?
    public var director: String?
    public var releaseDate: String?
    public var addedAt: Date?
    public var lastModified: Date?
    public var providerOrder: Int
    public var trailer: String?
    /// Stalker playback command for the series (episodes resolve from it).
    public var streamURL: String

    public init(id: String, sourceId: String, categoryId: String?, name: String, providerId: String, streamURL: String = "", providerOrder: Int) {
        self.id = id
        self.sourceId = sourceId
        self.categoryId = categoryId
        self.name = name
        self.providerId = providerId
        self.streamURL = streamURL
        self.providerOrder = providerOrder
    }
}

public struct Episode: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var seriesId: String
    public var sourceId: String
    public var season: Int
    public var number: Int
    public var title: String
    public var plot: String?
    public var imageURL: String?
    public var durationSeconds: Int?
    public var providerId: String
    public var containerExtension: String?
    public var streamURL: String
    public var airDate: String?

    public init(id: String, seriesId: String, sourceId: String, season: Int, number: Int, title: String, providerId: String, streamURL: String = "") {
        self.id = id
        self.seriesId = seriesId
        self.sourceId = sourceId
        self.season = season
        self.number = number
        self.title = title
        self.providerId = providerId
        self.streamURL = streamURL
    }

    public var code: String { String(format: "S%02dE%02d", season, number) }
}

/// Extra details fetched lazily when a movie or series is opened.
public struct VODDetails: Sendable, Hashable {
    public var plot: String?
    public var cast: String?
    public var director: String?
    public var genre: String?
    public var releaseDate: String?
    public var rating: Double?
    public var durationSeconds: Int?
    public var backdropURL: String?
    public var posterURL: String?
    public var trailer: String?
    public var containerExtension: String?
    public var tmdbId: String?
    public var episodes: [Episode] = []

    public init() {}
}

public enum MediaKind: String, Codable, Sendable {
    case movie
    case episode
    case channel
}

/// Resume position for movies and episodes.
public struct WatchProgress: Codable, Sendable, Hashable, Identifiable {
    public var id: String { mediaId }
    public var mediaId: String
    public var kind: MediaKind
    public var sourceId: String
    public var seriesId: String?
    public var title: String
    public var subtitle: String?
    public var posterURL: String?
    public var position: Double
    public var duration: Double
    public var completed: Bool
    public var updatedAt: Date

    public init(mediaId: String, kind: MediaKind, sourceId: String, seriesId: String? = nil, title: String, subtitle: String? = nil, posterURL: String? = nil, position: Double, duration: Double, completed: Bool = false, updatedAt: Date = Date()) {
        self.mediaId = mediaId
        self.kind = kind
        self.sourceId = sourceId
        self.seriesId = seriesId
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.position = position
        self.duration = duration
        self.completed = completed
        self.updatedAt = updatedAt
    }

    public var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    /// Matches ynotv: ≥90% watched or within 5 s of the end counts as finished.
    public static func isComplete(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        return position / duration >= 0.9 || duration - position <= 5
    }
}
