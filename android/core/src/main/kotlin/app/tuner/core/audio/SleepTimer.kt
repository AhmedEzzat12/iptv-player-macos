// Port of Sources/TunerCore/Audio/SleepTimer.swift
package app.tuner.core.audio

import java.time.Instant
import kotlin.math.ceil

/** When the sleep timer stops playback. */
public sealed class SleepTimerOption {
    /** After a number of minutes (wall-clock, also while paused). */
    public data class Minutes(val minutes: Int) : SleepTimerOption()

    /** When the playing movie or episode ends (no autoplay into the next one); live TV: when the programme ends. */
    public data object EndOfItem : SleepTimerOption()

    public companion object {
        public val presets: List<SleepTimerOption> = listOf(15, 30, 45, 60, 90).map { Minutes(it) }
    }
}

/** The player's sleep timer (per session, never persisted): time left, the volume fade and when to stop. */
public class SleepTimer(public val option: SleepTimerOption, now: Instant = Instant.now()) {
    /** When a minutes timer fires. */
    public val deadline: Instant? = (option as? SleepTimerOption.Minutes)?.let { now.plusSeconds(maxOf(it.minutes, 0) * 60L) }

    public val isEndOfItem: Boolean get() = option == SleepTimerOption.EndOfItem

    /**
     * Seconds until the timer fires, or null when that isn't known yet (end of item without a duration).
     * `itemTimeLeft` is the playing item's remaining real time, or for live TV the time until the programme ends.
     */
    public fun remaining(now: Instant = Instant.now(), itemTimeLeft: Double?): Double? = when (option) {
        is SleepTimerOption.Minutes -> deadline?.let { maxOf(0.0, (it.toEpochMilli() - now.toEpochMilli()) / 1000.0) }
        SleepTimerOption.EndOfItem -> itemTimeLeft?.let { maxOf(0.0, it) }
    }

    /** End of a movie/episode fires from the player's own end event, so only minutes and live programme ends fire here. */
    public fun shouldFire(remaining: Double?, isLive: Boolean): Boolean {
        if (remaining == null || remaining > 0) return false
        return !isEndOfItem || isLive
    }

    public companion object {
        /** The volume fades out over this many seconds before the timer fires. */
        public const val FADE_SECONDS: Double = 10.0

        /** Volume multiplier: 1, then a linear fade to 0 over the last [FADE_SECONDS]. */
        public fun volumeFactor(remaining: Double?): Double {
            if (remaining == null || remaining >= FADE_SECONDS) return 1.0
            return (remaining / FADE_SECONDS).coerceIn(0.0, 1.0)
        }

        /** Real time left in a finite item at playback speed `rate`, or null without a usable position/duration. */
        public fun itemTimeLeft(position: Double?, duration: Double?, rate: Double = 1.0): Double? {
            if (position == null || duration == null || duration <= 0 || !position.isFinite() || !duration.isFinite()) return null
            return maxOf(0.0, duration - position) / maxOf(rate, 0.01)
        }

        /** "12:05" or "1:02:03" (rounded up, so it never shows 0:00 while still running). */
        public fun label(remaining: Double): String {
            val total = ceil(maxOf(0.0, remaining)).toInt()
            val h = total / 3600; val m = total % 3600 / 60; val s = total % 60
            return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
        }
    }
}
