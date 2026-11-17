package app.tuner.core.services

import kotlin.test.Test
import kotlin.test.assertEquals

class LiveWatchdogTest {
    @Test fun movingStreamIsFine() {
        val w = LiveWatchdog()
        w.started(0.0, isRetry = false)
        for (t in 1..60) assertEquals(LiveWatchdog.Result.OK, w.tick(t.toDouble(), t.toDouble(), t + 5.0, ended = false, idle = false, paused = false))
    }

    @Test fun stallLongerThanTheTimeoutDies() {
        val w = LiveWatchdog(stallTimeoutSeconds = 12.0)
        w.started(0.0, isRetry = false)
        for (t in 1..10) w.tick(t.toDouble(), t.toDouble(), t + 5.0, false, false, false)
        // Frozen at 10 s from now on.
        assertEquals(LiveWatchdog.Result.OK, w.tick(22.0, 10.0, 15.0, false, false, false))
        assertEquals(LiveWatchdog.Result.DIED, w.tick(23.0, 10.0, 15.0, false, false, false))
    }

    @Test fun graceAfterLoadingAndLongerAfterARetry() {
        val w = LiveWatchdog()
        w.started(0.0, isRetry = false)
        assertEquals(LiveWatchdog.Result.OK, w.tick(6.0, null, null, false, idle = true, paused = false))
        assertEquals(LiveWatchdog.Result.DIED, w.tick(7.0, null, null, false, idle = true, paused = false))
        assertEquals(1, w.nextRetry())
        w.started(100.0, isRetry = true)
        assertEquals(LiveWatchdog.Result.OK, w.tick(110.0, null, null, false, idle = true, paused = false))
        assertEquals(LiveWatchdog.Result.DIED, w.tick(111.0, null, null, false, idle = true, paused = false))
    }

    @Test fun endedOrIdleDiesEarly() {
        val w = LiveWatchdog()
        w.started(0.0, isRetry = false)
        assertEquals(LiveWatchdog.Result.DIED, w.tick(7.0, 3.0, 3.0, ended = true, idle = false, paused = false))
    }

    @Test fun recoveringResetsRetries() {
        val w = LiveWatchdog()
        w.started(0.0, isRetry = false)
        w.nextRetry(); w.nextRetry()
        w.started(50.0, isRetry = true)
        w.tick(51.0, 0.0, 1.0, false, false, false)
        assertEquals(LiveWatchdog.Result.RECOVERED, w.tick(52.0, 1.0, 2.0, false, false, false))
        assertEquals(0, w.retryCount)
    }

    @Test fun pausedIsNeverJudged() {
        val w = LiveWatchdog()
        w.started(0.0, isRetry = false)
        for (t in 1..100) assertEquals(LiveWatchdog.Result.OK, w.tick(t.toDouble(), 5.0, 5.0, false, false, paused = true))
    }

    @Test fun backoffIsCapped() {
        val w = LiveWatchdog()
        assertEquals(listOf(1, 2, 3, 4, 5, 5), (1..6).map { w.backoffSeconds(it) })
    }
}
