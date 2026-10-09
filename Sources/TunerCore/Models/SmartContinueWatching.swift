import Foundation

/// One card in Home's Continue Watching row.
public enum ContinueWatchingItem: Sendable, Hashable, Identifiable {
    /// A movie or episode with a resume point.
    case resume(WatchProgress)
    /// The episode after one that was finished, played from the start. `progress` is a not-started record for it
    /// (show name, "S2, E4 · Title", artwork) so the card can be marked watched or removed like a resume entry.
    case nextEpisode(Episode, progress: WatchProgress)

    public var id: String { progress.mediaId }

    public var progress: WatchProgress {
        switch self {
        case .resume(let p): p
        case .nextEpisode(_, let p): p
        }
    }
}

/// Smart Continue Watching (Settings › AI): which entries the row shows and in what order.
///
/// Per show, the most recent record decides: an unfinished episode is resumed; a finished one offers the next
/// cached episode (none after the finale, or when the next is already watched); a record reset to the start
/// (marked unwatched, or removed from the row) takes the show out. Records of a few seconds' play are passed over.
/// Titles stopped early and not touched for weeks are left out. Nearly finished titles and next episodes of shows
/// watched this week come first, the rest by recency.
public enum SmartContinueWatching {
    /// At least this much watched counts as nearly finished…
    public static let nearlyFinishedFraction = 0.75
    /// …as does less than this left.
    public static let nearlyFinishedRemaining: TimeInterval = 15 * 60
    /// Nearly finished titles only jump the queue while they were touched this recently.
    public static let nearlyFinishedWindow: TimeInterval = 30 * 86_400
    /// Next episodes of shows watched within this window come first.
    public static let recentShowWindow: TimeInterval = 7 * 86_400
    /// Titles watched less than this…
    public static let abandonedFraction = 0.2
    /// …and untouched for this long are left out.
    public static let abandonedAfter: TimeInterval = 21 * 86_400

    /// Resume positions at or below this were never really watched (`WatchProgress` resumes past 10 s).
    static let resumeThreshold: Double = 10
    /// The player never saves positions at or below this, so such an unfinished record is a reset.
    static let resetThreshold: Double = 5

    /// An entry before the next episode's details are filled in.
    public enum Entry: Sendable, Hashable {
        case resume(WatchProgress)
        /// `episode` (from the cached episode list, possibly with only its id, season and number) follows `finished`.
        case nextEpisode(Episode, after: WatchProgress)
    }

    /// What a show's most recent activity calls for, before looking at its episodes.
    enum Decision: Equatable {
        case resume(WatchProgress)
        /// The finished records sharing the latest time (several when a season was marked watched at once).
        case next(after: [WatchProgress])
        case none
    }

    // MARK: Ranking

    /// The row's entries, best first.
    /// - Parameters:
    ///   - progress: unfinished movies plus every record of the shows to consider.
    ///   - episodes: cached episodes by series id (only the shows `showsNeedingEpisodes` lists are needed).
    public static func rank(progress: [WatchProgress], episodes: [String: [Episode]], now: Date, limit: Int) -> [Entry] {
        var candidates: [(entry: Entry, activity: Date, first: Bool)] = []
        for (_, records) in Dictionary(grouping: progress, by: { $0.seriesId.map { "s:" + $0 } ?? "m:" + $0.mediaId }) {
            let seriesId = records.first?.seriesId
            let decision = seriesId != nil ? decide(records) : decideStandalone(records)
            switch decision {
            case .none:
                continue
            case .resume(let p):
                guard !isAbandoned(p, activity: p.updatedAt, now: now) else { continue }
                candidates.append((.resume(p), p.updatedAt, isNearlyFinished(p, activity: p.updatedAt, now: now)))
            case .next(let finished):
                let list = seriesId.flatMap { episodes[$0] } ?? []
                guard let last = latestInOrder(finished, episodes: list),
                      let next = EpisodeNavigation.neighbor(of: last.mediaId, in: list, offset: 1) else { continue }
                let activity = last.updatedAt
                let existing = records.first { $0.mediaId == next.id }
                if existing?.completed == true { continue }
                if let existing, existing.position > resumeThreshold {
                    // Started before, then an earlier episode was rewatched: carry on where it was left.
                    guard !isAbandoned(existing, activity: activity, now: now) else { continue }
                    candidates.append((.resume(existing), activity, isNearlyFinished(existing, activity: activity, now: now)))
                } else {
                    candidates.append((.nextEpisode(next, after: last), activity, now.timeIntervalSince(activity) <= recentShowWindow))
                }
            }
        }
        candidates.sort { a, b in
            if a.first != b.first { return a.first }
            if a.activity != b.activity { return a.activity > b.activity }
            return a.entry.mediaId < b.entry.mediaId
        }
        return candidates.prefix(limit).map(\.entry)
    }

