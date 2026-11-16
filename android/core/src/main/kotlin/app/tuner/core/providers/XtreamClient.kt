// Port of Sources/TunerCore/Providers/XtreamClient.swift @ 666f598
package app.tuner.core.providers

import app.tuner.core.models.CatchupType
import app.tuner.core.models.Category
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Channel
import app.tuner.core.models.Episode
import app.tuner.core.models.Movie
import app.tuner.core.models.Series
import app.tuner.core.models.Source
import app.tuner.core.models.VODDetails
import app.tuner.core.net.HttpClient
import app.tuner.core.net.HttpException
import app.tuner.core.net.LenientJson
import app.tuner.core.net.LenientObject
import app.tuner.core.nilIfEmpty
import app.tuner.core.parsing.TitleParser
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

public data class XtreamAccount(
    val status: String?,
    val expiresAt: Instant?,
    val activeConnections: Int?,
    val maxConnections: Int?,
    val isTrial: Boolean,
    /** Server clock minus UTC (seconds), used to express timeshift start times in the panel's local time. */
    val serverTimeOffset: Double,
    val epgURLCandidates: List<String>,
)

/** Client for the Xtream Codes `player_api.php` API. */
public class XtreamClient(base: String, username: String, password: String, userAgent: String? = null) {
    public val urls: XtreamURLs = XtreamURLs(base, username, password)
    private val http = HttpClient(userAgent, timeoutSeconds = 60)

    public constructor(source: Source) : this(source.baseURL, source.username ?: "", source.password ?: "", source.userAgent)

    internal suspend fun call(action: String? = null, params: Map<String, String> = emptyMap()): JsonElement {
        val json = http.json(urls.apiURL(action, params))
        val obj = LenientObject.of(json)
        if (obj != null) {
            val user = obj.obj("user_info")
            if (user != null && user.int("auth") == 0) throw HttpException.AuthFailed("Xtream login failed — check username and password")
            val message = obj.string("error") ?: obj.string("message")
            if (action != null && message != null && obj.raw.size <= 2) throw HttpException.AuthFailed(message)
        }
        return json
    }

    public suspend fun authenticate(): XtreamAccount {
        val obj = LenientObject.of(call()) ?: throw HttpException.AuthFailed("Not an Xtream Codes server (missing user_info)")
        val user = obj.obj("user_info") ?: throw HttpException.AuthFailed("Not an Xtream Codes server (missing user_info)")
        if (user.int("auth") != 1) throw HttpException.AuthFailed("Xtream login failed — check username and password")
        val status = user.string("status")
        if (status != null && status.lowercase() != "active") throw HttpException.AuthFailed("Account status: $status")
        val server = obj.obj("server_info")
        var offset = 0.0
        val timeNow = server?.string("time_now")
        val ts = server?.double("timestamp_now")
        if (timeNow != null && ts != null) {
            val asUTC = runCatching { LocalDateTime.parse(timeNow, TIME_NOW).toEpochSecond(ZoneOffset.UTC) }.getOrNull()
            if (asUTC != null) {
                offset = asUTC - ts
                // Round to the nearest quarter hour; panels report a few seconds of skew.
                offset = Math.rint(offset / 900) * 900
            }
        }
        return XtreamAccount(
            status = status,
            expiresAt = user.date("exp_date"),
            activeConnections = user.int("active_cons"),
            maxConnections = user.int("max_connections"),
            isTrial = user.bool("is_trial"),
            serverTimeOffset = offset,
            epgURLCandidates = epgURLCandidates(server),
        )
    }

    internal fun epgURLCandidates(serverInfo: LenientObject?): List<String> {
        val primary = urls.xmltvURL()
        val list = mutableListOf(primary)
        val host = serverInfo?.string("url")
        if (host != null) {
            val proto = serverInfo.string("server_protocol") ?: "http"
            val port = if (proto == "https") serverInfo.string("https_port") ?: "443" else serverInfo.string("port") ?: "80"
            val standard = (proto == "https" && port == "443") || (proto == "http" && port == "80")
            val query = primary.substringAfter("/xmltv.php")
            val candidate = "$proto://$host${if (standard) "" else ":$port"}/xmltv.php$query"
            if (candidate !in list) list.add(candidate)
        }
        return list
    }

