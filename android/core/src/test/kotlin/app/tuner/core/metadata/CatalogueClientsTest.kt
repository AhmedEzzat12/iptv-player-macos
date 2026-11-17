// Port of the "Cinemeta", "TMDB" and pure "TVmaze episode pictures" suites in Tests/TunerCoreTests/MetadataTests.swift @ 666f598
package app.tuner.core.metadata

import app.tuner.core.net.HttpException
import kotlinx.serialization.json.Json
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CinemetaTest {
    @Test fun parsesSearch() {
        val results = CinemetaClient.parseSearch(metadataJSON("cinemeta_search_movie_dune.json"))
        assertTrue(results.size > 5)
        assertEquals("tt15239678", results[0].id)
        assertEquals("Dune: Part Two", results[0].name)
        assertEquals("2024", results[0].releaseInfo)
        val series = CinemetaClient.parseSearch(metadataJSON("cinemeta_search_series_breaking_bad.json"))
        assertEquals("2008-2013", series.first().releaseInfo)
        val query = assertNotNull(TitleMatcher.query("Breaking Bad", kind = MediaMetadata.Kind.series))
        assertEquals(0, CinemetaClient.bestMatch(query, series, MediaMetadata.Kind.series)?.first)
    }

    @Test fun mapsMovieMeta() {
        val md = assertNotNull(CinemetaClient.map(metadataJSON("cinemeta_meta_movie_dune.json").obj("meta")!!, MediaMetadata.Kind.movie))
        assertEquals("Cinemeta", md.source)
        assertEquals("Dune: Part Two", md.title)
        assertEquals("tt15239678", md.imdbId)
        assertEquals("693134", md.tmdbId)
        assertEquals("2024", md.year)
        assertEquals("2024-03-01", md.releaseDate)
        assertEquals(167, md.runtimeMinutes)
        assertEquals(8.4, md.rating)
        assertEquals(listOf("Action", "Adventure", "Drama"), md.genres)
        assertEquals(listOf("Timothée Chalamet", "Zendaya", "Rebecca Ferguson"), md.cast.map { it.name })
        assertTrue(md.cast.all { it.photoURL == null })
        assertEquals(listOf("Denis Villeneuve"), md.directors)
        assertEquals(3, md.writers.size)
        assertEquals("U2Qp5pL3ovA", md.trailerYouTubeId)
        assertEquals("https://images.metahub.space/poster/large/tt15239678/img", md.posterURL)
        assertEquals("https://images.metahub.space/background/medium/tt15239678/img", md.backdropURL)
        assertEquals("https://images.metahub.space/logo/medium/tt15239678/img", md.logoURL)
        assertTrue(md.country!!.startsWith("United States"))
        assertFalse(md.overview.isNullOrEmpty())
        assertTrue(md.episodes.isEmpty())
    }

    @Test fun mapsSeriesMetaWithEpisodes() {
        val md = assertNotNull(CinemetaClient.map(metadataJSON("cinemeta_meta_series_breaking_bad.json").obj("meta")!!, MediaMetadata.Kind.series))
        assertEquals("Breaking Bad", md.title)
        assertEquals("2008–2013", md.year)
        assertTrue(md.directors.isEmpty())
        assertEquals(listOf("Vince Gilligan"), md.writers)
        assertEquals(49, md.runtimeMinutes)
        assertEquals(67, md.episodes.size)
        val ep = assertNotNull(md.episode(1, 2))
        assertEquals("Cat's in the Bag...", ep.title)
        assertEquals("https://episodes.metahub.space/tt0903747/1/2/w780.jpg", ep.stillURL)
        assertEquals("2008-01-28", ep.airDate)
        assertEquals(7.6, ep.rating)
        assertFalse(ep.overview.isNullOrEmpty())
        assertEquals(0, md.episodes.first().season) // specials sort first
    }

    @Test fun lenientFieldShapes() {
        val meta = json("""{"name":"Odd","releaseInfo":2001,"runtime":"1h 45min","imdbRating":7,"genre":"Drama, Crime",
            "director":"Someone","cast":[{"name":"A"},"B"],"trailerStreams":[{"ytId":"yt1"}],
            "videos":[{"season":"1","number":"3","title":"Third","released":"2001-01-01T00:00:00Z"}]}""")
        val md = assertNotNull(CinemetaClient.map(meta, MediaMetadata.Kind.series))
        assertEquals("2001", md.year)
        assertEquals(105, md.runtimeMinutes)
        assertEquals(7.0, md.rating)
        assertEquals(listOf("Drama", "Crime"), md.genres)
        assertEquals(listOf("Someone"), md.directors)
        assertEquals(listOf("A", "B"), md.cast.map { it.name })
        assertEquals("yt1", md.trailerYouTubeId)
        assertEquals("Third", md.episode(1, 3)?.title)
        assertEquals("2001-01-01", md.episode(1, 3)?.airDate)
    }

    @Test fun nonLatinTitlesAreNotSearched() {
        assertTrue(CinemetaClient.isSearchable("The Matrix"))
        assertTrue(CinemetaClient.isSearchable("1917"))
        assertTrue(CinemetaClient.isSearchable("Amélie"))
        assertFalse(CinemetaClient.isSearchable("الرسالة"))
        assertFalse(CinemetaClient.isSearchable("Брат"))
    }
}

