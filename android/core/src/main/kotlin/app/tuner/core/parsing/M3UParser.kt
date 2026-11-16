// Port of Sources/TunerCore/Parsing/M3UParser.swift @ 666f598
package app.tuner.core.parsing

import app.tuner.core.models.CatchupType
import app.tuner.core.models.Category
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Channel
import app.tuner.core.models.Episode
import app.tuner.core.models.Movie
import app.tuner.core.models.Series
import app.tuner.core.models.toIntStrict
import app.tuner.core.nilIfEmpty

/** Result of parsing an extended M3U playlist. */
public data class M3UPlaylist(
    val epgURLs: MutableList<String> = mutableListOf(),
    val categories: MutableList<Category> = mutableListOf(),
    val channels: MutableList<Channel> = mutableListOf(),
    val movieCategories: MutableList<Category> = mutableListOf(),
    val movies: MutableList<Movie> = mutableListOf(),
    val seriesCategories: MutableList<Category> = mutableListOf(),
    val series: MutableList<Series> = mutableListOf(),
    val episodes: MutableList<Episode> = mutableListOf(),
)

/**
 * Byte-level extended-M3U parser. Compared with ynotv it also keeps commas inside quoted attributes and titles,
 * honours `#EXTVLCOPT:http-user-agent=` / `http-referrer=` and `#EXTGRP:`, accepts any URL scheme, splits
 * comma-separated `url-tvg` lists, and routes Xtream-style `/movie/` and `/series/` entries into the VOD library.
 */
public object M3UParser {
    public fun parse(bytes: ByteArray, sourceId: String): M3UPlaylist {
        val builder = Builder(sourceId)
        var pending: PendingEntry? = null
        var vlcUserAgent: String? = null
        var vlcReferrer: String? = null
        var extGroup: String? = null

        var i = 0
        val n = bytes.size
        if (n >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) i = 3

        while (i < n) {
            var lineEnd = i
            while (lineEnd < n && bytes[lineEnd] != LF && bytes[lineEnd] != CR) lineEnd++
            var start = i
            var end = lineEnd
            i = lineEnd
            while (i < n && (bytes[i] == LF || bytes[i] == CR)) i++

            while (start < end && isSpace(bytes[start])) start++
            while (end > start && isSpace(bytes[end - 1])) end--
            if (start == end) continue

            val line = Line(bytes, start, end)
            if (bytes[start] == '#'.code.toByte()) {
                when {
                    line.hasPrefix("#EXTINF") -> {
                        pending = parseExtinf(line)
                        vlcUserAgent = null
                        vlcReferrer = null
                        extGroup = null
                    }
                    line.hasPrefix("#EXTM3U") -> builder.applyHeader(parseAttributes(line, start + 7).first)
                    line.hasPrefix("#EXTVLCOPT:") -> {
                        val opt = line.string(start + 11)
                        value("http-user-agent", opt)?.let { vlcUserAgent = it }
                        (value("http-referrer", opt) ?: value("http-referer", opt))?.let { vlcReferrer = it }
                    }
                    line.hasPrefix("#EXTGRP:") -> extGroup = line.string(start + 8).nilIfEmpty()
                }
                continue
            }

            // A URL line consumes the pending #EXTINF metadata.
            val entry = pending ?: continue
            pending = null
            val url = line.string(start)
            if (!url.contains("://") && !url.startsWith("/")) continue
            entry.userAgent = vlcUserAgent ?: entry.attributes["user-agent"] ?: entry.attributes["http-user-agent"]
            entry.referrer = vlcReferrer ?: entry.attributes["referrer"] ?: entry.attributes["http-referrer"]
            if (entry.attributes["group-title"] == null && entry.attributes["group"] == null && extGroup != null) {
                entry.attributes["group-title"] = extGroup
            }
            builder.add(entry, url)
        }
        return builder.playlist
    }

    // EXTINF

    internal class PendingEntry(
        val title: String,
        val attributes: MutableMap<String, String>,
        var userAgent: String? = null,
        var referrer: String? = null,
    )

