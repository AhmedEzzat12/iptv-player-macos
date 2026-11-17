// Port of the "Skip intro: databases" and "service and cache" suites in Tests/TunerCoreTests/SkipSegmentsTests.swift
// @ 666f598 (learned spans are not in v1; the cache is in memory until phase 3).
package app.tuner.core.skip

import app.tuner.core.metadata.StubNetwork
import app.tuner.core.metadata.json
import app.tuner.core.net.HttpException
import kotlinx.coroutines.runBlocking
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private class MemorySkipCache : SkipSegmentCache {
    val rows = HashMap<String, SkipSegmentCacheEntry>()
    override suspend fun entry(mediaId: String) = rows[mediaId]
    override suspend fun save(segments: List<SkipSegment>, mediaId: String, at: Long) {
        rows[mediaId] = SkipSegmentCacheEntry(segments, at)
    }
}

class SkipDatabaseParsingTest {
    @Test fun parsesTheIntroDB() {
        val response = json("""{"tvdb_id":79168,"type":"tv","season":1,"episode":1,"intro":[{"start_ms":null,"end_ms":46000}],"credits":[{"start_ms":1359000,"end_ms":null}]}""")
        assertEquals(listOf(
            SkipSegment(SkipSegment.Kind.INTRO, 0.0, 46.0, SkipSegment.Source.THE_INTRO_DB),
            SkipSegment(SkipSegment.Kind.CREDITS, 1359.0, null, SkipSegment.Source.THE_INTRO_DB),
        ), SkipSegmentService.parseTheIntroDB(response))
    }

    @Test fun parsesIntroDB() {
        val response = json("""{"imdb_id":"tt0944947","media_type":"tv","is_movie":false,"season":1,"episode":1,"intro":{"start_sec":437,"end_sec":531,"start_ms":437000,"end_ms":531000,"confidence":1},"recap":null,"outro":{"start_sec":3631.5,"end_sec":3699.5,"start_ms":3631500,"end_ms":3699500,"confidence":1},"post_credits":null,"no_intro":false}""")
        assertEquals(listOf(
            SkipSegment(SkipSegment.Kind.INTRO, 437.0, 531.0, SkipSegment.Source.INTRO_DB),
            SkipSegment(SkipSegment.Kind.CREDITS, 3631.5, 3699.5, SkipSegment.Source.INTRO_DB),
        ), SkipSegmentService.parseIntroDB(response))
        assertTrue(SkipSegmentService.parseIntroDB(json("""{"intro":null,"recap":null,"outro":null}""")).isEmpty())
    }

    @Test fun requestURLs() {
        val episode = SkipSegmentService.Lookup("src_e1", "tt0944947", "1399", 1, 2)
        assertEquals("https://api.theintrodb.org/v4/media?imdb_id=tt0944947&season=1&episode=2", SkipSegmentService.theIntroDBURL(episode))
        assertEquals("https://api.introdb.app/segments?imdb_id=tt0944947&season=1&episode=2", SkipSegmentService.introDBURL(episode))
        val movie = SkipSegmentService.Lookup("src_m1", null, "27205")
        assertEquals("https://api.theintrodb.org/v4/media?tmdb_id=27205", SkipSegmentService.theIntroDBURL(movie))
        assertNull(SkipSegmentService.introDBURL(movie))
        val imdbMovie = SkipSegmentService.Lookup("src_m2", "TT1375666", null)
        assertEquals("https://api.introdb.app/segments?imdb_id=tt1375666&is_movie=true", SkipSegmentService.introDBURL(imdbMovie))
        assertFalse(SkipSegmentService.Lookup("x", "nm123", "0").canLookUp)
    }
}

class SkipSegmentServiceTest {
    private val cache = MemorySkipCache()
    private val lookup = SkipSegmentService.Lookup("src_e1", "tt0108778", null, 1, 1)
    private val theIntroDB = """{"tvdb_id":79168,"type":"tv","season":1,"episode":1,"intro":[{"start_ms":null,"end_ms":46000}]}"""
    private val introDB = """{"intro":{"start_ms":0,"end_ms":47000},"recap":null,"outro":{"start_ms":1360000,"end_ms":1366000}}"""

    private fun network(theIntroDB: String?, introDB: String?, failing: Boolean = false) = StubNetwork { url ->
        if (failing) throw IOException("offline")
        val body = (if (url.contains("theintrodb")) theIntroDB else introDB) ?: throw HttpException.Status(404)
        json(body)
    }

    @Test fun fetchesBothDatabasesAndCaches() = runBlocking {
        val net = network(theIntroDB, introDB)
        val service = SkipSegmentService(cache, net.fetch)
        val segments = service.segments(lookup, allowNetwork = true)
        assertEquals(3, segments.size)
        assertEquals(setOf(SkipSegment.Source.THE_INTRO_DB, SkipSegment.Source.INTRO_DB), segments.map { it.source }.toSet())
        assertEquals(2, net.requests.size)
        service.segments(lookup, allowNetwork = true) // second play: from the cache
        assertEquals(2, net.requests.size)
        // Merged for a 23-minute file: TheIntroDB's intro, IntroDB's credits.
        assertEquals(listOf(
            SkipSegment(SkipSegment.Kind.INTRO, 0.0, 46.0, SkipSegment.Source.THE_INTRO_DB),
            SkipSegment(SkipSegment.Kind.CREDITS, 1360.0, 1366.0, SkipSegment.Source.INTRO_DB),
        ), SkipSegments.merge(segments, 1380.0))
    }

    @Test fun notFoundIsCachedForAWeek() = runBlocking {
        var now = 1_800_000_000_000L
        val net = network(null, """{"intro":null,"recap":null,"outro":null}""")
        val service = SkipSegmentService(cache, net.fetch) { now }
        assertTrue(service.segments(lookup, allowNetwork = true).isEmpty())
        now += 6 * 86_400_000L
        service.segments(lookup, allowNetwork = true)
        assertEquals(2, net.requests.size)
        now += 2 * 86_400_000L
        service.segments(lookup, allowNetwork = true)
        assertEquals(4, net.requests.size)
    }

    @Test fun failuresAreNotCachedAndOfflineUsesTheCache() = runBlocking {
        val failing = network(null, null, failing = true)
        val service = SkipSegmentService(cache, failing.fetch)
        assertTrue(service.segments(lookup, allowNetwork = true).isEmpty())
        assertNull(cache.entry(lookup.mediaId))
        cache.save(listOf(SkipSegment(SkipSegment.Kind.INTRO, 0.0, 46.0, SkipSegment.Source.THE_INTRO_DB)), lookup.mediaId, 0)
        // Offline (or lookups off): the stale cache, no request.
        assertEquals(1, service.segments(lookup, allowNetwork = false).size)
        assertEquals(2, failing.requests.size)
    }

    @Test fun noIdsMeansNoRequest() = runBlocking {
        val net = network(theIntroDB, introDB)
        val service = SkipSegmentService(cache, net.fetch)
        assertTrue(service.segments(SkipSegmentService.Lookup("src_e2", null, null, 1, 2), allowNetwork = true).isEmpty())
        assertTrue(net.requests.isEmpty())
    }
}
