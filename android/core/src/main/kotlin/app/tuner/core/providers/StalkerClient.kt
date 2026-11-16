// Port of Sources/TunerCore/Providers/StalkerClient.swift @ 666f598
package app.tuner.core.providers

import app.tuner.core.models.CatchupType
import app.tuner.core.models.Category
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Channel
import app.tuner.core.models.Episode
import app.tuner.core.models.Movie
import app.tuner.core.models.Series
import app.tuner.core.models.Source
import app.tuner.core.models.toIntStrict
import app.tuner.core.net.HttpClient
import app.tuner.core.net.HttpException
import app.tuner.core.net.LenientJson
import app.tuner.core.net.LenientObject
import app.tuner.core.net.toSwiftDouble
import app.tuner.core.net.urlQueryEncoded
import app.tuner.core.nilIfEmpty
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Base64
import java.util.Locale
import java.util.TimeZone

/**
 * Opaque playback locator for Stalker items, resolved through `create_link` at play time (portal links are tokenised and
 * expire, so they're never stored). Encoded as `stalker:` + base64 of `{"channel":{"cmd":…}}`-style JSON, the shape
 * Swift's synthesized Codable uses.
 */
public sealed class StalkerLocator {
    public data class ChannelCmd(val cmd: String) : StalkerLocator()
    public data class Vod(val cmd: String) : StalkerLocator()
    public data class EpisodeCmd(val cmd: String, val series: Int?) : StalkerLocator()

    public val encoded: String
        get() {
            val json = when (this) {
                is ChannelCmd -> buildJsonObject { put("channel", buildJsonObject { put("cmd", cmd) }) }
                is Vod -> buildJsonObject { put("vod", buildJsonObject { put("cmd", cmd) }) }
                is EpisodeCmd -> buildJsonObject {
                    put("episode", buildJsonObject { put("cmd", cmd); if (series != null) put("series", series) })
                }
            }
            return PREFIX + Base64.getEncoder().encodeToString(json.toString().toByteArray())
        }

    public companion object {
        private const val PREFIX = "stalker:"

        public fun decode(string: String): StalkerLocator? {
            if (!string.startsWith(PREFIX)) return null
            return runCatching {
                val obj = Json.parseToJsonElement(String(Base64.getDecoder().decode(string.removePrefix(PREFIX)))).jsonObject
                val (kind, body) = obj.entries.single()
                val fields = body.jsonObject
                val cmd = fields["cmd"]!!.jsonPrimitive.content
                when (kind) {
                    "channel" -> ChannelCmd(cmd)
                    "vod" -> Vod(cmd)
                    "episode" -> EpisodeCmd(cmd, fields["series"]?.jsonPrimitive?.intOrNull)
                    else -> null
                }
            }.getOrNull()
        }
    }
}

public data class StalkerEPGEntry(val channelId: String, val start: Instant, val stop: Instant, val title: String, val desc: String?)

/** Client for Stalker/Ministra middleware portals (MAG set-top-box emulation). */
public class StalkerClient(portalURL: String, mac: String) {
    public val portalURL: String = portalURL.trim().let { if (it.lowercase().startsWith("http")) it else "http://$it" }
    public val mac: String = mac.trim(' ', '\t').uppercase()
    private val http = HttpClient(MAG_USER_AGENT, timeoutSeconds = 60)
    internal val identity = Identity(this.mac)

    private val tokenLock = Mutex()
    @Volatile private var endpoint: String? = null
    @Volatile private var token: String? = null
    @Volatile private var tokenIssuedAt: Instant? = null

    public constructor(source: Source) : this(source.url, source.mac ?: "")

    internal class Identity(mac: String) {
        val sn: String
        val deviceId: String
        val signature: String
        val hwVersion2: String

        init {
            fun hex(algorithm: String, s: String) =
                MessageDigest.getInstance(algorithm).digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
            sn = hex("MD5", mac).take(13).uppercase()
            deviceId = hex("SHA-256", mac).uppercase()
            signature = hex("SHA-256", mac + sn + deviceId + deviceId).uppercase()
            hwVersion2 = hex("SHA-1", mac)
        }
    }

    // Endpoint discovery

