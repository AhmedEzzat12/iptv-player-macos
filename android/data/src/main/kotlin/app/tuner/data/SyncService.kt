// Port of Sources/TunerCore/Services/SyncService.swift @ 666f598 (guide ingest comes later).
package app.tuner.data

import android.content.ContentValues
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Series
import app.tuner.core.models.Source
import app.tuner.core.models.VODDetails
import app.tuner.core.net.HttpClient
import app.tuner.core.net.HttpException
import app.tuner.core.parsing.Gzip
import app.tuner.core.parsing.M3UParser
import app.tuner.core.providers.StalkerClient
import app.tuner.core.providers.XtreamClient
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
        e.message ?: "Couldn't reach the playlist"
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
                errors += e.message ?: "Channels failed"
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
        for (s in library.sources()) {
            val hours = s.refreshHours ?: liveHours
            if (hours == 0) continue
            val last = s.lastSyncedAt?.toEpochMilli() ?: 0
            val lastVod = s.lastVODSyncedAt?.toEpochMilli() ?: 0
            if (now - last > hours * 3_600_000L || (s.kind != Source.Kind.M3U && now - lastVod > vodHours * 3_600_000L)) sync(s.id)
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
}
