// Port of Sources/TunerCore/Models/EpisodeNavigation.swift @ 666f598
package app.tuner.core.models

/**
 * Previous/next episode for the player: season by season, then by episode number. Specials (season 0) are only stepped
 * through while you're watching one, so "next" after a season finale is the next season's first episode.
 */
public object EpisodeNavigation {
    private fun ordered(episodes: List<Episode>, watchingSpecial: Boolean): List<Episode> =
        episodes.filter { (it.season == 0) == watchingSpecial }.sortedWith(compareBy({ it.season }, { it.number }))

    /** The episode `offset` places after (positive) or before (negative) `episodeId`, or null at either end. */
    public fun neighbor(episodeId: String, episodes: List<Episode>, offset: Int): Episode? {
        val current = episodes.firstOrNull { it.id == episodeId } ?: return null
        val list = ordered(episodes, current.season == 0)
        val index = list.indexOfFirst { it.id == episodeId }.takeIf { it >= 0 } ?: return null
        return list.getOrNull(index + offset)
    }

    /** Episodes before `episodeId` in watch order that aren't in `watched` (offered when marking one watched). */
    public fun unwatchedBefore(episodeId: String, episodes: List<Episode>, watched: Set<String>): List<Episode> {
        val current = episodes.firstOrNull { it.id == episodeId } ?: return emptyList()
        val list = ordered(episodes, current.season == 0)
        val index = list.indexOfFirst { it.id == episodeId }.takeIf { it >= 0 } ?: return emptyList()
        return list.subList(0, index).filter { it.id !in watched }
    }
}

/**
 * The "Up Next" card: shown for the last `countdown` seconds of an episode, counting down with the actual time left,
 * so pausing pauses it and nothing at the end is cut off.
 */
public object UpNextCountdown {
    /**
     * Whole seconds left to show (rounded up), or null when it shouldn't show: countdown off (0), duration unknown or
     * open-ended, playback ended, or a clip shorter than twice the countdown.
     */
    public fun secondsLeft(position: Double?, duration: Double?, countdown: Int): Int? {
        if (countdown <= 0 || position == null || duration == null || !position.isFinite() || !duration.isFinite() ||
            duration < countdown * 2.0
        ) return null
        val remaining = duration - position
        if (remaining <= 0 || remaining > countdown) return null
        return kotlin.math.ceil(remaining).toInt()
    }
}

/**
 * Finite media whose stream gives out just before the end. Provider files often report a duration a few seconds longer
 * than the picture runs, so no "ended" arrives and the Up Next countdown freezes. Stuck this close to the end counts as
 * the end.
 */
public object EndOfMediaStall {
    /** How close to the reported end a stall counts as the end. */
    public const val WINDOW: Double = 15.0

    /** How long playback must stop advancing there (seconds). */
    public const val PATIENCE: Double = 3.0

    public fun hasEnded(position: Double?, duration: Double?, stalledFor: Double): Boolean {
        if (position == null || duration == null || !position.isFinite() || !duration.isFinite() || duration <= WINDOW * 2) {
            return false
        }
        return duration - position <= WINDOW && stalledFor >= PATIENCE
    }
}
