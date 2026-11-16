// Ports of the "Catchup URLs", "Identifiers and names" and "HTTP robustness" suites in
// Tests/TunerCoreTests/ParserTests.swift @ 666f598, plus request-flow tests against a mock server.
package app.tuner.core.providers

import app.tuner.core.models.CatchupType
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Series
import app.tuner.core.net.HttpClient
import app.tuner.core.net.HttpException
import app.tuner.core.parsing.CatchupURLBuilder
import app.tuner.core.parsing.ChannelNameNormalizer
import app.tuner.core.parsing.StableID
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import java.time.Instant
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProviderTest {
    private val start = Instant.ofEpochSecond(1_767_268_800) // 2026-01-01 12:00 UTC
    private val end = Instant.ofEpochSecond(1_767_272_400)   // 13:00
    private val now = Instant.ofEpochSecond(1_767_276_000)   // 14:00

    // Catchup URLs

    @Test fun shiftAppendsUTC() {
        assertEquals("http://x/ch.m3u8?token=1&utc=1767268800&lutc=1767276000",
            CatchupURLBuilder.m3u("http://x/ch.m3u8?token=1", CatchupType.SHIFT, null, null, start, end, now))
    }

    @Test fun flussonicRewritesPath() {
        assertEquals("http://f/chan/index-1767268800-3600.m3u8?token=a",
            CatchupURLBuilder.m3u("http://f/chan/index.m3u8?token=a", CatchupType.FLUSSONIC, null, null, start, end, now))
        assertEquals("http://f/chan/timeshift_abs-1767268800.ts",
            CatchupURLBuilder.m3u("http://f/chan/mpegts", CatchupType.FLUSSONIC, null, null, start, end, now))
    }

    @Test fun templateSubstitution() {
        val template = "http://arch/{catchup-id}/{Y}-{m}-{d}/{H}{M}?d={duration:60}&s=\${start}&e={utcend}&o={offset}"
        assertEquals("http://arch/cnn.us/2026-01-01/1200?d=60&s=1767268800&e=1767272400&o=7200",
            CatchupURLBuilder.m3u("http://live/x", CatchupType.DEFAULT, template, "cnn.us", start, end, now))
    }

    @Test fun appendTemplateIsRelative() {
        assertEquals("http://live/x.ts?utc=1767268800&lutc=1767276000",
            CatchupURLBuilder.m3u("http://live/x.ts", CatchupType.APPEND, "?utc={utc}&lutc={lutc}", null, start, end, now))
    }

    @Test fun xtreamTimeshiftUsesServerLocalTime() {
        val urls = XtreamURLs("http://panel:8080/", "u s", "p&w")
        assertEquals("http://panel:8080/timeshift/u%20s/p&w/60/2026-01-01:13-00/42.ts", urls.timeshiftURL("42", start, 60, 3600.0))
    }

    // Identifiers and names

    @Test fun djb2IsDeterministic() {
        assertEquals(StableID.hash("http://example.com/a.ts"), StableID.hash("http://example.com/a.ts"))
        assertNotEquals(StableID.hash("a"), StableID.hash("b"))
        assertTrue(StableID.hash("").length <= 8)
    }

    @Test fun slugKeepsUnicodeLetters() {
        assertEquals("uk-sports-hd", StableID.slug("UK | Sports HD"))
        assertEquals("федеральные", StableID.slug("Федеральные"))
        assertTrue(StableID.slug("!!!").startsWith("category-"))
    }

    @Test fun normalizerStripsNoise() {
        assertEquals(ChannelNameNormalizer.normalize("CNN"), ChannelNameNormalizer.normalize("US| CNN HD"))
        assertEquals(ChannelNameNormalizer.normalize("BBC One"), ChannelNameNormalizer.normalize("[UK] BBC One FHD"))
        assertEquals("skysportsplus", ChannelNameNormalizer.normalize("Sky Sports+ (1080p)"))
        assertTrue(ChannelNameNormalizer.normalize("HD").isNotEmpty())
        assertNotEquals(ChannelNameNormalizer.normalize("HBO West"), ChannelNameNormalizer.normalize("HBO East"))
    }

    @Test fun xtreamCredentialsFromPastedLink() {
        val c = assertNotNull(XtreamURLs.parseCredentials("http://host.tv:8080/get.php?username=bob&password=s3cret&type=m3u_plus"))
        assertEquals(Triple("http://host.tv:8080", "bob", "s3cret"), c)
        assertEquals("a+b", XtreamURLs.parseCredentials("http://h/get.php?username=u&password=a+b")?.third)
    }

    @Test fun stalkerIdentityHashes() {
        val id = StalkerClient.Identity("00:1A:79:00:00:01")
        assertEquals(13, id.sn.length)
        assertEquals(id.sn.uppercase(), id.sn)
        assertEquals(64, id.deviceId.length)
        assertEquals(40, id.hwVersion2.length)
    }

    @Test fun stalkerLocatorRoundTrip() {
        val loc = StalkerLocator.EpisodeCmd("ffrt http://localhost/ch/1", 3)
        assertEquals(loc, StalkerLocator.decode(loc.encoded))
        assertNull(StalkerLocator.decode("http://not"))
        // Swift's encoding (JSONEncoder escapes "/") decodes too.
        val swift = "stalker:" + java.util.Base64.getEncoder().encodeToString("""{"channel":{"cmd":"ffrt http:\/\/localhost\/ch\/9"}}""".toByteArray())
        assertEquals(StalkerLocator.ChannelCmd("ffrt http://localhost/ch/9"), StalkerLocator.decode(swift))
    }

    @Test fun stalkerSanitizesLinks() {
        val c = StalkerClient("http://portal.tv:8080/c/", "00:1A:79:00:00:01")
        assertEquals("http://portal.tv:8080/ch/123?x=1", c.sanitize("ffmpeg http://localhost/ch/123?x=1"))
        assertEquals("http://cdn.tv/live.ts", c.sanitize("ffrt http://cdn.tv/live.ts"))
        assertEquals("http://portal.tv:8080/portal.php", c.candidateEndpoints().first())
        assertEquals("http://portal.tv:8080/play/1.ts", c.sanitize("/play/1.ts"))
        assertEquals("http://portal.tv:8080/x", c.absolute("x"))
    }

    // HTTP robustness

    @Test fun jsonWithPHPWarningPrefixIsRecovered() {
        val body = "<br />\n<b>Warning</b>: Undefined index in /var/www/player_api.php on line 12<br />\n[{\"category_id\":\"1\",\"category_name\":\"Movies\"}]\n"
        val value = HttpClient.parseJSONLeniently(body.toByteArray()) as JsonArray
        assertEquals("Movies", (value.first() as JsonObject)["category_name"]!!.jsonPrimitive.content)
    }

    @Test fun objectWithTrailingJunkIsRecovered() {
        val value = HttpClient.parseJSONLeniently("{\"user_info\":{\"auth\":1}}<!-- served in 0.2s -->".toByteArray()) as JsonObject
        assertNotNull(value["user_info"])
    }

    @Test fun htmlPageIsRejectedWithPreview() {
        val page = "<html><body>Too many requests</body></html>".toByteArray()
        assertNull(HttpClient.parseJSONLeniently(page))
        assertTrue(HttpException.InvalidJSON(HttpClient.preview(page)).message!!.contains("Too many requests"))
    }

    // Request flows against a mock server

    private lateinit var server: MockWebServer
    private val routes = mutableMapOf<String, (RecordedRequest) -> MockResponse>()

    @BeforeTest fun startServer() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val url = request.url
                val key = url.queryParameter("action") ?: url.encodedPath
                return routes[key]?.invoke(request) ?: MockResponse(code = 404)
            }
        }
        server.start()
    }

    @AfterTest fun stopServer() = server.close()

    private fun json(body: String) = MockResponse.Builder().code(200).body(body).build()

    @Test fun xtreamAuthenticateAndCatalog() = runBlocking {
        routes["/player_api.php"] = {
            json("""{"user_info":{"auth":1,"status":"Active","exp_date":"1798761600","active_cons":"0","max_connections":"1","is_trial":"0"},
                "server_info":{"url":"panel.example","port":"8080","server_protocol":"http","time_now":"2026-01-01 14:00:05","timestamp_now":1767268800}}""")
        }
        routes["get_live_streams"] = {
            json("""<b>Notice</b>: x [{"num":1,"name":"News","stream_id":11,"stream_icon":"","epg_channel_id":"news.tuner","category_id":"1","tv_archive":1,"tv_archive_duration":"3"},
                {"num":"2","name":"No id"},{"name":"Kids","stream_id":"14","category_id":3,"tv_archive":0,"is_adult":"1"}]""")
        }
        routes["get_series_info"] = {
            json("""{"info":{"plot":"P","rating":"8.1","backdrop_path":["","http://b/1.jpg"]},
                "episodes":{"2":[{"id":"201","episode_num":"1","title":"Two One","container_extension":"mkv","info":{"duration_secs":"1500"}}],
                            "1":[{"id":"101","episode_num":2},{"id":"100","episode_num":1,"season":1}]}}""")
        }
        val client = XtreamClient(server.url("/").toString(), "u@x", "p/w")
        val account = client.authenticate()
        assertEquals(7200.0, account.serverTimeOffset) // 14:00:05 local vs 12:00 UTC → 2 h
        assertEquals(1, account.maxConnections)
        assertEquals(2, account.epgURLCandidates.size)
        assertTrue(account.epgURLCandidates[1].startsWith("http://panel.example:8080/xmltv.php?username=u@x&password=p%2Fw"))

        val channels = client.liveStreams("src")
        assertEquals(listOf("src_11", "src_14"), channels.map { it.id })
        assertEquals(CatchupType.XTREAM, channels[0].catchupType)
        assertEquals(3, channels[0].catchupDays)
        assertNull(channels[0].logoURL)
        assertTrue(channels[1].isAdult)
        assertEquals("", channels[0].streamURL) // credentials are never stored

        val series = Series(id = "src_series_9", sourceId = "src", categoryId = null, name = "S", providerId = "9", providerOrder = 0)
        val details = client.seriesInfo(series)
        assertEquals(listOf("src_ep_100", "src_ep_101", "src_ep_201"), details.episodes.map { it.id })
        assertEquals(8.1, details.rating)
        assertEquals("http://b/1.jpg", details.backdropURL)
        assertEquals(1500, details.episodes.last().durationSeconds)

        val request = server.takeRequest()
        assertEquals("VLC/3.0.20 LibVLC/3.0.20", request.headers["User-Agent"])
    }

    @Test fun xtreamRejectsBadLogin() = runBlocking {
        routes["/player_api.php"] = { json("""{"user_info":{"auth":0}}""") }
        val e = assertFailsWith<HttpException.AuthFailed> { XtreamClient(server.url("/").toString(), "u", "p").authenticate() }
        assertEquals("Xtream login failed — check username and password", e.message)
        routes["/player_api.php"] = { MockResponse(code = 403) }
        assertFailsWith<HttpException.Status> { XtreamClient(server.url("/").toString(), "u", "p").authenticate() }
        Unit
    }

    @Test fun stalkerHandshakeTokenAndCatalog() = runBlocking {
        val seenAuth = mutableListOf<String?>()
        routes["handshake"] = { json("""{"js":{"token":"T1"}}""") }
        routes["get_profile"] = { json("""{"js":{"token":"T2","id":1}}""") }
        routes["get_genres"] = { r -> seenAuth += r.headers["Authorization"]; json("""{"js":[{"id":"*","title":"All"},{"id":"5","title":"News"}]}""") }
        routes["get_all_channels"] = {
            json("""{"js":{"data":[{"id":"7","name":"Seven","number":"7","cmd":"ffrt http://localhost/ch/7","logo":"/logos/7.png","tv_genre_id":"5","tv_archive":"1","tv_archive_duration":"72"}]}}""")
        }
        routes["get_categories"] = { json("""{"js":[{"id":"12","title":"Films"}]}""") }
        routes["get_ordered_list"] = { r ->
            val page = r.url.queryParameter("p")?.toInt() ?: 1
            json("""{"js":{"total_items":20,"max_page_items":14,"data":[{"id":"m$page","name":"Film $page","cmd":"/media/$page.mpg","time":"90","rating_imdb":"7.5"}]}}""")
        }
        routes["create_link"] = { json("""{"js":{"cmd":"ffmpeg http://localhost:88/stream/7.ts?token=x"}}""") }

        val portal = server.url("/stalker_portal/c/").toString()
        val c = StalkerClient(portal, "00:1a:79:00:00:01")
        val cats = c.liveCategories("s")
        assertEquals(listOf("s_5"), cats.map { it.id })
        assertEquals(listOf<String?>("Bearer T2"), seenAuth) // profile's token replaces the handshake's
        val ch = c.channels("s").single()
        assertEquals(CatchupType.STALKER, ch.catchupType)
        assertEquals(3, ch.catchupDays)
        assertEquals("${server.url("/").toString().trimEnd('/')}/logos/7.png", ch.logoURL)
        assertTrue(ch.streamURL.startsWith("stalker:"))

        assertEquals(listOf("s_vod_12"), c.vodCategories("s", CategoryKind.MOVIE).map { it.id })
        val (movies, _) = c.items("s", CategoryKind.MOVIE, "12")
        assertEquals(listOf("s_vod_m1", "s_vod_m2"), movies.map { it.id }) // two pages, in order
        assertEquals(5400, movies[0].durationSeconds)

        val url = c.resolve(StalkerLocator.decode(ch.streamURL)!!)
        val host = server.url("/").host
        assertEquals("http://$host:88/stream/7.ts?token=x", url)
    }
}
