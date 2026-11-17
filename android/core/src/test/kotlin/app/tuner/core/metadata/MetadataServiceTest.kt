// Port of the "Metadata service" and service-level "TVmaze episode pictures" suites in
// Tests/TunerCoreTests/MetadataTests.swift @ 666f598 (the database is an in-memory MetadataCache until phase 3).
package app.tuner.core.metadata

import app.tuner.core.net.HttpException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val DAY_MS = 86_400_000L
private fun daysAgo(days: Int) = System.currentTimeMillis() - days * DAY_MS

class MetadataServiceTest {
    private val cache = MemoryMetadataCache()

    @Test fun cinemetaMatchIsCachedAndReused() = runBlocking {
        val net = StubNetwork(handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        val md = assertNotNull(service.metadata(movie("m1", "4K-Dune Part Two 2024 HDTC")))
        assertEquals("Cinemeta", md.source)
        assertEquals("tt15239678", md.imdbId)
        assertEquals(2, net.requests.size) // search + meta
        assertEquals(md, service.metadata(movie("m1", "4K-Dune Part Two 2024 HDTC")))
        assertEquals(md, service.cachedMetadata("m1"))
        assertEquals(listOf("m1"), service.cachedMetadata(listOf("m1", "nope")).keys.sorted())
        assertEquals(2, net.requests.size)
    }

    @Test fun concurrentRequestsShareOneLookup() = runBlocking {
        val net = StubNetwork(delayMs = 50, handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        val m = movie("m1", "Dune: Part Two", year = "2024")
        val results = coroutineScope { (0 until 6).map { async { service.metadata(m) } }.awaitAll() }
        assertEquals(6, results.size)
        assertTrue(results.all { it?.imdbId == "tt15239678" })
        assertEquals(2, net.requests.size)
    }

    @Test fun networkLookupsAreLimited() = runBlocking {
        val net = StubNetwork(delayMs = 40, handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        coroutineScope { (0 until 9).map { i -> async { service.metadata(movie("m$i", "Unknown Film Number $i")) } }.awaitAll() }
        assertEquals(9, net.requests.size)
        assertTrue(net.maxInFlight.get() <= MetadataService.MAX_CONCURRENT_LOOKUPS)
    }

    @Test fun nonLatinMissIsCachedWithoutNetwork() = runBlocking {
        val net = StubNetwork(handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        assertNull(service.metadata(movie("ar1", "|AR| فيلم الرسالة")))
        assertTrue(net.requests.isEmpty())
        val entry = assertNotNull(cache.entry("ar1"))
        assertTrue(entry.notFound)
        assertTrue(entry.isFresh())
    }

    @Test fun missIsCachedAsNotFound() = runBlocking {
        val net = StubNetwork(handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        assertNull(service.metadata(movie("x", "Some Unknown Film (2011)")))
        val first = net.requests.size
        assertTrue(first >= 1)
        assertNull(service.metadata(movie("x", "Some Unknown Film (2011)")))
        assertEquals(first, net.requests.size)
        assertEquals(true, cache.entry("x")?.notFound)
    }

    @Test fun disabledServesCacheOnly() = runBlocking {
        val net = StubNetwork(handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        service.configure(MetadataSettings(enabled = false))
        assertNull(service.metadata(movie("m1", "Dune: Part Two (2024)")))
        assertTrue(net.requests.isEmpty())
        cache.save(MediaMetadata(MediaMetadata.Kind.movie, "Cinemeta", "Dune: Part Two", fetchedAt = daysAgo(90), imdbId = "tt15239678"), "m1")
        assertEquals("Dune: Part Two", service.metadata(movie("m1", "Dune: Part Two (2024)"))?.title)
        assertTrue(net.requests.isEmpty())
    }

    @Test fun expiredEntriesAreRefetched() = runBlocking {
        val net = StubNetwork(handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        cache.save(MediaMetadata(MediaMetadata.Kind.movie, "Cinemeta", "Old", fetchedAt = daysAgo(31)), "m1")
        cache.saveNotFound("m2", MediaMetadata.Kind.movie, daysAgo(8))
        cache.saveNotFound("m3", MediaMetadata.Kind.movie, daysAgo(6))
        assertEquals("Dune: Part Two", service.metadata(movie("m1", "Dune Part Two (2024)"))?.title)
        assertEquals("Dune: Part Two", service.metadata(movie("m2", "Dune Part Two (2024)"))?.title)
        val count = net.requests.size
        assertNull(service.metadata(movie("m3", "Dune Part Two (2024)"))) // fresh "not found"
        assertEquals(count, net.requests.size)
    }

    @Test fun refreshMissKeepsEarlierMatch() = runBlocking {
        val net = StubNetwork(handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        cache.save(MediaMetadata(MediaMetadata.Kind.movie, "Cinemeta", "Earlier Match", fetchedAt = daysAgo(40)), "m1")
        assertEquals("Earlier Match", service.metadata(movie("m1", "Nothing Matches This"))?.title)
        val entry = assertNotNull(cache.entry("m1"))
        assertFalse(entry.notFound)
        assertTrue(entry.isFresh())
    }

    @Test fun networkFailureIsNotCached() = runBlocking {
        val net = StubNetwork { throw IOException("offline") }
        val service = MetadataService(cache, net.fetch)
        assertNull(service.metadata(movie("m1", "Dune Part Two (2024)")))
        assertNull(cache.entry("m1"))
        val count = net.requests.size
        assertNull(service.metadata(movie("m1", "Dune Part Two (2024)"))) // backed off: no immediate retry
        assertEquals(count, net.requests.size)
    }

    @Test fun tmdbIsPreferredAndUsesProviderId() = runBlocking {
        val net = StubNetwork { url ->
            when {
                url.contains("api.themoviedb.org/3/movie/693134?") -> metadataJSON("tmdb_movie.json")
                url.contains("api.themoviedb.org/3/search/movie?") -> metadataJSON("tmdb_search_movie.json")
                else -> StubNetwork.cinemeta(url)
            }
        }
        val service = MetadataService(cache, net.fetch)
        service.configure(MetadataSettings(tmdbAPIKey = "0123456789abcdef0123456789abcdef"))
        val direct = assertNotNull(service.metadata(movie("m1", "Whatever Name", tmdbId = "693134")))
        assertEquals("TMDB", direct.source)
        assertEquals(1, net.requests.size)
        assertTrue(net.requests[0].contains("append_to_response=credits,videos,images,external_ids"))
        assertTrue(net.requests[0].contains("include_image_language=en,null"))
        val searched = assertNotNull(service.metadata(movie("m2", "EN - Dune: Part Two (2024)")))
        assertEquals("693134", searched.tmdbId)
        assertTrue(net.requests.any { it.contains("/search/movie?query=Dune:%20Part%20Two&") })
        assertFalse(net.requests.any { it.contains("cinemeta") })
    }

    @Test fun tmdbSeriesFetchesSeasons() = runBlocking {
        val net = StubNetwork { url ->
            when {
                url.contains("/3/search/tv?") -> metadataJSON("tmdb_search_tv.json")
                url.contains("/3/tv/1396/season/0?") -> metadataJSON("tmdb_season_0.json")
                url.contains("/3/tv/1396/season/1?") -> metadataJSON("tmdb_season_1.json")
                url.contains("/3/tv/1396/season/2?") -> metadataJSON("tmdb_season_2.json")
                url.contains("/3/tv/1396?") -> metadataJSON("tmdb_tv.json")
                else -> throw HttpException.Status(404)
            }
        }
        val service = MetadataService(cache, net.fetch)
        service.configure(MetadataSettings(tmdbAPIKey = "eyJhbGciOiJIUzI1NiJ9.e30.sig"))
        val md = assertNotNull(service.metadata(series("s1", "NF: Breaking Bad S01")))
        assertEquals("TMDB", md.source)
        assertEquals(4, md.episodes.size)
        assertTrue(md.episode(1, 2)?.stillURL?.endsWith("/w300/tjDNvbokPLtEnpFyFPyXMOd6Zr1.jpg") == true)
        assertFalse(net.requests.any { it.contains("season/6") })
        assertFalse(net.requests.any { it.contains("api_key") })
    }

    @Test fun rejectedTMDBKeyFallsBackToCinemeta() = runBlocking {
        val net = StubNetwork { url -> if (url.contains("themoviedb")) throw HttpException.Status(401) else StubNetwork.cinemeta(url) }
        val service = MetadataService(cache, net.fetch)
        service.configure(MetadataSettings(tmdbAPIKey = "bad"))
        assertEquals("Cinemeta", service.metadata(movie("m1", "Dune Part Two (2024)"))?.source)
    }

    @Test fun tmdbOutageMakesMissInconclusive() = runBlocking {
        val net = StubNetwork { url -> if (url.contains("themoviedb")) throw HttpException.Status(503) else StubNetwork.cinemeta(url) }
        val service = MetadataService(cache, net.fetch)
        service.configure(MetadataSettings(tmdbAPIKey = "0123456789abcdef0123456789abcdef"))
        assertNull(service.metadata(movie("m1", "Some Unknown Film")))
        assertNull(cache.entry("m1"))
    }

    @Test fun changingTheKeyMarksCacheStale() = runBlocking {
        val net = StubNetwork(handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        service.configure(MetadataSettings())
        service.metadata(movie("m1", "Dune Part Two (2024)"))
        val count = net.requests.size
        service.configure(MetadataSettings()) // unchanged: no invalidation
        service.metadata(movie("m1", "Dune Part Two (2024)"))
        assertEquals(count, net.requests.size)
        service.configure(MetadataSettings(tmdbAPIKey = "0123456789abcdef0123456789abcdef"))
        service.metadata(movie("m1", "Dune Part Two (2024)"))
        assertTrue(net.requests.size > count)
    }

    @Test fun clearCacheRemovesEverything() = runBlocking {
        val net = StubNetwork(handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        service.metadata(movie("m1", "Dune Part Two (2024)"))
        service.metadata(movie("m2", "Nothing Here"))
        service.clearCache()
        assertNull(cache.entry("m1"))
        assertNull(cache.entry("m2"))
    }

    @Test fun seriesFromCinemetaIncludesEpisodes() = runBlocking {
        val net = StubNetwork(handler = StubNetwork::cinemeta)
        val service = MetadataService(cache, net.fetch)
        val officeMeta = assertNotNull(service.metadata(series("s2", "The Office (US) [MULTI-SUB]")))
        assertEquals("tt0386676", officeMeta.imdbId)
        assertEquals("2005–2013", officeMeta.year)
        assertTrue(officeMeta.posterURL!!.endsWith("@._V1_SX780.jpg"))
        val md = assertNotNull(service.metadata(series("s1", "Breaking Bad")))
        assertNotNull(md.episode(1, 2)?.stillURL)
        Unit
    }

    @Test fun metaThatContradictsTheSearchHitIsRejected() = runBlocking {
        val net = StubNetwork { url ->
            when {
                url.contains("/catalog/movie/top/search=") -> json("""{"metas":[{"id":"tt5581256","name":"Inception","type":"movie"}]}""")
                url.endsWith("/meta/movie/tt5581256.json") -> json("""{"meta":{"id":"tt5581256","name":"Untitled Project","releaseInfo":"2017"}}""")
                else -> throw HttpException.Status(404)
            }
        }
        val service = MetadataService(cache, net.fetch)
        assertNull(service.metadata(movie("m1", "Inception")))
        assertEquals(true, cache.entry("m1")?.notFound)
    }

    @Test fun validatesKeys() = runBlocking {
        val net = StubNetwork { url ->
            if (url.contains("api_key=good") || (url.contains("/configuration") && !url.contains("api_key"))) json("""{"images":{}}""")
            else throw HttpException.Status(401)
        }
        val service = MetadataService(cache, net.fetch)
        assertNull(service.validateTMDBKey("good"))
        assertNull(service.validateTMDBKey("eyJ.a.b"))
        assertTrue(service.validateTMDBKey("bad")!!.contains("401"))
        assertNotNull(service.validateTMDBKey("   "))
        Unit
    }

    // TVmaze episode pictures through the service

    private fun tvmazeNetwork(fails: Boolean = false): StubNetwork {
        val episodes = CinemetaClient.map(metadataJSON("cinemeta_meta_series_breaking_bad.json").obj("meta")!!, MediaMetadata.Kind.series)!!.episodes
        val items = episodes.joinToString(",") { """{"season":${it.season},"number":${it.episode},"image":{"original":"https://tvmaze/${it.season}/${it.episode}.jpg"}}""" }
        val show = json("""{"id":169,"_embedded":{"episodes":[$items]}}""")
        return StubNetwork { url ->
            if (url.contains("api.tvmaze.com")) {
                when {
                    fails -> throw HttpException.Status(503)
                    url.contains("/lookup/shows?imdb=tt0903747") -> json("""{"id":169,"name":"Breaking Bad"}""")
                    url.contains("/shows/169?embed=episodes") -> show
                    else -> throw HttpException.Status(404)
                }
            } else {
                StubNetwork.cinemeta(url)
            }
        }
    }

    @Test fun seriesLookupAddsTVmazePicturesAsFallbacks() = runBlocking {
        val service = MetadataService(cache, tvmazeNetwork().fetch)
        val md = assertNotNull(service.metadata(series("s1", "Breaking Bad")))
        val episode = assertNotNull(md.episode(1, 2))
        assertNotNull(episode.stillURL)
        assertEquals("https://tvmaze/1/2.jpg", episode.fallbackStillURL)
        assertEquals(md, service.cachedMetadata("s1"))
    }

    @Test fun tvmazeOutageKeepsTheMatch() = runBlocking {
        val service = MetadataService(cache, tvmazeNetwork(fails = true).fetch)
        val md = assertNotNull(service.metadata(series("s1", "Breaking Bad")))
        assertEquals("tt0903747", md.imdbId)
        assertTrue(md.episodes.all { it.fallbackStillURL == null })
    }

    @Test fun moviesNeverAskTVmaze() = runBlocking {
        val net = tvmazeNetwork()
        MetadataService(cache, net.fetch).metadata(movie("m1", "Dune Part Two (2024)"))
        assertFalse(net.requests.any { it.contains("tvmaze") })
    }
}
