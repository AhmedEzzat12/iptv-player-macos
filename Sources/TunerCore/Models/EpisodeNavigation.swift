import Foundation

/// Previous/next episode for the player: season by season, then by episode number. Specials (season 0) are only
/// stepped through while you're watching one, so "next" after a season finale is the next season's first episode.
public enum EpisodeNavigation {
    /// The episode `offset` places after (positive) or before (negative) `episodeId`, or nil at either end.
    public static func neighbor(of episodeId: String, in episodes: [Episode], offset: Int) -> Episode? {
        guard let current = episodes.first(where: { $0.id == episodeId }) else { return nil }
        let watchingSpecial = current.season == 0
        let ordered = episodes
            .filter { ($0.season == 0) == watchingSpecial }
            .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard let index = ordered.firstIndex(where: { $0.id == episodeId }) else { return nil }
        let target = index + offset
        return ordered.indices.contains(target) ? ordered[target] : nil
    }

    /// Episodes before `episodeId` in watch order (earlier seasons included, same specials rule as `neighbor`)
    /// that aren't in `watched`: what to offer to mark as well when marking an episode watched, as TV Time does.
    public static func unwatched(before episodeId: String, in episodes: [Episode], watched: Set<String>) -> [Episode] {
        guard let current = episodes.first(where: { $0.id == episodeId }) else { return [] }
        let watchingSpecial = current.season == 0
        let ordered = episodes
            .filter { ($0.season == 0) == watchingSpecial }
            .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard let index = ordered.firstIndex(where: { $0.id == episodeId }) else { return [] }
        return ordered[..<index].filter { !watched.contains($0.id) }
    }
}

/// The "Up Next" card: shown for the last `countdown` seconds of an episode, counting down with the actual time
/// left, so pausing pauses it and nothing at the end is cut off. When it reaches zero the episode has ended and
/// autoplay starts the next one.
public enum UpNextCountdown {
    /// Whole seconds left to show on the card (rounded up), or nil when it shouldn't show: the countdown is off
    /// (0), the duration is unknown or open-ended, playback has ended, or the clip is shorter than twice the
    /// countdown (a trailer-length clip would be covered by the card).
    public static func secondsLeft(position: Double?, duration: Double?, countdown: Int) -> Int? {
        guard countdown > 0, let position, let duration, position.isFinite, duration.isFinite,
              duration >= Double(countdown) * 2 else { return nil }
        let remaining = duration - position
        guard remaining > 0, remaining <= Double(countdown) else { return nil }
        return Int(remaining.rounded(.up))
    }
}
