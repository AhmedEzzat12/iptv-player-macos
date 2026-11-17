// Port of SleepTimerTests in Tests/TunerCoreTests/AudioEnhancementTests.swift
package app.tuner.core.audio

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SleepTimerTest {
    private val start = Instant.ofEpochSecond(1_000_000)

    @Test fun minutesCountDownByTheClock() {
        val timer = SleepTimer(SleepTimerOption.Minutes(15), start)
        assertEquals(900.0, timer.remaining(start, null))
        assertEquals(10.0, timer.remaining(start.plusSeconds(890), 5.0))
        assertEquals(0.0, timer.remaining(start.plusSeconds(1000), null))
        assertFalse(timer.shouldFire(1.0, false))
        assertTrue(timer.shouldFire(0.0, false))
        assertTrue(timer.shouldFire(0.0, true))
        assertEquals(listOf(15, 30, 45, 60, 90).map { SleepTimerOption.Minutes(it) }, SleepTimerOption.presets)
    }

    @Test fun endOfItemFollowsThePlayingItem() {
        val timer = SleepTimer(SleepTimerOption.EndOfItem, start)
        assertTrue(timer.isEndOfItem)
        assertNull(timer.deadline)
        assertNull(timer.remaining(start, null))
        assertEquals(42.0, timer.remaining(start, 42.0))
        assertFalse(timer.shouldFire(0.0, false))
        assertTrue(timer.shouldFire(0.0, true))
        assertFalse(timer.shouldFire(null, true))
    }

    @Test fun itemTimeLeftAccountsForSpeed() {
        assertEquals(60.0, SleepTimer.itemTimeLeft(100.0, 160.0, 1.0))
        assertEquals(30.0, SleepTimer.itemTimeLeft(100.0, 160.0, 2.0))
        assertEquals(0.0, SleepTimer.itemTimeLeft(170.0, 160.0))
        assertNull(SleepTimer.itemTimeLeft(null, 160.0))
        assertNull(SleepTimer.itemTimeLeft(10.0, 0.0))
    }

    @Test fun fadesOverTheLastTenSeconds() {
        assertEquals(1.0, SleepTimer.volumeFactor(null))
        assertEquals(1.0, SleepTimer.volumeFactor(600.0))
        assertEquals(1.0, SleepTimer.volumeFactor(10.0))
        assertEquals(0.5, SleepTimer.volumeFactor(5.0))
        assertEquals(0.0, SleepTimer.volumeFactor(0.0))
    }

    @Test fun labels() {
        assertEquals("15:00", SleepTimer.label(900.0))
        assertEquals("1:00", SleepTimer.label(59.2))
        assertEquals("1:02:03", SleepTimer.label(3723.0))
        assertEquals("0:00", SleepTimer.label(0.0))
    }
}