    internal fun candidateEndpoints(): List<String> {
        val parts = Origin.parse(portalURL) ?: return listOf(portalURL)
        val origin = parts.origin
        val path = parts.path.trimEnd('/')
        val list = mutableListOf<String>()
        when {
            path.endsWith(".php") -> list.add(origin + path)
            path.endsWith("/c") -> {
                val prefix = path.dropLast(2)
                list.add("$origin$prefix/portal.php")
                list.add("$origin$prefix/server/load.php")
            }
            path.contains("stalker_portal") -> list.add(origin + path.substringBefore("stalker_portal") + "stalker_portal/server/load.php")
            path.isNotEmpty() -> {
                list.add("$origin$path/portal.php")
                list.add("$origin$path/server/load.php")
            }
        }
        for (fallback in listOf("/stalker_portal/server/load.php", "/portal.php", "/c/portal.php")) {
            if (origin + fallback !in list) list.add(origin + fallback)
        }
        return list
    }

    internal fun headers(endpoint: String, includeToken: Boolean = true): Map<String, String> {
        val origin = Origin.parse(endpoint)?.origin ?: portalURL
        var cookie = "mac=${mac.urlQueryEncoded}; stb_lang=en; timezone=${TimeZone.getDefault().id.urlQueryEncoded}"
        val h = linkedMapOf(
            "Referer" to "$origin/stalker_portal/c/index.html",
            "Accept-Language" to "en-US,en;q=0.5",
            "Pragma" to "no-cache",
            "X-User-Agent" to "Model: MAG250; Link: WiFi",
        )
        val t = token
        if (includeToken && t != null) {
            h["Authorization"] = "Bearer $t"
            cookie += "; token=$t"
        }
        h["Cookie"] = cookie
        return h
    }

    internal fun url(endpoint: String, type: String, action: String, params: Map<String, String>): String {
        val s = StringBuilder("$endpoint?type=$type&action=$action&JsHttpRequest=1-xml")
        for ((k, v) in params.toSortedMap()) s.append('&').append(k).append('=').append(v.urlQueryEncoded)
        return s.toString()
    }

    // Requests

    /** Performs a portal call and returns the unwrapped `js` payload. Re-authenticates once on 401/403 or bad JSON. */
    internal suspend fun call(type: String, action: String, params: Map<String, String> = emptyMap(), authenticated: Boolean = true): JsonElement {
        if (authenticated) ensureToken()
        val ep = endpoint ?: throw HttpException.AuthFailed("Portal not reachable")
        return try {
            raw(ep, type, action, params, includeToken = authenticated)
        } catch (e: HttpException) {
            val retry = authenticated && ((e is HttpException.Status && (e.code == 401 || e.code == 403)) || e is HttpException.InvalidJSON)
            if (!retry) throw e
            invalidateToken()
            ensureToken()
            raw(ep, type, action, params, includeToken = true)
        }
    }

    internal suspend fun raw(endpoint: String, type: String, action: String, params: Map<String, String>, includeToken: Boolean): JsonElement {
        val json = http.json(url(endpoint, type, action, params), headers(endpoint, includeToken))
        if (json is JsonObject) {
            json["js"]?.let { return it }
            json["data"]?.let { return it }
        }
        return json
    }

    private fun invalidateToken() {
        token = null
        tokenIssuedAt = null
    }

    private suspend fun ensureToken() = tokenLock.withLock {
        val issued = tokenIssuedAt
        if (token != null && issued != null && Instant.now().epochSecond - issued.epochSecond < 3600) return@withLock
        authenticate()
    }

    private suspend fun authenticate() {
        var lastError: Exception = HttpException.AuthFailed("Portal handshake failed")
        val candidates = endpoint?.let { listOf(it) } ?: candidateEndpoints()
        for (candidate in candidates) {
            try {
                val js = raw(candidate, "stb", "handshake", mapOf("token" to "", "prehash" to "0"), includeToken = false)
                val t = LenientObject.of(js)?.string("token") ?: throw HttpException.AuthFailed("Portal returned no token")
                endpoint = candidate
                token = t
                tokenIssuedAt = Instant.now()
                runCatching { profile() }
                return
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                lastError = e
            }
        }
        throw lastError
    }

