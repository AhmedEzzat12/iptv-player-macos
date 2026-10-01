import Foundation

/// A cast member as shown on detail pages.
public struct CastMember: Codable, Sendable, Hashable {
    public var name: String
    public var character: String?
    public var photoURL: String?

    public init(name: String, character: String? = nil, photoURL: String? = nil) {
        self.name = name
        self.character = character
        self.photoURL = photoURL
    }
}

/// Per-episode artwork and text from the online catalogue (matched to provider episodes by season/number).
public struct EpisodeMetadata: Codable, Sendable, Hashable {
    public var season: Int
    public var episode: Int
    public var title: String?
    public var overview: String?
    public var stillURL: String?
    /// A second picture source, tried when `stillURL` doesn't load (Cinemeta lists still URLs that don't exist for
    /// many later seasons). Optional, so metadata cached before it existed still decodes.
    public var fallbackStillURL: String?
    public var airDate: String?
    public var rating: Double?

    public init(season: Int, episode: Int, title: String? = nil, overview: String? = nil, stillURL: String? = nil,
                fallbackStillURL: String? = nil, airDate: String? = nil, rating: Double? = nil) {
        self.season = season
        self.episode = episode
        self.title = title
        self.overview = overview
        self.stillURL = stillURL
        self.fallbackStillURL = fallbackStillURL
        self.airDate = airDate
        self.rating = rating
    }
}

/// Rich metadata for a movie or series from an online catalogue (Cinemeta or TMDB).
public struct MediaMetadata: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case movie
        case series
    }

    public var kind: Kind
    /// Human-readable source, e.g. "Cinemeta" or "TMDB".
    public var source: String
    public var imdbId: String?
    public var tmdbId: String?
    public var title: String
    public var originalTitle: String?
    public var year: String?
    public var overview: String?
    public var tagline: String?
    public var posterURL: String?
    public var backdropURL: String?
    /// Transparent title artwork (used instead of text on heroes, like the TV app).
    public var logoURL: String?
    public var genres: [String]
    public var runtimeMinutes: Int?
    /// 0–10 (IMDb or TMDB vote average).
    public var rating: Double?
    public var releaseDate: String?
    public var country: String?
    public var cast: [CastMember]
    public var directors: [String]
    public var writers: [String]
    public var trailerYouTubeId: String?
    public var episodes: [EpisodeMetadata]
    public var fetchedAt: Date

    public init(kind: Kind, source: String, title: String, fetchedAt: Date = Date()) {
        self.kind = kind
        self.source = source
        self.title = title
        self.genres = []
        self.cast = []
        self.directors = []
        self.writers = []
        self.episodes = []
        self.fetchedAt = fetchedAt
    }

    public func episode(season: Int, number: Int) -> EpisodeMetadata? {
        episodes.first { $0.season == season && $0.episode == number }
    }
}

/// User-facing metadata configuration.
public struct MetadataSettings: Sendable, Hashable {
    /// Master switch for online lookups (cached results are still shown when off).
    public var enabled: Bool
    /// Optional TMDB API key (v3 key or v4 read-access token). When set, TMDB is preferred over Cinemeta.
    public var tmdbAPIKey: String?
    /// BCP-47 language for TMDB text, e.g. "en-US".
    public var language: String

    public init(enabled: Bool = true, tmdbAPIKey: String? = nil, language: String = "en-US") {
        self.enabled = enabled
        self.tmdbAPIKey = tmdbAPIKey
        self.language = language
    }
}

/// A free online XMLTV guide (epgshare01.online catalogue).
public struct OnlineGuide: Sendable, Hashable, Identifiable {
    /// File name, e.g. "epg_ripper_SA1.xml.gz".
    public var id: String
    /// Display name, e.g. "Saudi Arabia" or "beIN Sports".
    public var name: String
    /// Variant number when a region has several files ("1", "2"), else nil.
    public var variant: String?
    /// ISO country code when the file is per-country ("SA"), else nil.
    public var countryCode: String?
    public var url: String

    public init(id: String, name: String, variant: String?, countryCode: String?, url: String) {
        self.id = id
        self.name = name
        self.variant = variant
        self.countryCode = countryCode
        self.url = url
    }
}
