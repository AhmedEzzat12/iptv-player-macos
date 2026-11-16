// Port of Sources/TunerCore/Models/SmartContinueWatching.swift @ 666f598
package app.tuner.core.models

import app.tuner.core.nilIfEmpty
import java.time.Duration
import java.time.Instant

/** One card in Home's Continue Watching row. */
public sealed class ContinueWatchingItem {
    /** A movie or episode with a resume point. */
    public data class Resume(override val progress: WatchProgress) : ContinueWatchingItem()
    /** The episode after one that was finished, played from the start; `progress` is a not-started record for it. */
    public data class NextEpisode(val episode: Episode, override val progress: WatchProgress) : ContinueWatchingItem()

    public abstract val progress: WatchProgress
    public val id: String get() = progress.mediaId
}

/**
 * Which resume points and next episodes to offer, and in what order (Home's Up Next row uses the next episodes).
 *
 * Per show, the most recent record decides: an unfinished episode is resumed; a finished one offers the next cached
 * episode (none after the finale, or when the next is already watched); a record reset to the start takes the show out.
 * Records of a few seconds' play are passed over. Titles stopped early and untouched for weeks are left out. Nearly
 * finished titles and next episodes of shows watched this week come first, the rest by recency.
 */
public object SmartContinueWatching {
    /** At least this much watched counts as nearly finished… */
    public const val NEARLY_FINISHED_FRACTION: Double = 0.75
    /** …as does less than this left (seconds). */
    public const val NEARLY_FINISHED_REMAINING: Double = 15 * 60.0
    /** Nearly finished titles only jump the queue while they were touched this recently (seconds). */
    public const val NEARLY_FINISHED_WINDOW: Double = 30 * 86_400.0
    /** Next episodes of shows watched within this window come first (seconds). */
    public const val RECENT_SHOW_WINDOW: Double = 7 * 86_400.0
    /** Titles watched less than this… */
    public const val ABANDONED_FRACTION: Double = 0.2
    /** …and untouched for this long are left out (seconds). */
    public const val ABANDONED_AFTER: Double = 21 * 86_400.0
    /** Resume positions at or below this were never really watched. */
    internal const val RESUME_THRESHOLD: Double = 10.0
    /** The player never saves positions at or below this, so such an unfinished record is a reset. */
    internal const val RESET_THRESHOLD: Double = 5.0

    /** An entry before the next episode's details are filled in. */
    public sealed class Entry {
        public data class Resume(val progress: WatchProgress) : Entry()
        /** `episode` (from the cached episode list, possibly with only id, season and number) follows `after`. */
        public data class NextEpisode(val episode: Episode, val after: WatchProgress) : Entry()

        internal val mediaId: String get() = when (this) {
            is Resume -> progress.mediaId
            is NextEpisode -> episode.id
        }
    }

    internal sealed class Decision {
        data class Resume(val progress: WatchProgress) : Decision()
        /** The finished records sharing the latest time (several when a season was marked watched at once). */
        data class Next(val after: List<WatchProgress>) : Decision()
        object None : Decision()
    }

    private fun seconds(from: Instant, to: Instant) = Duration.between(from, to).toMillis() / 1000.0

    /**
     * The row's entries, best first. `progress`: unfinished movies plus every record of the shows to consider;
     * `episodes`: cached episodes by series id (only the shows `showsNeedingEpisodes` lists are needed).
     */
    public fun rank(progress: List<WatchProgress>, episodes: Map<String, List<Episode>>, now: Instant, limit: Int): List<Entry> {
        data class Candidate(val entry: Entry, val activity: Instant, val first: Boolean)
        val candidates = mutableListOf<Candidate>()
        for ((_, records) in progress.groupBy { p -> p.seriesId?.let { "s:$it" } ?: "m:${p.mediaId}" }) {
            val seriesId = records.first().seriesId
            when (val decision = if (seriesId != null) decide(records) else decideStandalone(records)) {
                is Decision.None -> continue
                is Decision.Resume -> {
                    val p = decision.progress
                    if (isAbandoned(p, p.updatedAt, now)) continue
                    candidates += Candidate(Entry.Resume(p), p.updatedAt, isNearlyFinished(p, p.updatedAt, now))
                }
                is Decision.Next -> {
                    val list = seriesId?.let { episodes[it] } ?: emptyList()
                    val last = latestInOrder(decision.after, list) ?: continue
                    val currentId = resolveEpisodeId(last, list) ?: continue
                    val next = EpisodeNavigation.neighbor(currentId, list, 1) ?: continue
                    val activity = last.updatedAt
                    val existing = records.firstOrNull { it.mediaId == next.id || it.episodePosition == (next.season to next.number) }
                    if (existing?.completed == true) continue
                    if (existing != null && existing.position > RESUME_THRESHOLD) {
                        // Started before, then an earlier episode was rewatched: carry on where it was left.
                        if (isAbandoned(existing, activity, now)) continue
                        candidates += Candidate(Entry.Resume(existing), activity, isNearlyFinished(existing, activity, now))
                    } else {
                        candidates += Candidate(Entry.NextEpisode(next, last), activity, seconds(activity, now) <= RECENT_SHOW_WINDOW)
                    }
                }
            }
        }
        return candidates
            .sortedWith(compareBy<Candidate> { !it.first }.thenByDescending { it.activity }.thenBy { it.entry.mediaId })
            .take(limit)
            .map { it.entry }
    }