class TMDBTest {
    private val noFetch: MetadataFetch = { _, _ -> throw HttpException.EmptyBody() }

    @Test fun credentials() {
        assertEquals(TMDBClient.Credential.ApiKey("0123456789abcdef0123456789abcdef"), TMDBClient.credential("0123456789abcdef0123456789abcdef"))
        assertEquals(TMDBClient.Credential.Bearer("eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIxMjMifQ.sig"),
            TMDBClient.credential(" eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIxMjMifQ.sig \n"))
        assertNull(TMDBClient.credential("  "))
        assertNull(TMDBClient.credential(null))
    }

    @Test fun requestsCarryTheCredential() {
        val v3 = assertNotNull(TMDBClient.create("0123456789abcdef0123456789abcdef", "en-US", noFetch))
        assertEquals("https://api.themoviedb.org/3/search/movie?query=Fast%20%26%20Furious&language=en-US&api_key=0123456789abcdef0123456789abcdef",
            v3.url("/search/movie", listOf("query" to "Fast & Furious", "language" to "en-US")))
        assertTrue(v3.headers.isEmpty())
        val v4 = assertNotNull(TMDBClient.create("eyJtoken.part.sig", "ar_SA", noFetch))
        assertEquals("Bearer eyJtoken.part.sig", v4.headers["Authorization"])
        assertFalse(v4.url("/configuration", emptyList()).contains("api_key"))
        assertEquals("ar-SA", v4.language)
    }

    @Test fun normalizesLanguages() {
        assertEquals("en-US", TMDBClient.normalizedLanguage("en-US"))
        assertEquals("fr", TMDBClient.normalizedLanguage("fr"))
        assertEquals("zh-CN", TMDBClient.normalizedLanguage("zh-Hans-CN"))
        assertEquals("en-US", TMDBClient.normalizedLanguage(""))
    }