    // Live

    public suspend fun liveCategories(sourceId: String): List<Category> =
        LenientJson.objects(call("get_live_categories")).mapIndexedNotNull { index, c ->
            val id = c.string("category_id") ?: return@mapIndexedNotNull null
            Category("${sourceId}_$id", sourceId, CategoryKind.LIVE, c.string("category_name") ?: "Category $id", index)
        }

    public suspend fun liveStreams(sourceId: String): List<Channel> =
        LenientJson.objects(call("get_live_streams")).mapIndexedNotNull { index, s -> liveChannel(sourceId, index, s) }

    internal fun liveChannel(sourceId: String, index: Int, s: LenientObject): Channel? {
        val streamId = s.string("stream_id") ?: return null
        val archive = s.int("tv_archive") ?: 0
        return Channel(
            id = "${sourceId}_$streamId",
            sourceId = sourceId,
            categoryId = s.string("category_id")?.let { "${sourceId}_$it" },
            name = s.string("name") ?: "Channel $streamId",
            number = s.int("num"),
            providerOrder = index,
            logoURL = s.string("stream_icon"),
            tvgId = s.string("epg_channel_id"),
            streamURL = "",
            providerStreamId = streamId,
            catchupType = if (archive > 0) CatchupType.XTREAM else null,
            catchupDays = if (archive > 0) (s.int("tv_archive_duration") ?: 7) else null,
            isAdult = s.bool("is_adult"),
        )
    }

    // VOD

    public suspend fun vodCategories(sourceId: String): List<Category> =
        LenientJson.objects(call("get_vod_categories")).mapIndexedNotNull { index, c ->
            val id = c.string("category_id") ?: return@mapIndexedNotNull null
            Category("${sourceId}_vod_$id", sourceId, CategoryKind.MOVIE, c.string("category_name") ?: "Category $id", index)
        }

    public suspend fun vodStreams(sourceId: String): List<Movie> =
        LenientJson.objects(call("get_vod_streams")).mapIndexedNotNull { index, s -> movie(sourceId, index, s) }

    internal fun movie(sourceId: String, index: Int, s: LenientObject): Movie? {
        val id = s.string("stream_id") ?: return null
        val rawName = s.string("name") ?: s.string("title") ?: "Untitled ($id)"
        val (title, year) = TitleParser.splitYear(rawName)
        return Movie(
            id = "${sourceId}_vod_$id", sourceId = sourceId, categoryId = s.string("category_id")?.let { "${sourceId}_vod_$it" },
            name = title, providerId = id, providerOrder = index,
            year = s.string("year") ?: year,
            posterURL = s.string("stream_icon"),
            containerExtension = s.string("container_extension"),
            rating = s.double("rating")?.takeIf { it > 0 },
            addedAt = s.date("added"),
            tmdbId = s.string("tmdb") ?: s.string("tmdb_id"),
            trailer = s.string("youtube_trailer"),
            plot = s.string("plot"),
            genre = s.string("genre"),
        )
    }

    public suspend fun vodInfo(movie: Movie): VODDetails = vodDetails(call("get_vod_info", mapOf("vod_id" to movie.providerId)))

    internal fun vodDetails(json: JsonElement): VODDetails {
        val d = VODDetails()
        val obj = LenientObject.of(json) ?: return d
        obj.obj("info")?.let { info ->
            d.plot = info.string("plot") ?: info.string("description")
            d.cast = info.string("cast") ?: info.string("actors")
            d.director = info.string("director")
            d.genre = info.string("genre")
            d.releaseDate = info.string("releasedate") ?: info.string("release_date")
            d.rating = info.double("rating")?.takeIf { it > 0 }
            d.durationSeconds = info.int("duration_secs")
            d.posterURL = info.string("movie_image") ?: info.string("cover_big")
            d.backdropURL = firstString(info["backdrop_path"])
            d.trailer = info.string("youtube_trailer")
            d.tmdbId = info.string("tmdb_id")
        }
        d.containerExtension = obj.obj("movie_data")?.string("container_extension")
        return d
    }

    // Series

