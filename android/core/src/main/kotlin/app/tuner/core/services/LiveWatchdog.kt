// Port of the live-stream watchdog in Sources/Tuner/Player/PlayerSlot.swift (watchdog / streamDied).
package app.tuner.core.services

/**
 * Notices a live stream that stopped: no movement of the position or the buffer for a while. Fed from the player's
 * poll (every second); [tick] says when the stream has died and the player should fail over or reconnect.
 */
public class LiveWatchdog(
    /** Settings → Playback → stall timeout (Apple default 12 s). */
    private val stallTimeoutSeconds: Double = 12.0,
) {
    public enum class Result { OK, RECOVERED, DIED }

    private var lastPosition: Double? = null
    private var lastBufferedEnd: Double? = null
    private var lastProgressAt = 0.0
    private var loadStartedAt = 0.0

    /** Reconnect attempts since the stream last played; reset when it moves again. */
    public var retryCount: Int = 0
        private set

    /** A new stream started loading (a channel change, a failover or a reconnect). */
    public fun started(now: Double, isRetry: Boolean) {
        lastPosition = null
        lastBufferedEnd = null
        lastProgressAt = now
        loadStartedAt = now
        if (!isRetry) retryCount = 0
    }

    /** One more reconnect attempt; returns its number. */
    public fun nextRetry(): Int = ++retryCount

    /** Seconds to wait before reconnect attempt `n` (1, 2, … capped at 5). */
    public fun backoffSeconds(attempt: Int): Int = minOf(maxOf(attempt, 1), 5)

    /**
     * `position` and `bufferedEnd` in seconds (null when unknown); `ended` when the player reached the end (a live
     * stream should never); `idle` when it has nothing loaded (it failed or stopped). `paused` streams are never judged.
     */
    public fun tick(now: Double, position: Double?, bufferedEnd: Double?, ended: Boolean, idle: Boolean, paused: Boolean): Result {
        if (paused) { lastProgressAt = now; return Result.OK }
        var progressed = false
        val lp = lastPosition
        val lb = lastBufferedEnd
        if (position != null && lp != null && position - lp > 0.25) progressed = true
        if (bufferedEnd != null && lb != null && bufferedEnd - lb > 0.25) progressed = true
        if (position != null) lastPosition = position
        if (bufferedEnd != null) lastBufferedEnd = bufferedEnd
        if (progressed) {
            lastProgressAt = now
            if (retryCount > 0) { retryCount = 0; return Result.RECOVERED }
            return Result.OK
        }
        val grace = if (retryCount > 0) 10.0 else 6.0
        if (now - loadStartedAt <= grace) return Result.OK
        val stalled = now - lastProgressAt
        return if (ended || (idle && stalled > 4) || stalled > stallTimeoutSeconds) Result.DIED else Result.OK
    }

    public companion object {
        /** Settings → Playback → reconnect attempts (Apple default 10). */
        public const val MAX_RETRIES: Int = 10
    }
}