    /** A trimmed line inside the playlist bytes. */
    internal class Line(val bytes: ByteArray, val start: Int, val end: Int) {
        fun string(from: Int, to: Int = end): String = String(bytes, from, maxOf(0, to - from), Charsets.UTF_8)

        /** Case-insensitive ASCII prefix. */
        fun hasPrefix(prefix: String): Boolean {
            if (end - start < prefix.length) return false
            for (k in prefix.indices) {
                if (upper(bytes[start + k].toInt() and 0xFF) != upper(prefix[k].code)) return false
            }
            return true
        }

        private fun upper(c: Int) = if (c in 0x61..0x7A) c - 0x20 else c
    }

    internal fun parseExtinf(line: Line): PendingEntry {
        val b = line.bytes
        var p = line.start + 7 // after "#EXTINF"
        if (p < line.end && b[p] == ':'.code.toByte()) p++
        // duration token
        while (p < line.end && isSpace(b[p])) p++
        while (p < line.end && !isSpace(b[p]) && b[p] != COMMA) p++
        val (attributes, titleStart) = parseAttributes(line, p)
        val title = titleStart?.let { line.string(it).trim(' ', '\t') } ?: ""
        return PendingEntry(title, attributes)
    }

    /** Parses `key="value" key2=value2 ...` until a top-level comma (returned as the title start). */
    internal fun parseAttributes(line: Line, from: Int): Pair<MutableMap<String, String>, Int?> {
        val b = line.bytes
        val attrs = HashMap<String, String>()
        var p = from
        val end = line.end
        while (p < end) {
            while (p < end && isSpace(b[p])) p++
            if (p >= end) break
            if (b[p] == COMMA) return attrs to (p + 1)

            val keyStart = p
            while (p < end && b[p] != EQUALS && b[p] != COMMA && !isSpace(b[p])) p++
            val key = line.string(keyStart, p).lowercase()
            // tolerate spaces around '='
            var q = p
            while (q < end && isSpace(b[q])) q++
            if (q >= end || b[q] != EQUALS) continue // bare token
            p = q + 1
            while (p < end && isSpace(b[p])) p++
            if (p >= end) break

            val value: String
            val quote = b[p]
            if (quote == DQUOTE || quote == SQUOTE) {
                val valueStart = p + 1
                var close = valueStart
                while (close < end && b[close] != quote) close++
                if (close < end) {
                    value = line.string(valueStart, close)
                    p = close + 1
                } else {
                    // Unclosed quote: read up to the next comma.
                    var c = valueStart
                    while (c < end && b[c] != COMMA) c++
                    value = line.string(valueStart, c)
                    p = c
                }
            } else {
                val valueStart = p
                while (p < end && !isSpace(b[p]) && b[p] != COMMA) p++
                val raw = line.string(valueStart, p)
                // `tvg-id= tvg-name="A"` must not swallow the next key.
                value = if (raw.contains("=") && !raw.contains("://") && !raw.contains("?")) "" else raw
            }
            if (key.isNotEmpty() && attrs[key].isNullOrEmpty()) attrs[key] = value.trim(' ', '\t')
        }
        return attrs to null
    }

    // Builder

    internal class Builder(private val sourceId: String) {
        private val ids = M3UChannelIDAllocator(sourceId)
        val playlist = M3UPlaylist()
        private val categoryIndex = HashSet<String>()
        private val movieCategoryIndex = HashSet<String>()
        private val seriesCategoryIndex = HashSet<String>()
        private val seriesIndex = HashSet<String>()
        private val movieIDs = HashSet<String>()
        private var headerCatchupType: String? = null
        private var headerCatchupSource: String? = null
        private var headerCatchupDays: Int? = null

