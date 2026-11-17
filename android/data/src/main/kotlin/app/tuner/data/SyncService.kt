// Port of Sources/TunerCore/Services/SyncService.swift and GuideService.swift @ 666f598.
package app.tuner.data

import android.content.ContentValues
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.EPGChannel
import app.tuner.core.models.EPGFeed
import app.tuner.core.models.Program
import app.tuner.core.models.Series
import app.tuner.core.models.Source
import app.tuner.core.models.VODDetails
import app.tuner.core.net.HttpClient
import app.tuner.core.net.HttpException
import app.tuner.core.parsing.Gzip
import app.tuner.core.parsing.M3UParser
import app.tuner.core.parsing.XMLTVParser
import app.tuner.core.providers.StalkerClient
import app.tuner.core.providers.XtreamClient
import app.tuner.core.services.GuideParse
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.util.UUID

/** Orchestrates provider sync: fetch → replace rows → status. One sync per source at a time. */
public class SyncService(private val library: Library, private val cacheDir: File) {
    public data class Progress(val sourceId: String, val step: String, val error: String? = null, val done: Boolean = false)

    private val _progress = MutableStateFlow<Progress?>(null)
    public val progress: StateFlow<Progress?> = _progress

    private val lock = Mutex()
    private val running = HashSet<String>()
    private val stalkerClients = HashMap<String, StalkerClient>()

    public suspend fun stalkerClient(source: Source): StalkerClient = lock.withLock {
        stalkerClients.getOrPut("${source.id}|${source.url}|${source.mac}") { StalkerClient(source) }
    }

