// Port of the rank/order suites in Tests/TunerCoreTests/SmartContinueWatchingTests.swift @ 666f598.
// The "database" suite needs the Room layer and is ported in phase 3 (data).
package app.tuner.core.models

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private val now: Instant = Instant.ofEpochSecond(1_800_000_000)
private const val HOUR = 3600.0
private const val DAY = 86_400.0

private fun ago(seconds: Double): Instant = now.minusMillis((seconds * 1000).toLong())

private fun ep(season: Int, number: Int, show: String = "show") =
    Episode(id = "$show-s${season}e$number", seriesId = show, sourceId = "src", season = season, number = number,
        title = "Episode $number", providerId = "$season-$number")

/** An episode record `ago` seconds old; default duration 2400 s (40 min). */
private fun episode(season: Int, number: Int, show: String = "show", position: Double, completed: Boolean = false,
                    ago: Double, duration: Double = 2400.0) =
    WatchProgress(mediaId = "$show-s${season}e$number", kind = MediaKind.EPISODE, sourceId = "src", seriesId = show, title = show,
        subtitle = "S$season, E$number · Episode $number", position = position, duration = duration, completed = completed,
        updatedAt = ago(ago))

private fun finished(season: Int, number: Int, show: String = "show", ago: Double) =
    episode(season, number, show, position = 2400.0, completed = true, ago = ago)

/** A two-hour movie record. */
private fun movie(id: String, position: Double, ago: Double, duration: Double = 7200.0) =
    WatchProgress(mediaId = id, kind = MediaKind.MOVIE, sourceId = "src", title = id, position = position, duration = duration,
        updatedAt = ago(ago))

/** Two seasons of three episodes, plus a special. */
private val showEpisodes = mapOf("show" to listOf(ep(1, 1), ep(1, 2), ep(1, 3), ep(2, 1), ep(2, 2), ep(2, 3), ep(0, 1)))

private fun rank(progress: List<WatchProgress>, episodes: Map<String, List<Episode>> = showEpisodes, limit: Int = 20) =
    SmartContinueWatching.rank(progress, episodes, now, limit)

/** "next:<episode id>" or "resume:<media id>". */
private fun ids(entries: List<SmartContinueWatching.Entry>) = entries.map {
    when (it) {
        is SmartContinueWatching.Entry.Resume -> "resume:${it.progress.mediaId}"
        is SmartContinueWatching.Entry.NextEpisode -> "next:${it.episode.id}"
    }
}

class SmartContinueWatchingNextEpisodeTest {
    @Test fun finishingAnEpisodeOffersTheNextOne() {
        val entries = rank(listOf(finished(1, 1, ago = HOUR * 2), finished(1, 2, ago = HOUR)))
        assertEquals(listOf("next:show-s1e3"), ids(entries))
        assertEquals("show-s1e2", (entries.first() as SmartContinueWatching.Entry.NextEpisode).after.mediaId)
    }

    @Test fun aSeasonFinaleLeadsIntoTheNextSeason() {
        assertEquals(listOf("next:show-s2e1"), ids(rank(listOf(finished(1, 3, ago = HOUR)))))
    }

    @Test fun theLastCachedEpisodeLeavesTheRow() {
        assertTrue(rank(listOf(finished(2, 3, ago = HOUR))).isEmpty())
    }

    @Test fun noCachedEpisodesMeansNoCard() {
        assertTrue(rank(listOf(finished(1, 1, ago = HOUR)), episodes = emptyMap()).isEmpty())
        assertTrue(rank(listOf(finished(5, 1, ago = HOUR))).isEmpty())
    }

    @Test fun aNextEpisodeAlreadyWatchedIsSkipped() {
        assertTrue(rank(listOf(finished(1, 3, ago = DAY * 30), finished(1, 2, ago = HOUR))).isEmpty())
    }

    @Test fun aNextEpisodeWithAResumePointIsResumed() {
        assertEquals(listOf("resume:show-s1e3"), ids(rank(listOf(episode(1, 3, position = 600.0, ago = DAY), finished(1, 2, ago = HOUR)))))
    }

    @Test fun anUnfinishedLatestEpisodeIsResumedAsToday() {
        assertEquals(listOf("resume:show-s1e2"), ids(rank(listOf(finished(1, 1, ago = DAY), episode(1, 2, position = 900.0, ago = HOUR)))))
    }

    @Test fun aFewSecondsOfPlayDoNotCount() {
        assertEquals(listOf("next:show-s1e3"), ids(rank(listOf(finished(1, 2, ago = HOUR), episode(1, 3, position = 8.0, ago = 60.0)))))
        assertEquals(listOf("resume:show-s1e2"),
            ids(rank(listOf(episode(1, 2, position = 900.0, ago = HOUR), episode(2, 2, position = 8.0, ago = 60.0)))))
    }

    @Test fun aResetRecordTakesTheShowOut() {
        assertTrue(rank(listOf(finished(1, 2, ago = HOUR), episode(1, 3, position = 0.0, ago = 60.0))).isEmpty())
        assertTrue(rank(listOf(finished(1, 1, ago = DAY), episode(1, 2, position = 0.0, ago = 60.0))).isEmpty())
    }

    @Test fun aSeasonMarkedWatchedAtOnceContinuesAfterItsLastEpisode() {
        val marked = listOf(finished(1, 2, ago = HOUR), finished(1, 3, ago = HOUR), finished(1, 1, ago = HOUR))
        assertEquals(listOf("next:show-s2e1"), ids(rank(marked)))
    }

