import Foundation

/// TVmaze's public API (no key; data CC BY-SA, credited in the UI) as a second source of episode pictures.
/// Cinemeta lists a still URL for every episode, but its image host has none for many later seasons (e.g.
/// Jujutsu Kaisen S2–S3 return 404), so those episodes would only ever show the show's artwork.
struct TVmazeClient: Sendable {
    static let base = "https://api.tvmaze.com"

    let fetch: MetadataFetch

    struct Episode: Sendable, Hashable {
        var season: Int
        var episode: Int
        /// Full-size picture (TVmaze's "medium" is only 250×140, too small for episode cards).
        var imageURL: String?
    }

    /// The show's numbered episodes, or [] when TVmaze doesn't know this IMDb id. Throws on network/server errors.
    func episodes(imdbId: String) async throws -> [Episode] {
        let show: JSONObject
        do {
            // Answers with a redirect to /shows/{id}, which the HTTP client follows.
            show = try await fetch("\(Self.base)/lookup/shows?imdb=\(imdbId.urlPathEncoded)", [:])
        } catch let error where MetadataHTTP.isNotFound(error) {
            return []
        }
        guard let id = show.int("id") else { return [] }
        return Self.parseEpisodes(try await fetch("\(Self.base)/shows/\(id)?embed=episodes", [:]))
    }

    // MARK: - Pure (unit-tested)

    /// Episodes from a `/shows/{id}?embed=episodes` body. Specials without an episode number are dropped.
    static func parseEpisodes(_ show: JSONObject) -> [Episode] {
        (show.object("_embedded")?.objects("episodes") ?? []).compactMap { e in
            guard let season = e.int("season"), let number = e.int("number") else { return nil }
            let image = e.object("image")
            return Episode(season: season, episode: number, imageURL: image?.string("original") ?? image?.string("medium"))
        }
    }

    /// Adds TVmaze pictures as fallbacks (or as the still, when an episode has none). Working stills stay first.
    /// A season is only used when both sources count the same episodes in it: anime and long-running shows are
    /// often split into seasons differently, and a mismatched picture is worse than none.
    static func addFallbackStills(to episodes: [EpisodeMetadata], from tvmaze: [Episode]) -> [EpisodeMetadata] {
        let ownCounts = Dictionary(grouping: episodes, by: \.season).mapValues(\.count)
        let theirCounts = Dictionary(grouping: tvmaze, by: \.season).mapValues(\.count)
        var pictures: [Int: [Int: String]] = [:]
        for e in tvmaze {
            guard let url = e.imageURL, ownCounts[e.season] == theirCounts[e.season] else { continue }
            pictures[e.season, default: [:]][e.episode] = url
        }
        return episodes.map { episode in
            guard let picture = pictures[episode.season]?[episode.episode], picture != episode.stillURL else { return episode }
            var updated = episode
            if updated.stillURL == nil {
                updated.stillURL = picture
            } else {
                updated.fallbackStillURL = picture
            }
            return updated
        }
    }
}