    private suspend fun profile() {
        val ep = endpoint ?: return
        val metrics = """{"mac":"$mac","sn":"${identity.sn}","type":"STB","model":"MAG250","uid":"","random":"${randomHex(20)}"}"""
        val params = mapOf(
            "hd" to "1", "ver" to FIRMWARE_VERSION, "num_banks" to "2", "sn" to identity.sn, "stb_type" to "MAG250",
            "client_type" to "STB", "image_version" to "218", "video_out" to "hdmi", "device_id" to identity.deviceId,
            "device_id2" to identity.deviceId, "signature" to identity.signature, "auth_second_step" to "1",
            "hw_version" to "1.7-BD-00", "not_valid_token" to "0", "metrics" to metrics, "hw_version_2" to identity.hwVersion2,
            "timestamp" to Instant.now().epochSecond.toString(), "api_signature" to "262", "prehash" to "",
        )
        val js = raw(ep, "stb", "get_profile", params, includeToken = true)
        LenientObject.of(js)?.string("token")?.let { token = it }
    }

    // Account

    public suspend fun expiryDate(): Instant? {
        val obj = runCatching { LenientObject.of(call("account_info", "get_main_info")) }.getOrNull() ?: return null
        // Portals put the expiry in odd fields; "phone" is the most common.
        for (key in listOf("phone", "end_date", "expire_billing_date", "tariff_expired_date")) {
            val s = obj.string(key) ?: continue
            parseLooseDate(s)?.let { return it }
        }
        return null
    }

    // Live

    public suspend fun liveCategories(sourceId: String): List<Category> =
        LenientJson.objects(call("itv", "get_genres", mapOf("include_censored" to "1", "censored" to "1"))).mapIndexedNotNull { index, g ->
            val id = g.string("id")?.takeIf { it != "*" } ?: return@mapIndexedNotNull null
            Category("${sourceId}_$id", sourceId, CategoryKind.LIVE, g.string("title") ?: "Genre $id", index)
        }

    public suspend fun channels(sourceId: String): List<Channel> {
        val js = call("itv", "get_all_channels", mapOf("include_censored" to "1", "censored" to "1"))
        return LenientJson.objects(LenientObject.of(js)?.get("data") ?: js).mapIndexedNotNull { index, c -> channel(sourceId, index, c) }
    }

    internal fun channel(sourceId: String, index: Int, c: LenientObject): Channel? {
        val id = c.string("id") ?: return null
        val cmd = c.string("cmd") ?: ""
        val archive = c.bool("tv_archive") || (c.int("tv_archive_duration") ?: 0) > 0
        val genre = c.string("tv_genre_id") ?: c.string("genre_id")
        return Channel(
            id = "${sourceId}_$id",
            sourceId = sourceId,
            categoryId = genre?.let { "${sourceId}_$it" },
            name = c.string("name") ?: "Channel $id",
            number = c.int("number"),
            providerOrder = index,
            logoURL = absolute(c.string("logo")),
            tvgId = c.string("xmltv_id"),
            streamURL = StalkerLocator.ChannelCmd(cmd).encoded,
            providerStreamId = id,
            catchupType = if (archive) CatchupType.STALKER else null,
            catchupDays = if (archive) maxOf(1, (c.int("tv_archive_duration") ?: 168) / 24) else null,
            isAdult = c.bool("censored") || c.bool("lock"),
        )
    }

    // VOD

    public suspend fun vodCategories(sourceId: String, kind: CategoryKind): List<Category> {
        val type = if (kind == CategoryKind.SERIES) "series" else "vod"
        return LenientJson.objects(call(type, "get_categories", mapOf("sortby" to "number"))).mapIndexedNotNull { index, c ->
            val id = c.string("id")?.takeIf { it != "*" } ?: return@mapIndexedNotNull null
            Category("${sourceId}_${type}_$id", sourceId, kind, c.string("title") ?: "Category $id", index)
        }
    }

