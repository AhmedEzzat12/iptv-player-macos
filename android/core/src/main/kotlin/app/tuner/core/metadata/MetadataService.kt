// Port of Sources/TunerCore/Metadata/MetadataService.swift (+ MetadataCacheEntry from AppDatabase+Metadata.swift) @ 666f598
package app.tuner.core.metadata

import app.tuner.core.models.Movie
import app.tuner.core.models.Series
import app.tuner.core.net.HttpException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** A cached online-metadata lookup: a match, or a remembered "not found". */
public data class MetadataCacheEntry(
    val mediaId: String,
    val kind: MediaMetadata.Kind,
    /** null for "not found" (or a row that no longer decodes). */
    val metadata: MediaMetadata?,
    val notFound: Boolean,
    /** Epoch milliseconds. */
    val fetchedAt: Long,
) {
    public fun isFresh(now: Long = System.currentTimeMillis()): Boolean =
        if (notFound) now - fetchedAt < NOT_FOUND_TTL_MS else metadata != null && now - fetchedAt < MATCH_TTL_MS

    public companion object {
        /** Matches are refreshed after 30 days, "not found" after 7. */
        public const val MATCH_TTL_MS: Long = 30L * 86_400_000
        public const val NOT_FOUND_TTL_MS: Long = 7L * 86_400_000
    }
}

/** The `mediaMetadata` table (implemented by the data module with Room; in-memory in tests). */
public interface MetadataCache {
    public suspend fun entry(mediaId: String): MetadataCacheEntry?
    public suspend fun cached(mediaIds: List<String>): Map<String, MediaMetadata>
    public suspend fun save(metadata: MediaMetadata, mediaId: String)
    public suspend fun saveNotFound(mediaId: String, kind: MediaMetadata.Kind, at: Long)
    public suspend fun touch(mediaId: String, at: Long)
    public suspend fun markAllStale()
    public suspend fun clear()
}

/**
 * Online metadata for movies and series (posters, backdrops, title logos, plot, cast, ratings, trailers, episode stills).
 * Cinemeta needs no key; TMDB is used when the user provides one. Results (including "not found") are cached.
 *
 * Cache: matches fresh for 30 days, "not found" for 7; a fresh entry is returned without network. Lookups off: whatever is
 * cached (even stale) is returned. Order: TMDB (if a key is set; the provider's tmdbId first) → Cinemeta. TMDB auth errors
 * fall back silently; network/server errors are never cached as "not found" (the item isn't retried for two minutes).
 * Concurrent requests for one id share a lookup; at most three lookups run at once, newest request first.
 */
public class MetadataService(private val cache: MetadataCache, private val fetch: MetadataFetch = MetadataHTTP.live()) {
    private val lock = Mutex()
    public var settings: MetadataSettings = MetadataSettings()
        private set
    private var configured = false
    /** Rows fetched before this are treated as stale (set when the TMDB key or language changes). */
    private var staleBefore = Long.MIN_VALUE
    private val inFlight = HashMap<String, Deferred<MediaMetadata?>>()
    private val recentFailures = HashMap<String, Long>()
    private val slots = LifoSemaphore(MAX_CONCURRENT_LOOKUPS)

    /** Applies settings. Changing the TMDB key (or its language) marks the cache stale; cached values stay visible. */
    public suspend fun configure(new: MetadataSettings) {
        var markStale = false
        lock.withLock {
            val old = settings
            settings = new
            if (configured) {
                val oldKey = old.tmdbAPIKey?.trim()?.ifEmpty { null }
                val newKey = new.tmdbAPIKey?.trim()?.ifEmpty { null }
                if (oldKey != newKey || (newKey != null && old.language != new.language)) {
                    staleBefore = System.currentTimeMillis()
                    recentFailures.clear()
                    markStale = true
                } else if (new.enabled && !old.enabled) {
                    recentFailures.clear()
                }
            }
            configured = true
        }
        if (markStale) runCatching { cache.markAllStale() }
    }