    public suspend fun seriesCategories(sourceId: String): List<Category> =
        LenientJson.objects(call("get_series_categories")).mapIndexedNotNull { index, c ->
            val id = c.string("category_id") ?: return@mapIndexedNotNull null
            Category("${sourceId}_series_$id", sourceId, CategoryKind.SERIES, c.string("category_name") ?: "Category $id", index)
        }

    public suspend fun series(sourceId: String): List<Series> =
        LenientJson.objects(call("get_series")).mapIndexedNotNull { index, s -> seriesItem(sourceId, index, s) }

    internal fun seriesItem(sourceId: String, index: Int, s: LenientObject): Series? {
        val id = s.string("series_id") ?: return null
        val rawName = s.string("name") ?: s.string("title") ?: "Untitled ($id)"
        val (title, year) = TitleParser.splitYear(rawName)
        val lastModified = s.date("last_modified")
        return Series(
            id = "${sourceId}_series_$id", sourceId = sourceId, categoryId = s.string("category_id")?.let { "${sourceId}_series_$it" },
            name = title, providerId = id, providerOrder = index,
            year = s.string("year") ?: year,
            coverURL = s.string("cover"),
            backdropURL = firstString(s["backdrop_path"]),
            plot = s.string("plot"),
            cast = s.string("cast"),
            director = s.string("director"),
            genre = s.string("genre"),
            releaseDate = s.string("releaseDate") ?: s.string("release_date"),
            rating = s.double("rating")?.takeIf { it > 0 },
            lastModified = lastModified,
            addedAt = lastModified,
            trailer = s.string("youtube_trailer"),
        )
    }

    public suspend fun seriesInfo(series: Series): VODDetails = seriesDetails(series, call("get_series_info", mapOf("series_id" to series.providerId)))

    internal fun seriesDetails(series: Series, json: JsonElement): VODDetails {
        val d = VODDetails()
        val obj = LenientObject.of(json) ?: return d
        obj.obj("info")?.let { info ->
            d.plot = info.string("plot")
            d.cast = info.string("cast")
            d.director = info.string("director")
            d.genre = info.string("genre")
            d.releaseDate = info.string("releaseDate") ?: info.string("release_date")
            d.rating = info.double("rating")?.takeIf { it > 0 }
            d.posterURL = info.string("cover")
            d.backdropURL = firstString(info["backdrop_path"])
            d.trailer = info.string("youtube_trailer")
            d.tmdbId = info.string("tmdb") ?: info.string("tmdb_id")
        }
        // `episodes` is usually {"1": [...], "2": [...]} but some panels return [[...], [...]].
        val groups = mutableListOf<Pair<Int, List<LenientObject>>>()
        when (val episodes = obj["episodes"]) {
            is JsonObject -> for ((key, value) in episodes) groups.add((key.toIntOrNull() ?: 0) to LenientJson.objects(value))
            is JsonArray -> episodes.forEachIndexed { i, value ->
                val eps = LenientJson.objects(value)
                groups.add((eps.firstOrNull()?.int("season") ?: (i + 1)) to eps)
            }
            else -> Unit
        }
        for ((seasonKey, eps) in groups) {
            eps.forEachIndexed { i, e ->
                val epId = e.string("id") ?: return@forEachIndexed
                val season = e.int("season") ?: seasonKey
                val number = e.int("episode_num") ?: (i + 1)
                val info = e.obj("info")
                d.episodes.add(
                    Episode(
                        id = "${series.sourceId}_ep_$epId", seriesId = series.id, sourceId = series.sourceId,
                        season = season, number = number, title = e.string("title") ?: "Episode $number", providerId = epId,
                        containerExtension = e.string("container_extension"),
                        plot = info?.string("plot"),
                        imageURL = info?.string("movie_image"),
                        durationSeconds = info?.int("duration_secs"),
                        airDate = info?.string("releasedate") ?: info?.string("air_date"),
                    ),
                )
            }
        }
        d.episodes.sortWith(compareBy({ it.season }, { it.number }))
        return d
    }

    public companion object {
        private val TIME_NOW: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.ROOT)

        internal fun firstString(element: JsonElement?): String? = when (element) {
            is JsonPrimitive -> if (element.isString) element.contentOrNull.nilIfEmpty() else null
            is JsonArray -> element.firstNotNullOfOrNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.contentOrNull.nilIfEmpty() }
            else -> null
        }
    }
}