    /** Loads every page of a VOD/series category (portals page 14 items at a time), four pages at a time. */
    public suspend fun items(sourceId: String, kind: CategoryKind, categoryRawId: String, maxPages: Int = 200): Pair<List<Movie>, List<Series>> {
        val type = if (kind == CategoryKind.SERIES) "series" else "vod"
        val params = buildMap {
            put("category", categoryRawId); put("sortby", "added"); put("include_censored", "1"); put("censored", "1")
            if (kind == CategoryKind.SERIES) { put("movie_id", "0"); put("season_id", "0"); put("episode_id", "0") }
        }
        val first = page(type, params, 1)
        val all = first.items.toMutableList()
        val pages = minOf(maxPages, kotlin.math.ceil(first.total.toDouble() / first.perPage).toInt())
        if (pages > 1) {
            val gate = Semaphore(4)
            val rest = coroutineScope {
                (2..pages).map { n -> async { gate.withPermit { page(type, params, n).items } } }.awaitAll()
            }
            rest.forEach { all += it }
        }
        val movies = mutableListOf<Movie>()
        val series = mutableListOf<Series>()
        val catId = "${sourceId}_${type}_$categoryRawId"
        all.forEachIndexed { index, item ->
            val id = item.string("id") ?: return@forEachIndexed
            val isSeries = kind == CategoryKind.SERIES || item.bool("is_series")
            val name = item.string("name") ?: item.string("o_name") ?: "Untitled $id"
            val poster = absolute(item.string("screenshot_uri") ?: item.string("cover_big"))
            val rating = (item.double("rating_imdb") ?: item.double("rating_kinopoisk"))?.takeIf { it > 0 }
            val stream = StalkerLocator.Vod(item.string("cmd") ?: "").encoded
            val added = parseLooseDate(item.string("added") ?: "")
            if (isSeries) {
                series += Series(id = "${sourceId}_series_$id", sourceId = sourceId, categoryId = catId, name = name, providerId = id,
                    streamURL = stream, providerOrder = index, coverURL = poster, plot = item.string("description"),
                    year = item.string("year"), genre = item.string("genres_str"), cast = item.string("actors"),
                    director = item.string("director"), rating = rating, addedAt = added)
            } else {
                movies += Movie(id = "${sourceId}_vod_$id", sourceId = sourceId, categoryId = catId, name = name, providerId = id,
                    streamURL = stream, providerOrder = index, posterURL = poster, plot = item.string("description"),
                    year = item.string("year"), genre = item.string("genres_str"), cast = item.string("actors"),
                    director = item.string("director"), rating = rating, durationSeconds = item.int("time")?.let { it * 60 },
                    addedAt = added)
            }
        }
        return movies to series
    }

    internal class Page(val items: List<LenientObject>, val total: Int, val perPage: Int)

    internal suspend fun page(type: String, params: Map<String, String>, number: Int): Page {
        val js = call(type, "get_ordered_list", params + ("p" to number.toString()))
        val obj = LenientObject.of(js)
        val items = LenientJson.objects(obj?.get("data") ?: js)
        return Page(items, obj?.int("total_items") ?: items.size, maxOf(1, obj?.int("max_page_items") ?: 14))
    }

    public suspend fun episodes(series: Series): List<Episode> {
        val base = mapOf("movie_id" to series.providerId, "season_id" to "0", "episode_id" to "0")
        var seasons = LenientJson.objects(LenientObject.of(call("series", "get_ordered_list", base))?.get("data"))
        if (seasons.isEmpty()) seasons = LenientJson.objects(LenientObject.of(call("vod", "get_ordered_list", base))?.get("data"))
        val result = mutableListOf<Episode>()
        seasons.forEachIndexed { seasonIndex, season ->
            val seasonNumber = season.int("season_number") ?: seasonNumber(season.string("name")) ?: (seasonIndex + 1)
            val cmd = season.string("cmd") ?: ""
            val numbers = season.array("series").mapNotNull { el ->
                (el as? JsonPrimitive)?.let { p -> if (p.isString) p.content.toIntStrict() else p.contentOrNull?.toSwiftDouble()?.toInt() }
            }
            if (numbers.isNotEmpty()) {
                for (n in numbers) {
                    result += Episode(id = "${series.sourceId}_ep_${series.providerId}_${seasonNumber}_$n", seriesId = series.id,
                        sourceId = series.sourceId, season = seasonNumber, number = n, title = "Episode $n", providerId = "$n",
                        streamURL = StalkerLocator.EpisodeCmd(cmd, n).encoded, imageURL = absolute(season.string("screenshot_uri")))
                }
            } else {
                val seasonId = season.string("id") ?: return@forEachIndexed
                val eps = LenientJson.objects(LenientObject.of(call("series", "get_ordered_list",
                    mapOf("movie_id" to series.providerId, "season_id" to seasonId, "episode_id" to "0")))?.get("data"))
                eps.forEachIndexed { i, e ->
                    val eid = e.string("id") ?: return@forEachIndexed
                    val n = e.int("series_number") ?: e.int("episode_number") ?: (i + 1)
                    result += Episode(id = "${series.sourceId}_ep_$eid", seriesId = series.id, sourceId = series.sourceId,
                        season = seasonNumber, number = n, title = e.string("name") ?: "Episode $n", providerId = eid,
                        streamURL = StalkerLocator.EpisodeCmd(e.string("cmd") ?: cmd, null).encoded,
                        plot = e.string("description"), imageURL = absolute(e.string("screenshot_uri")))
                }
            }
        }
        return result.sortedWith(compareBy({ it.season }, { it.number }))
    }