        fun applyHeader(attrs: Map<String, String>) {
            for (key in listOf("url-tvg", "x-tvg-url", "tvg-url")) {
                val raw = attrs[key] ?: continue
                for (url in raw.split(',')) {
                    val u = url.trim(' ', '\t')
                    if (u.isNotEmpty() && u !in playlist.epgURLs) playlist.epgURLs.add(u)
                }
            }
            headerCatchupType = attrs["catchup"] ?: attrs["catchup-type"] ?: attrs["catchup-mode"]
            headerCatchupSource = attrs["catchup-source"] ?: attrs["catchup-url"]
            headerCatchupDays = (attrs["catchup-days"] ?: attrs["catchup-days-max"] ?: attrs["catchup-range"])?.toIntStrict()
            val shift = attrs["timeshift"] ?: attrs["tvg-shift"]
            if (headerCatchupType == null && shift != null && (shift.toIntStrict() ?: 0) > 0) headerCatchupType = "shift"
        }

        fun add(entry: PendingEntry, url: String) {
            val a = entry.attributes
            val tvgName = a["tvg-name"].nilIfEmpty()
            val name = entry.title.nilIfEmpty() ?: tvgName ?: "Channel ${playlist.channels.size + 1}"
            val group = (a["group-title"] ?: a["group"]).nilIfEmpty() ?: "Uncategorized"
            val logo = (a["tvg-logo"] ?: a["tvg-icon"] ?: a["logo"]).nilIfEmpty()

            when (classify(url)) {
                EntryKind.MOVIE -> { addMovie(name, group, logo, url); return }
                EntryKind.EPISODE -> { if (!addEpisode(name, group, logo, url)) addMovie(name, group, logo, url); return }
                EntryKind.LIVE -> Unit
            }

            val categoryId = liveCategory(group)
            var catchupType = (a["catchup"] ?: a["catchup-type"] ?: a["catchup-mode"]).nilIfEmpty()
            val shift = a["timeshift"] ?: a["tvg-shift"]
            if (catchupType == null && shift != null && (shift.toIntStrict() ?: 0) > 0) catchupType = "shift"
            catchupType = catchupType ?: headerCatchupType
            val catchupSource = (a["catchup-source"] ?: a["catchup-url"]).nilIfEmpty() ?: headerCatchupSource
            val days = (a["catchup-days"] ?: a["catchup-days-max"] ?: a["catchup-range"] ?: a["tvg-rec"])?.toIntStrict()
                ?: headerCatchupDays
            val hasCatchup = catchupType != null || catchupSource != null || (a["tvg-rec"]?.toIntStrict() ?: 0) > 0

            val tvgId = a["tvg-id"].nilIfEmpty()
            playlist.channels.add(
                Channel(
                    id = ids.allocate(tvgId, url),
                    sourceId = sourceId,
                    categoryId = categoryId,
                    name = name,
                    number = (a["tvg-chno"] ?: a["tvg-ch"] ?: a["channel-number"])?.toIntStrict(),
                    providerOrder = playlist.channels.size,
                    logoURL = logo,
                    tvgId = tvgId,
                    streamURL = url,
                    providerStreamId = xtreamStreamId(url),
                    catchupType = if (hasCatchup) CatchupType.fromM3U(catchupType ?: "default") else null,
                    catchupSource = catchupSource,
                    catchupDays = if (hasCatchup) (days ?: 7) else null,
                    userAgent = entry.userAgent.nilIfEmpty(),
                    referrer = entry.referrer.nilIfEmpty(),
                    isAdult = a["tvg-adult"] == "1" || group.lowercase().contains("adult") || group.contains("XXX"),
                ),
            )
        }

        private fun liveCategory(name: String): String {
            val id = "${sourceId}_${StableID.slug(name)}"
            if (categoryIndex.add(id)) {
                playlist.categories.add(Category(id, sourceId, CategoryKind.LIVE, name, playlist.categories.size))
            }
            return id
        }