    /** Cached result, else an online lookup (when enabled). null when nothing matched. */
    public suspend fun metadata(movie: Movie): MediaMetadata? =
        resolve(LookupRequest(movie.id, MediaMetadata.Kind.movie, movie.name, movie.year ?: movie.releaseDate, movie.tmdbId))

    /** Cached result, else an online lookup (when enabled). Includes `episodes` when available. */
    public suspend fun metadata(series: Series): MediaMetadata? =
        resolve(LookupRequest(series.id, MediaMetadata.Kind.series, series.name, series.year ?: series.releaseDate, null))

    /** Cache only, never the network (grids and shelves). Returns stale matches too. */
    public suspend fun cachedMetadata(mediaId: String): MediaMetadata? = runCatching { cache.entry(mediaId)?.metadata }.getOrNull()

    public suspend fun cachedMetadata(mediaIds: List<String>): Map<String, MediaMetadata> = runCatching { cache.cached(mediaIds) }.getOrDefault(emptyMap())

    public suspend fun clearCache() {
        lock.withLock { recentFailures.clear() }
        runCatching { cache.clear() }
    }

    /** Validates a TMDB key/token; returns a user-facing error message, or null when valid. */
    public suspend fun validateTMDBKey(key: String): String? {
        val client = TMDBClient.create(key, settings.language, fetch) ?: return "Enter a TMDB API key or API read access token."
        return try {
            client.validate()
            null
        } catch (e: HttpException.Status) {
            if (e.code == 401 || e.code == 403) {
                "TMDB rejected the key (${e.code}). Paste the API Key or the API Read Access Token from themoviedb.org → Settings → API."
            } else {
                "TMDB returned an error (${e.code}). Try again later."
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            "Couldn't reach TMDB: ${e.message}"
        }
    }

    internal data class LookupRequest(val mediaId: String, val kind: MediaMetadata.Kind, val name: String, val year: String?, val tmdbId: String?)

    private sealed class Step {
        class Done(val value: MediaMetadata?) : Step()
        class Wait(val running: Deferred<MediaMetadata?>) : Step()
        class Run(val deferred: CompletableDeferred<MediaMetadata?>, val settings: MetadataSettings) : Step()
    }

    private suspend fun resolve(request: LookupRequest): MediaMetadata? {
        lock.withLock { inFlight[request.mediaId] }?.let { return it.await() }
        val entry = runCatching { cache.entry(request.mediaId) }.getOrNull()
        val step = lock.withLock {
            val failedAt = recentFailures[request.mediaId]
            when {
                entry != null && isFresh(entry) -> Step.Done(entry.metadata)
                !settings.enabled -> Step.Done(entry?.metadata)
                failedAt != null && System.currentTimeMillis() - failedAt < FAILURE_BACKOFF_MS -> Step.Done(entry?.metadata)
                // The cache read suspended: another caller may have started this lookup meanwhile.
                inFlight[request.mediaId] != null -> Step.Wait(inFlight.getValue(request.mediaId))
                else -> Step.Run(CompletableDeferred<MediaMetadata?>().also { inFlight[request.mediaId] = it }, settings)
            }
        }
        return when (step) {
            is Step.Done -> step.value
            is Step.Wait -> step.running.await()
            is Step.Run -> {
                try {
                    step.deferred.complete(lookup(request, step.settings, entry))
                } catch (e: Throwable) {
                    step.deferred.completeExceptionally(e)
                    throw e
                } finally {
                    lock.withLock { inFlight.remove(request.mediaId) }
                }
                step.deferred.await()
            }
        }
    }

    private fun isFresh(entry: MetadataCacheEntry) = entry.fetchedAt >= staleBefore && entry.isFresh()

    private suspend fun lookup(request: LookupRequest, settings: MetadataSettings, cached: MetadataCacheEntry?): MediaMetadata? {
        slots.acquire()
        try {
            // A duplicate lookup that started just as another finished: the cache now has the answer.
            val now = runCatching { cache.entry(request.mediaId) }.getOrNull()
            if (now != null && lock.withLock { isFresh(now) }) return now.metadata
            val started = System.currentTimeMillis()
            return when (val outcome = MetadataProviders(fetch).lookup(request, settings, started)) {
                is MetadataProviders.Outcome.Found -> {
                    lock.withLock { recentFailures.remove(request.mediaId) }
                    runCatching { cache.save(outcome.metadata, request.mediaId) }
                    outcome.metadata
                }
                MetadataProviders.Outcome.NotFound -> {
                    lock.withLock { recentFailures.remove(request.mediaId) }
                    // A refresh that finds nothing keeps an earlier match (more likely a catalogue hiccup than a fix).
                    val previous = cached?.metadata
                    if (previous != null) {
                        runCatching { cache.touch(request.mediaId, started) }
                        previous
                    } else {
                        runCatching { cache.saveNotFound(request.mediaId, request.kind, started) }
                        null
                    }
                }
                MetadataProviders.Outcome.Failed -> {
                    lock.withLock { recentFailures[request.mediaId] = System.currentTimeMillis() }
                    cached?.metadata
                }
            }
        } finally {
            slots.release()
        }
    }

    public companion object {
        internal const val MAX_CONCURRENT_LOOKUPS: Int = 3
        /** After a failed lookup (offline, server error), the same item isn't retried for this long. */
        internal const val FAILURE_BACKOFF_MS: Long = 120_000
    }
}

/** Counting semaphore with LIFO hand-off: the most recent request runs next (the page just opened wins over prefetches). */
internal class LifoSemaphore(private val permits: Int) {
    private val lock = Mutex()
    private var running = 0
    private val waiting = ArrayDeque<CompletableDeferred<Unit>>()