    // Playback

    /** Resolves a locator to a playable URL via `create_link`. */
    public suspend fun resolve(locator: StalkerLocator): String = when (locator) {
        is StalkerLocator.ChannelCmd -> createLink("itv", locator.cmd, emptyMap())
        is StalkerLocator.Vod -> createLink("vod", locator.cmd, emptyMap())
        is StalkerLocator.EpisodeCmd -> createLink("vod", locator.cmd, locator.series?.let { mapOf("series" to it.toString()) } ?: emptyMap())
    }

    /** Archive playback for a past programme. */
    public suspend fun catchupURL(channelId: String, cmd: String, start: Instant, end: Instant): String {
        val minutes = maxOf(1, ((end.epochSecond - start.epochSecond) / 60).toInt())
        val direct = sanitize(cmd)
        if (direct.contains("/play/") && direct.contains("live.php")) {
            return direct.replace("live.php", "timeshift.php") + "&start=${ARCHIVE_FORMAT.format(start)}&duration=$minutes"
        }
        val variants = listOf(cmd, "${cmd}_", "ffrt http://localhost/ch/${channelId}_", "ffrt http://localhost/ch/$channelId", "http://localhost/ch/${channelId}_")
        var lastError: Exception = HttpException.EmptyBody()
        for (variant in variants) {
            try {
                val url = createLink("tv_archive", variant, mapOf(
                    "utc" to start.epochSecond.toString(), "lutc" to Instant.now().epochSecond.toString(),
                    "ch_id" to channelId, "start" to ARCHIVE_FORMAT.format(start), "end" to ARCHIVE_FORMAT.format(end),
                ))
                if (!url.contains("19691231")) return url
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                lastError = e
            }
        }
        throw lastError
    }

    internal suspend fun createLink(type: String, cmd: String, extra: Map<String, String>): String {
        val params = mapOf("cmd" to cmd, "forced_storage" to "undefined", "disable_ad" to "0", "download" to "0") + extra
        val js = call(type, "create_link", params)
        val obj = LenientObject.of(js)
        val link = obj?.string("cmd") ?: obj?.string("url") ?: (js as? JsonPrimitive)?.takeIf { it.isString }?.content ?: ""
        val url = sanitize(link)
        if (url.isEmpty() || url.startsWith("?") || url.contains("load.php?token=")) {
            // Fallback: a cmd that is already a URL is often directly playable.
            val direct = sanitize(cmd)
            if (direct.contains("://") && !direct.contains("localhost")) return direct
            throw HttpException.AuthFailed("The portal did not return a stream link")
        }
        return url
    }

    /** Strips `ffmpeg `/`ffrt ` prefixes and rewrites localhost/relative links to the portal origin. */
    internal fun sanitize(cmd: String): String {
        var s = cmd.trim()
        for (prefix in listOf("ffmpeg ", "ffrt ", "auto ", "ffrt2 ", "ffrt3 ", "ffrt4 ")) {
            if (s.lowercase().startsWith(prefix)) s = s.substring(prefix.length).trim(' ', '\t')
        }
        val portal = Origin.parse(portalURL) ?: return s
        if (portal.host.isEmpty()) return s
        if (s.startsWith("/")) return portal.origin + s
        val link = Origin.parse(s)
        if (link != null && (link.host == "localhost" || link.host == "127.0.0.1" || link.host.isEmpty())) {
            return link.withHost(portal.host, link.port ?: portal.port)
        }
        return s.replace("http://:", "http://${portal.host}:")
    }