    @Test fun specialsStepThroughSpecials() {
        val episodes = mapOf("show" to listOf(ep(1, 1), ep(0, 1), ep(0, 2)))
        assertEquals(listOf("next:show-s0e2"), ids(rank(listOf(finished(0, 1, ago = HOUR)), episodes = episodes)))
    }

    @Test fun onlyShowsEndingOnAFinishedEpisodeNeedTheirEpisodes() {
        val progress = listOf(finished(1, 1, show = "a", ago = HOUR), episode(1, 2, show = "b", position = 600.0, ago = HOUR),
            finished(1, 1, show = "c", ago = DAY), episode(1, 2, show = "c", position = 0.0, ago = HOUR),
            movie("m", position = 600.0, ago = HOUR))
        assertEquals(setOf("a"), SmartContinueWatching.showsNeedingEpisodes(progress))
    }

    @Test fun theNextEpisodeRecordDescribesTheCard() {
        var next = ep(2, 4).copy(title = "The Return", durationSeconds = 2700)
        val series = Series(id = "show", sourceId = "src", categoryId = null, name = "The Show", providerId = "1", providerOrder = 0,
            backdropURL = "http://img/backdrop.jpg")
        val record = SmartContinueWatching.nextEpisodeRecord(next, series, finished(2, 3, ago = HOUR))
        assertEquals(next.id, record.mediaId)
        assertEquals(MediaKind.EPISODE, record.kind)
        assertEquals("show", record.seriesId)
        assertEquals("The Show", record.title)
        assertEquals("S2, E4 · The Return", record.subtitle)
        assertEquals("http://img/backdrop.jpg", record.posterURL)
        assertTrue(record.position == 0.0 && record.duration == 2700.0 && !record.completed)
        assertEquals(ago(HOUR), record.updatedAt)
        next = next.copy(imageURL = "http://img/still.jpg")
        assertEquals("http://img/still.jpg", SmartContinueWatching.nextEpisodeRecord(next, series, finished(2, 3, ago = HOUR)).posterURL)
    }
}

class SmartContinueWatchingOrderTest {
    @Test fun nearlyFinishedAndRecentNextEpisodesComeFirst() {
        val progress = listOf(
            movie("fresh", position = 1800.0, ago = HOUR),
            movie("nearly", position = 5600.0, ago = DAY * 3),
            movie("lastBit", position = 6100.0, ago = DAY * 2),
            finished(1, 1, show = "weekly", ago = DAY * 5),
            finished(1, 1, show = "old", ago = DAY * 10),
            movie("middle", position = 3600.0, ago = DAY * 4),
        )
        val episodes = mapOf("weekly" to listOf(ep(1, 1, "weekly"), ep(1, 2, "weekly")), "old" to listOf(ep(1, 1, "old"), ep(1, 2, "old")))
        assertEquals(listOf("resume:lastBit", "resume:nearly", "next:weekly-s1e2", "resume:fresh", "resume:middle", "next:old-s1e2"),
            ids(rank(progress, episodes = episodes)))
    }

    @Test fun shortTimeLeftCountsAsNearlyFinished() {
        val progress = listOf(movie("movie", position = 3600.0, ago = HOUR), episode(1, 1, position = 720.0, ago = DAY, duration = 1320.0))
        assertEquals(listOf("resume:show-s1e1", "resume:movie"), ids(rank(progress)))
    }

    @Test fun nearlyFinishedTitlesStopJumpingTheQueueAfterAMonth() {
        val progress = listOf(movie("stale", position = 6000.0, ago = DAY * 40), movie("fresh", position = 1800.0, ago = DAY * 2))
        assertEquals(listOf("resume:fresh", "resume:stale"), ids(rank(progress)))
    }

    @Test fun titlesStoppedEarlyAndUntouchedForThreeWeeksAreLeftOut() {
        val progress = listOf(
            movie("abandoned", position = 600.0, ago = DAY * 22),
            movie("recentStart", position = 600.0, ago = DAY * 20),
            movie("halfway", position = 3600.0, ago = DAY * 60),
            episode(1, 1, show = "dropped", position = 200.0, ago = DAY * 30),
        )
        assertEquals(listOf("resume:recentStart", "resume:halfway"), ids(rank(progress)))
    }

    @Test fun aResumedNextEpisodeIsJudgedByTheShowsLatestActivity() {
        assertEquals(listOf("resume:show-s1e3"), ids(rank(listOf(episode(1, 3, position = 240.0, ago = DAY * 40), finished(1, 2, ago = DAY)))))
    }

    @Test fun nextEpisodesOfOldShowsStay() {
        assertEquals(listOf("next:show-s1e2"), ids(rank(listOf(finished(1, 1, ago = DAY * 90)))))
    }

    @Test fun oneEntryPerShowAndTheLimitApplies() {
        val progress = (1..30).map { movie("m$it", position = 3000.0, ago = it * HOUR) } +
            listOf(episode(1, 1, position = 600.0, ago = HOUR * 5), episode(1, 2, position = 600.0, ago = HOUR * 1.5))
        assertEquals(listOf("resume:m1", "resume:show-s1e2", "resume:m2", "resume:m3", "resume:m4"), ids(rank(progress, limit = 5)))
    }

    @Test fun finishedMoviesAndUnstartedOnesAreNotListed() {
        val done = movie("done", position = 7200.0, ago = HOUR).copy(completed = true)
        assertTrue(rank(listOf(done, movie("barely", position = 8.0, ago = HOUR))).isEmpty())
        assertFalse(rank(listOf(movie("started", position = 600.0, ago = HOUR))).isEmpty())
    }
}