    suspend fun acquire() {
        val wait = lock.withLock {
            if (running < permits) { running++; null } else CompletableDeferred<Unit>().also { waiting.addLast(it) }
        }
        wait?.await()
    }

    suspend fun release() {
        lock.withLock {
            val next = waiting.removeLastOrNull()
            if (next != null) next.complete(Unit) else running--
        }
    }
}

/** Provider fallback chain. */
internal class MetadataProviders(private val fetch: MetadataFetch) {
    sealed class Outcome {
        data class Found(val metadata: MediaMetadata) : Outcome()
        /** Every provider answered and nothing matched well enough (cacheable). */
        object NotFound : Outcome()
        /** A provider couldn't be reached or errored (not cacheable). */
        object Failed : Outcome()
    }

    suspend fun lookup(request: MetadataService.LookupRequest, settings: MetadataSettings, fetchedAt: Long): Outcome {
        val query = TitleMatcher.query(request.name, request.year, request.kind) ?: return Outcome.NotFound
        var transientFailure = false
        val tmdb = TMDBClient.create(settings.tmdbAPIKey, settings.language, fetch)
        if (tmdb != null) {
            try {
                tmdb.lookup(query, request.kind, request.tmdbId)?.let { return Outcome.Found(withEpisodeFallbacks(it.copy(fetchedAt = fetchedAt))) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Rejected keys fall back quietly; other errors make a Cinemeta miss inconclusive.
                if (!MetadataHTTP.isAuthError(e)) transientFailure = true
            }
        }
        return try {
            val md = CinemetaClient(fetch).lookup(query, request.kind)
            when {
                md != null -> Outcome.Found(withEpisodeFallbacks(md.copy(fetchedAt = fetchedAt)))
                transientFailure -> Outcome.Failed
                else -> Outcome.NotFound
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Outcome.Failed
        }
    }

    /** Series: adds TVmaze episode pictures as fallbacks. Best effort: a TVmaze failure never loses the match. */
    suspend fun withEpisodeFallbacks(metadata: MediaMetadata): MediaMetadata {
        val imdbId = metadata.imdbId
        if (metadata.kind != MediaMetadata.Kind.series || metadata.episodes.isEmpty() || imdbId == null) return metadata
        return try {
            metadata.copy(episodes = TVmazeClient.addFallbackStills(metadata.episodes, TVmazeClient(fetch).episodes(imdbId)))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            metadata
        }
    }
}