    internal fun absolute(url: String?): String? {
        val u = url.nilIfEmpty() ?: return null
        if (u.startsWith("http")) return u
        val portal = Origin.parse(portalURL)?.takeIf { it.host.isNotEmpty() } ?: return u
        return portal.origin + if (u.startsWith("/")) u else "/$u"
    }

    // EPG

    public suspend fun epg(hours: Int = 72): List<StalkerEPGEntry> {
        val js = call("itv", "get_epg_info", mapOf("period" to hours.toString()))
        val data = (LenientObject.of(js)?.get("data") ?: js) as? JsonObject ?: return emptyList()
        val entries = mutableListOf<StalkerEPGEntry>()
        for ((channelId, value) in data) {
            for (p in LenientJson.objects(value)) {
                val start = p.date("start_timestamp") ?: continue
                val stop = p.date("stop_timestamp") ?: continue
                if (!stop.isAfter(start)) continue
                entries += StalkerEPGEntry(channelId, start, stop, p.string("name") ?: "", p.string("descr"))
            }
        }
        return entries
    }

    public companion object {
        public const val MAG_USER_AGENT: String =
            "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3"
        internal const val FIRMWARE_VERSION: String =
            "ImageDescription: 0.2.18-r23-250; ImageDate: Wed Aug 29 10:49:53 EEST 2018; PORTAL version: 5.6.2; API Version: JS API version: 343; STB API version: 146; Player Engine version: 0x58c"

        private val ARCHIVE_FORMAT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd:HH-mm", Locale.ROOT).withZone(ZoneOffset.UTC)

        internal fun randomHex(bytes: Int): String {
            val r = java.security.SecureRandom()
            return (0 until bytes).joinToString("") { "%02x".format(r.nextInt(256)) }
        }

        /** Dates as portals write them (device time zone, like Swift's DateFormatter default), or unix seconds. */
        internal fun parseLooseDate(s: String): Instant? {
            val zone = ZoneId.systemDefault()
            val dateTimes = listOf("yyyy-MM-dd HH:mm:ss", "MMMM d, yyyy, h:mm a")
            for (fmt in dateTimes) {
                runCatching { return LocalDateTime.parse(s, DateTimeFormatter.ofPattern(fmt, Locale.US)).atZone(zone).toInstant() }
            }
            for (fmt in listOf("yyyy-MM-dd", "dd.MM.yyyy", "MM/dd/yyyy")) {
                runCatching { return LocalDate.parse(s, DateTimeFormatter.ofPattern(fmt, Locale.US)).atStartOfDay(zone).toInstant() }
            }
            val ts = s.toSwiftDouble()
            if (ts != null && ts > 1_000_000_000) return Instant.ofEpochMilli((ts * 1000).toLong())
            return null
        }

        internal fun seasonNumber(name: String?): Int? {
            val m = Regex("""(?i)season\s*(\d+)""").find(name ?: return null) ?: return null
            return m.value.filter { it.isDigit() }.toIntStrict()
        }
    }
}

/** scheme://[user@]host[:port] + rest, enough of URLComponents for origins and host rewrites. */
internal class Origin(val scheme: String, val userInfo: String?, val host: String, val port: Int?, val path: String, val rest: String) {
    val origin: String get() = "$scheme://$host${port?.let { ":$it" } ?: ""}"

    fun withHost(newHost: String, newPort: Int?): String =
        "$scheme://${userInfo?.let { "$it@" } ?: ""}$newHost${newPort?.let { ":$it" } ?: ""}$path$rest"

    companion object {
        fun parse(url: String): Origin? {
            val parts = app.tuner.core.parsing.UrlParts.parse(url) ?: return null
            val scheme = url.substringBefore("://")
            val authority = parts.prefix.substringAfter("://")
            val userInfo = authority.substringBefore('@', "").ifEmpty { null }
            val hostPort = authority.substringAfter('@')
            val colon = hostPort.lastIndexOf(':').takeIf { it >= 0 && !hostPort.endsWith("]") }
            val host = if (colon != null) hostPort.substring(0, colon) else hostPort
            val port = colon?.let { hostPort.substring(it + 1).toIntOrNull() }
            return Origin(scheme, userInfo, host, port, parts.path, parts.suffix)
        }
    }
}