    @Test fun mapsMovieDetails() {
        val md = assertNotNull(TMDBClient.mapMovie(metadataJSON("tmdb_movie.json"), "en-US"))
        assertEquals("TMDB", md.source)
        assertEquals("Dune: Part Two", md.title)
        assertNull(md.originalTitle)
        assertEquals("693134", md.tmdbId)
        assertEquals("tt15239678", md.imdbId)
        assertEquals("2024", md.year)
        assertEquals("2024-02-27", md.releaseDate)
        assertEquals(167, md.runtimeMinutes)
        assertEquals(8.2, md.rating)
        assertEquals(listOf("Science Fiction", "Adventure"), md.genres)
        assertEquals("United States", md.country)
        assertTrue(md.overview!!.startsWith("Follow the mythic journey")) // empty overview → US English translation
        assertEquals("Long live the fighters.", md.tagline)
        assertEquals("https://image.tmdb.org/t/p/w500/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg", md.posterURL)
        assertEquals("https://image.tmdb.org/t/p/w1280/xOMo8BRK7PfcJv9JCnx7s5hj0PX.jpg", md.backdropURL)
        assertEquals("https://image.tmdb.org/t/p/w500/logo-en.png", md.logoURL)
        assertEquals(listOf("Timothée Chalamet", "Zendaya", "Rebecca Ferguson"), md.cast.map { it.name })
        assertEquals("Paul Atreides", md.cast[0].character)
        assertEquals("https://image.tmdb.org/t/p/w185/BE2sdjpgsa2rNTFa66f7upkaOP.jpg", md.cast[0].photoURL)
        assertNull(md.cast[2].photoURL)
        assertEquals(listOf("Denis Villeneuve"), md.directors)
        assertEquals(listOf("Denis Villeneuve", "Jon Spaihts", "Frank Herbert"), md.writers)
        assertEquals("U2Qp5pL3ovA", md.trailerYouTubeId)
    }

    @Test fun prefersUILanguageArtworkAndTrailer() {
        val md = assertNotNull(TMDBClient.mapMovie(metadataJSON("tmdb_movie.json"), "ar-SA"))
        assertEquals("https://image.tmdb.org/t/p/w500/logo-ar.png", md.logoURL)
        assertEquals("arTrailer1", md.trailerYouTubeId)
        assertEquals(Locale.Builder().setRegion("US").build().getDisplayCountry(Locale.forLanguageTag("ar-SA")), md.country)
    }

    @Test fun logoFallbacks() {
        val svgOnly = json("""{"id":1,"title":"X","images":{"logos":[{"file_path":"/only.svg","iso_639_1":"en","vote_average":5},
            {"file_path":"/other.png","iso_639_1":"ko","vote_average":9}]}}""")
        assertEquals("https://image.tmdb.org/t/p/w500/only.png", TMDBClient.mapMovie(svgOnly, "en-US")?.logoURL)
        val foreignOnly = json("""{"id":1,"title":"X","images":{"logos":[{"file_path":"/other.png","iso_639_1":"ko","vote_average":9}]}}""")
        assertNull(TMDBClient.mapMovie(foreignOnly, "en-US")?.logoURL)
    }

    @Test fun mapsSeriesWithSeasons() {
        val tv = metadataJSON("tmdb_tv.json")
        assertEquals(listOf(1, 2, 0), TMDBClient.seasonNumbers(tv))
        val seasons = listOf("tmdb_season_1.json", "tmdb_season_2.json", "tmdb_season_0.json").map { metadataJSON(it) }
        val md = assertNotNull(TMDBClient.mapSeries(tv, seasons, "en-US"))
        assertEquals(MediaMetadata.Kind.series, md.kind)
        assertEquals("Breaking Bad", md.title)
        assertEquals("1396", md.tmdbId)
        assertEquals("tt0903747", md.imdbId)
        assertEquals("2008–2013", md.year)
        assertEquals(56, md.runtimeMinutes)
        assertEquals(listOf("Vince Gilligan"), md.writers)
        assertTrue(md.directors.isEmpty())
        assertEquals("Walter White", md.cast.first().character)
        assertEquals("https://image.tmdb.org/t/p/w500/bb-logo.png", md.logoURL)
        assertEquals("HhesaQXLuRY", md.trailerYouTubeId)
        assertEquals(listOf("0x1", "1x1", "1x2", "2x1"), md.episodes.map { "${it.season}x${it.episode}" })
        val ep = assertNotNull(md.episode(1, 2))
        assertEquals("Cat's in the Bag...", ep.title)
        assertEquals("https://image.tmdb.org/t/p/w300/tjDNvbokPLtEnpFyFPyXMOd6Zr1.jpg", ep.stillURL)
        assertEquals("2008-01-27", ep.airDate)
        assertEquals(8.0, ep.rating)
        val unrated = assertNotNull(md.episode(2, 1))
        assertNull(unrated.rating)
        assertNull(unrated.stillURL)
    }

