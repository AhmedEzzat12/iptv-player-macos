// Port of Tests/TunerCoreTests/EpisodeNavigationTests.swift @ 666f598
package app.tuner.core.models

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun ep(season: Int, number: Int) =
    Episode(id = "s${season}e$number", seriesId = "show", sourceId = "src", season = season, number = number,
        title = "S${season}E$number", providerId = "$season-$number")

class EpisodeNavigationTest {
    /** Deliberately unordered, with specials and a gap (no S2E2). */
    private val episodes = listOf(ep(2, 1), ep(1, 2), ep(0, 1), ep(1, 1), ep(2, 3), ep(0, 2))

    @Test fun nextCrossesIntoTheNextSeason() {
        assertEquals("s2e1", EpisodeNavigation.neighbor("s1e2", episodes, 1)?.id)
        assertEquals("s2e3", EpisodeNavigation.neighbor("s2e1", episodes, 1)?.id) // skips the gap
    }

    @Test fun previousCrossesBackIntoThePreviousSeason() {
        assertEquals("s1e2", EpisodeNavigation.neighbor("s2e1", episodes, -1)?.id)
    }

    @Test fun endsOfTheListHaveNoNeighbour() {
        assertNull(EpisodeNavigation.neighbor("s1e1", episodes, -1))
        assertNull(EpisodeNavigation.neighbor("s2e3", episodes, 1))
        assertNull(EpisodeNavigation.neighbor("missing", episodes, 1))
    }

    @Test fun specialsAreSkippedUnlessYouAreWatchingOne() {
        assertEquals("s1e2", EpisodeNavigation.neighbor("s1e1", episodes, 1)?.id)
        assertEquals("s0e2", EpisodeNavigation.neighbor("s0e1", episodes, 1)?.id)
        assertNull(EpisodeNavigation.neighbor("s0e2", episodes, 1))
    }
}

class EarlierEpisodesTest {
    private val episodes = listOf(ep(1, 1), ep(1, 2), ep(2, 1), ep(2, 2), ep(0, 1))

    @Test fun listsUnwatchedEpisodesBeforeIncludingEarlierSeasons() {
        assertEquals(listOf("s1e1", "s2e1"), EpisodeNavigation.unwatchedBefore("s2e2", episodes, setOf("s1e2")).map { it.id })
    }

    @Test fun nothingToAskForTheFirstEpisodeOrWhenAllAreWatched() {
        assertTrue(EpisodeNavigation.unwatchedBefore("s1e1", episodes, emptySet()).isEmpty())
        assertTrue(EpisodeNavigation.unwatchedBefore("s2e2", episodes, setOf("s1e1", "s1e2", "s2e1")).isEmpty())
        assertTrue(EpisodeNavigation.unwatchedBefore("missing", episodes, emptySet()).isEmpty())
    }

    @Test fun specialsOnlyAskAboutEarlierSpecials() {
        assertTrue(EpisodeNavigation.unwatchedBefore("s0e1", episodes, emptySet()).isEmpty())
    }
}

class UpNextCountdownTest {
    @Test fun showsOnlyDuringTheLastSecondsRoundedUp() {
        assertNull(UpNextCountdown.secondsLeft(1300.0, 1320.0, 10))
        assertEquals(10, UpNextCountdown.secondsLeft(1310.0, 1320.0, 10))
        assertEquals(4, UpNextCountdown.secondsLeft(1316.2, 1320.0, 10))
        assertEquals(1, UpNextCountdown.secondsLeft(1319.9, 1320.0, 10))
    }

    @Test fun hiddenWhenOffFinishedOrUnknown() {
        assertNull(UpNextCountdown.secondsLeft(1315.0, 1320.0, 0))
        assertNull(UpNextCountdown.secondsLeft(1320.0, 1320.0, 10))
        assertNull(UpNextCountdown.secondsLeft(null, 1320.0, 10))
        assertNull(UpNextCountdown.secondsLeft(5.0, null, 10))
        assertNull(UpNextCountdown.secondsLeft(5.0, Double.POSITIVE_INFINITY, 10))
    }

    @Test fun notForClipsShorterThanTwiceTheCountdown() {
        assertNull(UpNextCountdown.secondsLeft(12.0, 15.0, 10))
        assertEquals(8, UpNextCountdown.secondsLeft(22.0, 30.0, 10))
    }
}

class EndOfMediaStallTest {
    @Test fun stuckInTheLastSecondsCountsAsTheEnd() {
        assertTrue(EndOfMediaStall.hasEnded(1312.0, 1320.0, 3.0))
        assertTrue(EndOfMediaStall.hasEnded(1305.0, 1320.0, 10.0))
    }

    @Test fun notWhileStillAdvancingOrFarFromTheEnd() {
        assertFalse(EndOfMediaStall.hasEnded(1312.0, 1320.0, 1.0))
        assertFalse(EndOfMediaStall.hasEnded(1200.0, 1320.0, 30.0))
    }

    @Test fun notForUnknownDurationsOrShortClips() {
        assertFalse(EndOfMediaStall.hasEnded(1312.0, null, 10.0))
        assertFalse(EndOfMediaStall.hasEnded(5.0, Double.POSITIVE_INFINITY, 10.0))
        assertFalse(EndOfMediaStall.hasEnded(20.0, 25.0, 10.0))
    }
}