    /** Shows whose next episode has to be looked up (their latest record is a finished episode). */
    public fun showsNeedingEpisodes(progress: List<WatchProgress>): Set<String> =
        progress.filter { it.seriesId != null }.groupBy { it.seriesId!! }
            .filterValues { decide(it) is Decision.Next }.keys

    /** The not-started record shown on a next-episode card. */
    public fun nextEpisodeRecord(episode: Episode, series: Series?, after: WatchProgress): WatchProgress = WatchProgress(
        mediaId = episode.id, kind = MediaKind.EPISODE, sourceId = episode.sourceId, seriesId = after.seriesId ?: episode.seriesId,
        title = series?.name ?: after.title,
        subtitle = "S${episode.season}, E${episode.number} · ${episode.title}",
        posterURL = episode.imageURL.nilIfEmpty() ?: series?.backdropURL.nilIfEmpty() ?: series?.coverURL.nilIfEmpty() ?: after.posterURL,
        position = 0.0, duration = (episode.durationSeconds ?: 0).toDouble(), updatedAt = after.updatedAt,
    )

    internal fun isNearlyFinished(p: WatchProgress, activity: Instant, now: Instant): Boolean {
        if (p.duration <= 0 || seconds(activity, now) > NEARLY_FINISHED_WINDOW) return false
        return p.fraction >= NEARLY_FINISHED_FRACTION || p.duration - p.position < NEARLY_FINISHED_REMAINING
    }

    internal fun isAbandoned(p: WatchProgress, activity: Instant, now: Instant): Boolean =
        p.fraction < ABANDONED_FRACTION && seconds(activity, now) >= ABANDONED_AFTER

    /** A show's records, newest first: the first that isn't a few seconds' play decides. */
    internal fun decide(records: List<WatchProgress>): Decision {
        val sorted = records.sortedByDescending { it.updatedAt }
        for (p in sorted) {
            if (p.completed) return Decision.Next(sorted.filter { it.completed && it.updatedAt == p.updatedAt })
            if (p.position > RESUME_THRESHOLD) return Decision.Resume(p)
            if (p.position <= RESET_THRESHOLD) return Decision.None
        }
        return Decision.None
    }

    /** Movies (and episodes without a show): resumed while unfinished. */
    internal fun decideStandalone(records: List<WatchProgress>): Decision {
        val p = records.maxByOrNull { it.updatedAt } ?: return Decision.None
        if (p.completed || p.position <= RESUME_THRESHOLD) return Decision.None
        return Decision.Resume(p)
    }

    /** Of several records finished at the same moment, the one furthest along the show (specials sort first). */
    internal fun latestInOrder(finished: List<WatchProgress>, episodes: List<Episode>): WatchProgress? {
        if (finished.size <= 1) return finished.firstOrNull()
        val order = HashMap<String, Pair<Int, Int>>()
        for (e in episodes) order.putIfAbsent(e.id, (if (e.season == 0) -1 else e.season) to e.number)
        fun key(p: WatchProgress) = order[p.mediaId] ?: p.episodePosition?.let { (if (it.first == 0) -1 else it.first) to it.second }
        val byPosition = Comparator<WatchProgress> { a, b ->
            val x = key(a)
            val y = key(b)
            when {
                x != null && y != null -> compareValuesBy(x, y, { it.first }, { it.second })
                x == null && y != null -> -1
                x != null && y == null -> 1
                else -> 0
            }
        }
        return finished.maxWithOrNull(byPosition)
    }

    internal fun resolveEpisodeId(progress: WatchProgress, episodes: List<Episode>): String? {
        if (episodes.any { it.id == progress.mediaId }) return progress.mediaId
        val pos = progress.episodePosition ?: return null
        return episodes.firstOrNull { it.season == pos.first && it.number == pos.second }?.id
    }
}