        private fun addMovie(name: String, group: String, logo: String?, url: String) {
            val catId = "${sourceId}_vod_${StableID.slug(group)}"
            if (movieCategoryIndex.add(catId)) {
                playlist.movieCategories.add(Category(catId, sourceId, CategoryKind.MOVIE, group, playlist.movieCategories.size))
            }
            var id = "${sourceId}_vod_${StableID.hash(url)}"
            var n = 2
            while (id in movieIDs) { id = "${sourceId}_vod_${StableID.hash(url)}_$n"; n++ }
            movieIDs.add(id)
            val (title, year) = TitleParser.splitYear(name)
            playlist.movies.add(
                Movie(
                    id = id, sourceId = sourceId, categoryId = catId, name = title, providerId = id, streamURL = url,
                    providerOrder = playlist.movies.size, year = year, posterURL = logo, containerExtension = pathExtension(url),
                ),
            )
        }

        /** Groups "Show Name S01 E02" entries into a series. Returns false if the name has no SxxEyy. */
        private fun addEpisode(name: String, group: String, logo: String?, url: String): Boolean {
            val ep = TitleParser.episodeInfo(name) ?: return false
            val catId = "${sourceId}_series_${StableID.slug(group)}"
            if (seriesCategoryIndex.add(catId)) {
                playlist.seriesCategories.add(Category(catId, sourceId, CategoryKind.SERIES, group, playlist.seriesCategories.size))
            }
            val seriesId = "${sourceId}_series_${StableID.slug(ep.show)}"
            if (seriesIndex.add(seriesId)) {
                playlist.series.add(
                    Series(id = seriesId, sourceId = sourceId, categoryId = catId, name = ep.show, providerId = seriesId,
                        providerOrder = playlist.series.size, coverURL = logo),
                )
            }
            val epId = "${sourceId}_ep_${StableID.hash(url)}"
            playlist.episodes.add(
                Episode(id = epId, seriesId = seriesId, sourceId = sourceId, season = ep.season, number = ep.episode,
                    title = ep.title ?: "Episode ${ep.episode}", providerId = epId, streamURL = url, imageURL = logo,
                    containerExtension = pathExtension(url)),
            )
            return true
        }
    }

    // Helpers

    internal enum class EntryKind { LIVE, MOVIE, EPISODE }

    internal fun classify(url: String): EntryKind {
        val lower = url.lowercase()
        if (lower.contains("/movie/")) return EntryKind.MOVIE
        if (lower.contains("/series/")) return EntryKind.EPISODE
        if (lower.contains("/live/")) return EntryKind.LIVE
        val beforeQuery = lower.split('?').firstOrNull { it.isNotEmpty() } ?: lower
        val ext = beforeQuery.split('.').lastOrNull { it.isNotEmpty() } ?: ""
        return if (ext in setOf("mkv", "mp4", "avi", "mov", "m4v", "wmv")) EntryKind.MOVIE else EntryKind.LIVE
    }

    /** `/live/{user}/{pass}/{id}.ts` → `id`. */
    internal fun xtreamStreamId(url: String): String? {
        val path = UrlParts.parse(url)?.path ?: return null
        val parts = path.split('/').filter { it.isNotEmpty() }
        val i = parts.indexOf("live")
        if (i < 0 || i + 3 >= parts.size) return null
        val digits = parts[i + 3].takeWhile { it.isDigit() }
        return digits.ifEmpty { null }
    }

    /** Foundation's `URL.pathExtension` (null when empty): the last path component's text after its last dot. */
    internal fun pathExtension(url: String): String? {
        val path = UrlParts.parse(url)?.path ?: url.substringBefore('?').substringBefore('#')
        val last = path.trimEnd('/').substringAfterLast('/')
        val dot = last.lastIndexOf('.')
        return if (dot <= 0 || dot == last.length - 1) null else last.substring(dot + 1)
    }

    internal fun value(key: String, option: String): String? {
        if (!option.lowercase().startsWith("$key=")) return null
        return option.substring(key.length + 1).nilIfEmpty()
    }

    private fun isSpace(b: Byte) = b == SPACE || b == TAB

    private const val LF: Byte = 0x0A
    private const val CR: Byte = 0x0D
    private const val SPACE: Byte = 0x20
    private const val TAB: Byte = 0x09
    private const val COMMA: Byte = 0x2C
    private const val EQUALS: Byte = 0x3D
    private const val DQUOTE: Byte = 0x22
    private const val SQUOTE: Byte = 0x27
}