    @Test fun searchMatchingUsesOriginalTitles() {
        val results = TMDBClient.parseSearch(metadataJSON("tmdb_search_movie.json"), MediaMetadata.Kind.movie)
        assertEquals(listOf("693134", "1170608", "438631"), results.map { it.id })
        val query = assertNotNull(TitleMatcher.query("4K-Dune Part Two 2024 HDTC", kind = MediaMetadata.Kind.movie))
        assertEquals(0, TMDBClient.bestMatch(query, results, MediaMetadata.Kind.movie)?.first)
        val dune = assertNotNull(TitleMatcher.query("Dune (2021)", kind = MediaMetadata.Kind.movie))
        assertEquals(2, TMDBClient.bestMatch(dune, results, MediaMetadata.Kind.movie)?.first)
    }

    @Test fun scriptLanguages() {
        assertEquals("ar-SA", TMDBClient.scriptLanguage("الرسالة"))
        assertEquals("ru-RU", TMDBClient.scriptLanguage("Брат"))
        assertNull(TMDBClient.scriptLanguage("The Matrix"))
    }
}

class TVmazePicturesTest {
    private fun show(episodes: List<Triple<Int, Int?, String?>>): app.tuner.core.net.LenientObject {
        val items = episodes.joinToString(",") { (season, number, image) ->
            buildString {
                append("""{"season":$season,"type":"regular"""")
                if (number != null) append(""","number":$number""")
                if (image != null) append(""","image":{"medium":"$image-small","original":"$image"}""")
                append("}")
            }
        }
        return json("""{"id":48450,"name":"Jujutsu Kaisen","_embedded":{"episodes":[$items]}}""")
    }

    private fun tv(season: Int, episode: Int, url: String?) = TVmazeClient.Episode(season, episode, url)

    @Test fun parsesPicturesBySeasonAndEpisode() {
        val parsed = TVmazeClient.parseEpisodes(show(listOf(Triple(1, 1, "a"), Triple(1, 2, null), Triple(2, 1, "b"), Triple(0, null, "special"))))
        assertEquals(3, parsed.size)
        assertEquals("b", parsed.first { it.season == 2 && it.episode == 1 }.imageURL)
        assertNull(parsed.first { it.season == 1 && it.episode == 2 }.imageURL)
    }

    @Test fun addsFallbacksWithoutReplacingWorkingStills() {
        val episodes = listOf(
            EpisodeMetadata(1, 1, stillURL = "cine/1/1"), EpisodeMetadata(1, 2, stillURL = "cine/1/2"),
            EpisodeMetadata(2, 1, stillURL = "cine/2/1"), EpisodeMetadata(2, 2),
        )
        val merged = TVmazeClient.addFallbackStills(episodes, listOf(tv(1, 1, "tv/1/1"), tv(1, 2, null), tv(2, 1, "tv/2/1"), tv(2, 2, "tv/2/2")))
        assertEquals("cine/1/1", merged[0].stillURL)
        assertEquals("tv/1/1", merged[0].fallbackStillURL)
        assertNull(merged[1].fallbackStillURL)
        assertEquals("tv/2/1", merged[2].fallbackStillURL)
        assertEquals("tv/2/2", merged[3].stillURL)
        assertNull(merged[3].fallbackStillURL)
    }

    @Test fun skipsSeasonsNumberedDifferently() {
        val episodes = listOf(EpisodeMetadata(1, 1, stillURL = "cine/1/1"), EpisodeMetadata(1, 2))
        assertEquals(episodes, TVmazeClient.addFallbackStills(episodes, listOf(tv(1, 1, "tv/1/1"), tv(1, 2, "tv/1/2"), tv(1, 3, "tv/1/3"))))
    }

    @Test fun episodesCachedBeforeFallbacksStillDecode() {
        val episode = Json.decodeFromString(EpisodeMetadata.serializer(), """{"season":2,"episode":1,"title":"Hidden Inventory","stillURL":"x"}""")
        assertEquals("x", episode.stillURL)
        assertNull(episode.fallbackStillURL)
    }
}