    /** Validates credentials without writing anything (the editor's Test button). Returns a user-facing error or null. */
    public suspend fun test(source: Source): String? = try {
        when (source.kind) {
            Source.Kind.XTREAM -> XtreamClient(source).authenticate().let { null }
            Source.Kind.STALKER -> StalkerClient(source).liveCategories(source.id).let { null }
            Source.Kind.M3U -> {
                val p = M3UParser.parse(loadPlaylist(source), source.id)
                if (p.channels.isEmpty() && p.movies.isEmpty() && p.episodes.isEmpty()) "The playlist has no channels" else null
            }
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        e.message ?: "Couldn't reach the playlist (${e::class.java.simpleName})"
    }

    public suspend fun sync(sourceId: String) {
        val source = library.source(sourceId) ?: return
        if (!source.enabled || source.needsPassword) return
        if (!lock.withLock { running.add(sourceId) }) return
        try {
            val errors = mutableListOf<String>()
            var liveOK = false
            var vodOK = false
            _progress.value = Progress(sourceId, "Loading channels…")
            try {
                syncLive(source); liveOK = true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errors += e.message ?: "Channels failed (${e::class.java.simpleName})"
            }
            // VOD is attempted even if channels failed: a bad live response must not hide movies.
            if (source.includeVOD && source.kind != Source.Kind.M3U) {
                _progress.value = Progress(sourceId, "Loading movies and shows…")
                try {
                    syncVOD(source); vodOK = true
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    errors += "Movies & series: ${e.message}"
                }
            }
            if (source.includeLive) {
                _progress.value = Progress(sourceId, "Updating TV guide…")
                try {
                    val fresh = library.source(sourceId) ?: source
                    syncGuide(fresh)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    // Guide errors are recorded on the feed row; don't fail the playlist sync itself.
                }
            }
            val now = System.currentTimeMillis()
            library.updateStatus(sourceId, ContentValues().apply {
                put("lastError", errors.joinToString("\n").ifEmpty { null })
                // Each part stamped on its own success, so a failed part is retried without redoing the rest.
                if (liveOK) put("lastSyncedAt", now)
                if (vodOK) put("lastVODSyncedAt", now)
            })
            _progress.value = Progress(sourceId, if (errors.isEmpty()) "Done" else "Failed", errors.joinToString("\n").ifEmpty { null }, done = true)
        } finally {
            lock.withLock { running.remove(sourceId) }
        }
    }

    /** Sources whose data is older than their refresh interval (global defaults: live 6 h, VOD 24 h; 0 = manual). */
    public suspend fun refreshStale(liveHours: Int = 6, vodHours: Int = 24) {
        val now = System.currentTimeMillis()
        val feedsBySource = library.epgFeeds().groupBy { it.sourceId }
        for (s in library.sources()) {
            val hours = s.refreshHours ?: liveHours
            if (hours == 0) continue
            val last = s.lastSyncedAt?.toEpochMilli() ?: 0
            val lastVod = s.lastVODSyncedAt?.toEpochMilli() ?: 0
            if (now - last > hours * 3_600_000L || (s.kind != Source.Kind.M3U && now - lastVod > vodHours * 3_600_000L)) {
                sync(s.id)
            } else if (s.includeLive && s.enabled && !s.needsPassword && feedsBySource[s.id].isNullOrEmpty()) {
                runCatching { syncGuide(s) }
            }
        }
    }

    private suspend fun syncLive(source: Source) {
        when (source.kind) {
            Source.Kind.M3U -> {
                val playlist = M3UParser.parse(loadPlaylist(source), source.id)
                if (playlist.channels.isEmpty() && playlist.movies.isEmpty() && playlist.episodes.isEmpty()) {
                    throw HttpException.AuthFailed("The playlist has no channels")
                }
                library.replaceLive(source.id, if (source.includeLive) playlist.categories else emptyList(), if (source.includeLive) playlist.channels else emptyList())
                if (source.includeVOD) {
                    library.replaceMovies(source.id, playlist.movieCategories, playlist.movies)
                    library.replaceSeries(source.id, playlist.seriesCategories, playlist.series)
                    library.replaceEpisodes(playlist.episodes.groupBy { it.seriesId })
                }
                library.updateStatus(source.id, ContentValues().apply {
                    put("channelCount", playlist.channels.size); put("movieCount", playlist.movies.size); put("seriesCount", playlist.series.size)
                    playlist.epgURLs.firstOrNull()?.let { put("discoveredEPGURL", it) }
                })
            }
            Source.Kind.XTREAM -> {
                val client = XtreamClient(source)
                val account = client.authenticate()
                var count = 0
                if (source.includeLive) {
                    val (cats, streams) = coroutineScope {
                        val c = async { client.liveCategories(source.id) }
                        val s = async { client.liveStreams(source.id) }
                        c.await() to s.await()
                    }
                    library.replaceLive(source.id, cats, streams)
                    count = streams.size
                }
                library.updateStatus(source.id, ContentValues().apply {
                    put("channelCount", count); put("expiresAt", account.expiresAt?.toEpochMilli())
                    put("activeConnections", account.activeConnections); put("maxConnections", account.maxConnections)
                })
            }
            Source.Kind.STALKER -> {
                val client = stalkerClient(source)
                var count = 0
                if (source.includeLive) {
                    val cats = client.liveCategories(source.id)
                    val channels = client.channels(source.id)
                    library.replaceLive(source.id, cats, channels)
                    count = channels.size
                }
                val expiry = client.expiryDate()
                library.updateStatus(source.id, ContentValues().apply {
                    put("channelCount", count); if (expiry != null) put("expiresAt", expiry.toEpochMilli())
                })
            }
        }
    }

    private suspend fun syncVOD(source: Source) {
        when (source.kind) {
            Source.Kind.M3U -> Unit
            Source.Kind.XTREAM -> {
                // Movies and series stored independently; the two big downloads one after the other (gentler on panels).
                val client = XtreamClient(source)
                val failures = mutableListOf<String>()
                try {
                    val (c, m) = coroutineScope { async { client.vodCategories(source.id) }.let { c -> c to async { client.vodStreams(source.id) } } }
                        .let { it.first.await() to it.second.await() }
                    library.replaceMovies(source.id, c, m)
                    library.updateStatus(source.id, ContentValues().apply { put("movieCount", m.size) })
                } catch (e: CancellationException) { throw e } catch (e: Exception) { failures += "movies — ${e.message}" }
                try {
                    val (c, s) = coroutineScope { async { client.seriesCategories(source.id) }.let { c -> c to async { client.series(source.id) } } }
                        .let { it.first.await() to it.second.await() }
                    library.replaceSeries(source.id, c, s)
                    library.updateStatus(source.id, ContentValues().apply { put("seriesCount", s.size) })
                } catch (e: CancellationException) { throw e } catch (e: Exception) { failures += "series — ${e.message}" }
                if (failures.isNotEmpty()) throw HttpException.AuthFailed(failures.joinToString("; "))
            }
            Source.Kind.STALKER -> {
                // Portals page items 14 at a time: categories only; items load when a category opens.
                val client = stalkerClient(source)
                val movieCats = runCatching { client.vodCategories(source.id, CategoryKind.MOVIE) }.getOrDefault(emptyList())
                val seriesCats = runCatching { client.vodCategories(source.id, CategoryKind.SERIES) }.getOrDefault(emptyList())
                library.replaceMovies(source.id, movieCats, emptyList())
                library.replaceSeries(source.id, seriesCats, emptyList())
            }
        }
    }

    /** Fetches (and stores) a show's episodes; falls back to what's stored when the fetch fails. */
    public suspend fun episodes(series: Series): List<app.tuner.core.models.Episode> {
        val source = library.source(series.sourceId) ?: return library.episodes(series.id)
        val fetched = runCatching {
            when (source.kind) {
                Source.Kind.XTREAM -> XtreamClient(source).seriesInfo(series).episodes
                Source.Kind.STALKER -> stalkerClient(source).episodes(series)
                Source.Kind.M3U -> null
            }
        }.getOrNull()
        if (!fetched.isNullOrEmpty()) library.replaceEpisodes(mapOf(series.id to fetched))
        return library.episodes(series.id)
    }

    /** Lazily fetched movie details (plot, cast…), Xtream only. */
    public suspend fun movieDetails(movie: app.tuner.core.models.Movie): VODDetails? {
        val source = library.source(movie.sourceId) ?: return null
        if (source.kind != Source.Kind.XTREAM) return null
        return runCatching { XtreamClient(source).vodInfo(movie) }.getOrNull()
    }

    /** Stalker: a VOD category's items on first open. */
    public suspend fun loadStalkerCategory(sourceId: String, kind: CategoryKind, categoryId: String) {
        val source = library.source(sourceId) ?: return
        if (source.kind != Source.Kind.STALKER) return
        val raw = categoryId.substringAfter("${sourceId}_${if (kind == CategoryKind.SERIES) "series" else "vod"}_")
        val (movies, series) = stalkerClient(source).items(sourceId, kind, raw)
        library.appendVOD(movies, series)
    }

    private suspend fun loadPlaylist(source: Source): ByteArray = withContext(Dispatchers.IO) {
        val url = source.url.trim()
        val bytes = if (url.startsWith("file://") || url.startsWith("/")) {
            File(if (url.startsWith("file://")) java.net.URI(url).path else url).readBytes()
        } else {
            val file = HttpClient(source.userAgent, timeoutSeconds = 120).download(url, directory = cacheDir)
            try { file.readBytes() } finally { file.delete() }
        }
        if (Gzip.isGzipped(bytes)) Gzip.decompress(bytes) else bytes
    }

    /** Downloads and ingests a source's XMLTV / Stalker guide feeds and resolves channel EPG keys. */
    public suspend fun syncGuide(source: Source): String? = withContext(Dispatchers.IO) {
        val errors = mutableListOf<String>()
        val attempted = HashSet<String>()
        val shiftSeconds = (source.epgTimeshiftHours * 3600).toLong()

        if (source.kind == Source.Kind.STALKER && source.autoLoadEPG && source.epgURL.isNullOrBlank()) {
            val feed = EPGFeed("${source.id}#stalker", source.url, source.id, 0)
            attempted.add(feed.id)
            try {
                library.saveFeed(feed)
                val entries = stalkerClient(source).epg(hours = 72)
                val channels = LinkedHashMap<String, EPGChannel>()
                val programmes = ArrayList<Program>(entries.size)
                val counts = HashMap<String, Int>()
                for (e in entries) {
                    val key = "${feed.id}|${e.channelId}"
                    if (!channels.containsKey(e.channelId)) channels[e.channelId] = EPGChannel(feed.id, e.channelId, e.channelId, null)
                    programmes.add(Program(epgKey = key, start = e.start.plusSeconds(shiftSeconds), end = e.stop.plusSeconds(shiftSeconds),
                        title = e.title, summary = e.desc))
                    counts[key] = (counts[key] ?: 0) + 1
                }
                library.replaceGuide(feed.id, channels.values.toList(), programmes, counts)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val msg = e.message ?: "Portal guide failed"
                errors += msg
                runCatching { library.recordFeedError(feed.id, msg) }
            }
        }

        val urls = mutableListOf<String>()
        val manual = source.epgURL?.trim()?.takeIf { it.isNotEmpty() }
        if (manual != null) {
            urls += manual
        } else if (source.autoLoadEPG) {
            // The provider's url-tvg must be a web address: a playlist header shouldn't make the app read a local file.
            source.discoveredEPGURL?.trim()?.takeIf { it.startsWith("http://", true) || it.startsWith("https://", true) }?.let { urls += it }
            if (source.kind == Source.Kind.XTREAM) {
                val xmltv = XtreamClient(source).urls.xmltvURL()
                if (xmltv !in urls) urls += xmltv
            }
        }
        for (extra in source.extraEPGURLs) {
            val u = extra.trim()
            if (u.isNotEmpty() && u !in urls) urls += u
        }

        for ((index, url) in urls.withIndex()) {
            val feed = EPGFeed("${source.id}#$index", url, source.id, index)
            attempted.add(feed.id)
            try {
                library.saveFeed(feed)
                ingestXmltv(feed, source.userAgent, shiftSeconds)
                if (index == 0 && manual == null && source.discoveredEPGURL != url) {
                    library.updateStatus(source.id, ContentValues().apply { put("discoveredEPGURL", url) })
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val msg = e.message ?: "Guide failed"
                errors += msg
                runCatching { library.recordFeedError(feed.id, msg) }
            }
        }

        for (old in library.epgFeeds()) {
            if (old.sourceId == source.id && old.id !in attempted) library.deleteFeed(old.id)
        }
        var t1 = System.currentTimeMillis()
        library.resolveEPGKeys()
        android.util.Log.d("Guide", "resolved EPG keys in ${System.currentTimeMillis() - t1} ms"); t1 = System.currentTimeMillis()
        library.pruneProgrammes(Instant.now().minusSeconds(GuideParse.PAST_RETENTION_SECONDS))
        android.util.Log.d("Guide", "pruned in ${System.currentTimeMillis() - t1} ms")
        errors.joinToString("\n").ifEmpty { null }
    }

    public suspend fun addGlobalFeed(url: String): String? = withContext(Dispatchers.IO) {
        val cleaned = url.trim().let { if (!it.contains("://")) "https://$it" else it }
        val existing = library.epgFeeds().filter { it.sourceId == null }
        if (existing.any { it.url == cleaned }) return@withContext null
        val priority = (existing.maxOfOrNull { it.priority } ?: -1) + 1
        val feed = EPGFeed("global#${UUID.randomUUID().toString().uppercase()}", cleaned, null, priority)
        library.saveFeed(feed)
        try {
            ingestXmltv(feed, null, 0)
            library.resolveEPGKeys()
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val msg = e.message ?: "Couldn't load guide"
            runCatching { library.recordFeedError(feed.id, msg) }
            msg
        }
    }

    public suspend fun refreshGlobalFeeds(): String? = withContext(Dispatchers.IO) {
        val errors = mutableListOf<String>()
        for (feed in library.epgFeeds().filter { it.sourceId == null }) {
            try {
                ingestXmltv(feed, null, 0)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val msg = e.message ?: "Couldn't load guide"
                errors += msg
                runCatching { library.recordFeedError(feed.id, msg) }
            }
        }
        library.resolveEPGKeys()
        errors.joinToString("\n").ifEmpty { null }
    }

    private suspend fun ingestXmltv(feed: EPGFeed, userAgent: String?, shiftSeconds: Long) {
        val u = feed.url.trim()
        val downloaded: File
        val deleteDownloaded: Boolean
        if (u.startsWith("file://") || u.startsWith("/")) {
            downloaded = File(if (u.startsWith("file://")) java.net.URI(u).path else u)
            deleteDownloaded = false
        } else {
            var t = System.currentTimeMillis()
            downloaded = HttpClient(userAgent, timeoutSeconds = 120).download(u, directory = cacheDir)
            android.util.Log.d("Guide", "feed ${feed.id}: downloaded ${downloaded.length()} bytes in ${System.currentTimeMillis() - t} ms")
            deleteDownloaded = true
        }
        var decompressed: File? = null
        try {
            val xmlFile = if (Gzip.isGzipped(downloaded)) {
                File(cacheDir, "tuner-xmltv-${UUID.randomUUID()}.xml").also { out ->
                    Gzip.decompress(downloaded, out)
                    decompressed = out
                }
            } else downloaded
            val now = Instant.now()
            var t0 = System.currentTimeMillis()
            val wanted = library.wantedGuideSet()
            android.util.Log.d("Guide", "feed ${feed.id}: wanted set in ${System.currentTimeMillis() - t0} ms"); t0 = System.currentTimeMillis()
            val result = GuideParse.parse(
                file = xmlFile, feedId = feed.id, wanted = wanted, shiftSeconds = shiftSeconds,
                windowStart = now.minusSeconds(GuideParse.PAST_RETENTION_SECONDS),
                windowEnd = now.plusSeconds(GuideParse.FUTURE_RETENTION_SECONDS),
            )
            if (!result.sawGuide && !XMLTVParser.looksLikeXMLTV(xmlFile)) {
                throw HttpException.AuthFailed("Not an XMLTV guide")
            }
            android.util.Log.d("Guide", "feed ${feed.id}: parsed ${result.channels.size} channels, ${result.programmes.size} programmes in ${System.currentTimeMillis() - t0} ms"); t0 = System.currentTimeMillis()
            library.replaceGuide(feed.id, result.channels, result.programmes, result.counts)
            android.util.Log.d("Guide", "feed ${feed.id}: saved in ${System.currentTimeMillis() - t0} ms")
        } finally {
            if (deleteDownloaded) downloaded.delete()
            decompressed?.delete()
        }
    }
}