    /// Shows whose next episode has to be looked up (their latest record is a finished episode).
    public static func showsNeedingEpisodes(_ progress: [WatchProgress]) -> Set<String> {
        var result = Set<String>()
        let shows = Dictionary(grouping: progress.compactMap { p in p.seriesId.map { ($0, p) } }, by: \.0)
        for (seriesId, pairs) in shows {
            if case .next = decide(pairs.map(\.1)) { result.insert(seriesId) }
        }
        return result
    }

    /// The not-started record shown on a next-episode card.
    public static func nextEpisodeRecord(_ episode: Episode, series: Series?, after finished: WatchProgress) -> WatchProgress {
        WatchProgress(
            mediaId: episode.id, kind: .episode, sourceId: episode.sourceId, seriesId: finished.seriesId ?? episode.seriesId,
            title: series?.name ?? finished.title,
            subtitle: "S\(episode.season), E\(episode.number) · \(episode.title)",
            posterURL: episode.imageURL?.nilIfEmpty ?? series?.backdropURL?.nilIfEmpty ?? series?.coverURL?.nilIfEmpty ?? finished.posterURL,
            position: 0, duration: Double(episode.durationSeconds ?? 0), updatedAt: finished.updatedAt
        )
    }

    // MARK: Rules

    static func isNearlyFinished(_ p: WatchProgress, activity: Date, now: Date) -> Bool {
        guard p.duration > 0, now.timeIntervalSince(activity) <= nearlyFinishedWindow else { return false }
        return p.fraction >= nearlyFinishedFraction || p.duration - p.position < nearlyFinishedRemaining
    }

    static func isAbandoned(_ p: WatchProgress, activity: Date, now: Date) -> Bool {
        p.fraction < abandonedFraction && now.timeIntervalSince(activity) >= abandonedAfter
    }

    /// A show's records, newest first: the first that isn't a few seconds' play decides.
    static func decide(_ records: [WatchProgress]) -> Decision {
        let sorted = records.sorted { $0.updatedAt > $1.updatedAt }
        for p in sorted {
            if p.completed {
                return .next(after: sorted.filter { $0.completed && $0.updatedAt == p.updatedAt })
            }
            if p.position > resumeThreshold { return .resume(p) }
            if p.position <= resetThreshold { return .none }
        }
        return .none
    }

    /// Movies (and episodes without a show): resumed while unfinished.
    static func decideStandalone(_ records: [WatchProgress]) -> Decision {
        guard let p = records.max(by: { $0.updatedAt < $1.updatedAt }), !p.completed, p.position > resumeThreshold else { return .none }
        return .resume(p)
    }

    /// Of several records finished at the same moment, the one furthest along the show.
    static func latestInOrder(_ finished: [WatchProgress], episodes: [Episode]) -> WatchProgress? {
        guard finished.count > 1 else { return finished.first }
        let order = Dictionary(episodes.map { ($0.id, ($0.season == 0 ? -1 : $0.season, $0.number)) }, uniquingKeysWith: { a, _ in a })
        return finished.max { a, b in
            switch (order[a.mediaId], order[b.mediaId]) {
            case let (x?, y?): x < y
            case (nil, _?): true
            default: false
            }
        }
    }
}

extension SmartContinueWatching.Entry {
    var mediaId: String {
        switch self {
        case .resume(let p): p.mediaId
        case .nextEpisode(let e, _): e.id
        }
    }
}
