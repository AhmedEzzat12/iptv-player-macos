// Port of Sources/TunerCore/Skip/SkipSegmentService.swift @ 666f598 (learned intros are not in v1)
package app.tuner.core.skip

import app.tuner.core.metadata.MetadataFetch
import app.tuner.core.metadata.MetadataHTTP
import app.tuner.core.metadata.objects
import app.tuner.core.net.HttpClient
import app.tuner.core.net.HttpException
import app.tuner.core.net.LenientObject
import app.tuner.core.net.urlQueryEncoded
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** A cached lookup: the timings found (empty = "not found") and when (epoch ms). */
public data class SkipSegmentCacheEntry(val segments: List<SkipSegment>, val fetchedAt: Long) {
    public fun isFresh(now: Long): Boolean =
        now - fetchedAt < if (segments.isEmpty()) SkipSegmentService.NOT_FOUND_TTL_MS else SkipSegmentService.FOUND_TTL_MS
}

/** The `skipSegmentCache` table (implemented by the data module; in-memory in tests). */
public interface SkipSegmentCache {
    public suspend fun entry(mediaId: String): SkipSegmentCacheEntry?
    public suspend fun save(segments: List<SkipSegment>, mediaId: String, at: Long)
}

/**
 * Intro/recap/credits timings from the public crowd-sourced databases, cached per movie/episode. TheIntroDB (by IMDb or
 * TMDB id + season/episode) and IntroDB (by IMDb id) are asked together, without keys; only the ids and numbers are sent.
 * Found results are cached for 30 days, "not found" for 7; a network failure caches nothing. Logs never contain URLs.
 */
public class SkipSegmentService(
    private val cache: SkipSegmentCache,
    private val fetch: MetadataFetch = liveFetch(),
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    /** What to look up: the provider's movie/episode id (the cache key) and the title's public ids. */
    public class Lookup(
        public val mediaId: String,
        imdbId: String?,
        tmdbId: String?,
        /** null for movies. */
        public val season: Int? = null,
        public val episode: Int? = null,
    ) {
        public val imdbId: String? = imdbId?.let { validIMDbId(it) }
        public val tmdbId: String? = tmdbId?.takeIf { id -> id.isNotEmpty() && id.all { it.isDigit() } && id != "0" }
        internal val isEpisode: Boolean get() = season != null && episode != null
        internal val canLookUp: Boolean get() = this.imdbId != null || this.tmdbId != null
    }

    private val lock = Mutex()
    private val inFlight = HashMap<String, CompletableDeferred<List<SkipSegment>>>()

    /** Cached or freshly fetched timings (raw, unsanitised). With `allowNetwork` false only the cache is read. */
    public suspend fun segments(lookup: Lookup, allowNetwork: Boolean): List<SkipSegment> {
        val cached = runCatching { cache.entry(lookup.mediaId) }.getOrNull()
        if (cached != null && (!allowNetwork || cached.isFresh(now()))) return cached.segments
        if (!allowNetwork || !lookup.canLookUp) return cached?.segments ?: emptyList()
        var mine = false
        val deferred = lock.withLock {
            inFlight[lookup.mediaId] ?: CompletableDeferred<List<SkipSegment>>().also { inFlight[lookup.mediaId] = it; mine = true }
        }
        if (!mine) return deferred.await()
        try {
            deferred.complete(fetchAndCache(lookup, cached?.segments ?: emptyList()))
        } catch (e: Throwable) {
            deferred.completeExceptionally(e)
            throw e
        } finally {
            lock.withLock { inFlight.remove(lookup.mediaId) }
        }
        return deferred.await()
    }

    private suspend fun fetchAndCache(lookup: Lookup, fallback: List<SkipSegment>): List<SkipSegment> {
        val results = coroutineScope {
            val a = async { query(SkipSegment.Source.THE_INTRO_DB, theIntroDBURL(lookup)) }
            val b = async { query(SkipSegment.Source.INTRO_DB, introDBURL(lookup)) }
            listOf(a.await(), b.await())
        }
        val segments = results.flatMap { it.first }
        // A failure caches nothing unless the other database answered with timings.
        if (results.any { it.second } && segments.isEmpty()) return fallback
        runCatching { cache.save(segments, lookup.mediaId, now()) }
        return segments
    }

    /** (segments, failed). A 404 means the database doesn't know the title ("not found", cached). */
    private suspend fun query(source: SkipSegment.Source, url: String?): Pair<List<SkipSegment>, Boolean> {
        if (url == null) return emptyList<SkipSegment>() to false
        return try {
            val json = fetch(url, emptyMap())
            (if (source == SkipSegment.Source.THE_INTRO_DB) parseTheIntroDB(json) else parseIntroDB(json)) to false
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (e is HttpException.Status && e.code == 404) emptyList<SkipSegment>() to false else emptyList<SkipSegment>() to true
        }
    }

    public companion object {
        public const val FOUND_TTL_MS: Long = 30L * 86_400_000
        public const val NOT_FOUND_TTL_MS: Long = 7L * 86_400_000
        /** Online lookups never hold anything up for long (seconds). */
        internal const val TIMEOUT_SECONDS: Long = 8

        /** One attempt, short timeout: a slow database just means no button this time. */
        public fun liveFetch(): MetadataFetch {
            val http = HttpClient(MetadataHTTP.USER_AGENT, TIMEOUT_SECONDS)
            return { url, headers ->
                val data = http.data(url, mapOf("Accept" to "application/json") + headers, retries = 0)
                LenientObject.of(HttpClient.parseJSONLeniently(data)) ?: throw HttpException.InvalidJSON(HttpClient.preview(data))
            }
        }

        private val imdbPattern = Regex("^tt\\d{7,8}$")

        internal fun validIMDbId(id: String): String? = id.trim(' ', '\t').lowercase().takeIf { imdbPattern.matches(it) }

        private fun query(items: List<Pair<String, String>>) = items.joinToString("&") { "${it.first}=${it.second.urlQueryEncoded}" }

        /** `https://api.theintrodb.org/v4/media?imdb_id=…[&season=…&episode=…]` (TMDB id when there's no IMDb id). */
        internal fun theIntroDBURL(lookup: Lookup): String? {
            val items = mutableListOf<Pair<String, String>>()
            when {
                lookup.imdbId != null -> items.add("imdb_id" to lookup.imdbId)
                lookup.tmdbId != null -> items.add("tmdb_id" to lookup.tmdbId)
                else -> return null
            }
            if (lookup.isEpisode) items += listOf("season" to lookup.season.toString(), "episode" to lookup.episode.toString())
            return "https://api.theintrodb.org/v4/media?" + query(items)
        }

        /** `https://api.introdb.app/segments?imdb_id=…&season=…&episode=…` or `…&is_movie=true` (IMDb ids only). */
        internal fun introDBURL(lookup: Lookup): String? {
            val imdb = lookup.imdbId ?: return null
            val items = mutableListOf("imdb_id" to imdb)
            if (lookup.isEpisode) items += listOf("season" to lookup.season.toString(), "episode" to lookup.episode.toString())
            else items.add("is_movie" to "true")
            return "https://api.introdb.app/segments?" + query(items)
        }

        /** TheIntroDB v4: arrays per kind with `start_ms` (null = beginning) and `end_ms` (null = end). Previews ignored. */
        internal fun parseTheIntroDB(json: LenientObject): List<SkipSegment> {
            val out = mutableListOf<SkipSegment>()
            for ((key, kind) in listOf("recap" to SkipSegment.Kind.RECAP, "intro" to SkipSegment.Kind.INTRO, "credits" to SkipSegment.Kind.CREDITS)) {
                for (entry in json.objects(key)) {
                    out += SkipSegment(kind, entry.double("start_ms")?.div(1000) ?: 0.0, entry.double("end_ms")?.div(1000), SkipSegment.Source.THE_INTRO_DB)
                }
            }
            return out
        }

        /** IntroDB: one object per kind (`outro` is the credits), in ms or seconds. Post-credits scenes are ignored. */
        internal fun parseIntroDB(json: LenientObject): List<SkipSegment> {
            val out = mutableListOf<SkipSegment>()
            for ((key, kind) in listOf("recap" to SkipSegment.Kind.RECAP, "intro" to SkipSegment.Kind.INTRO, "outro" to SkipSegment.Kind.CREDITS)) {
                val entry = json.obj(key) ?: continue
                val start = entry.double("start_ms")?.div(1000) ?: entry.double("start_sec") ?: continue
                val end = entry.double("end_ms")?.div(1000) ?: entry.double("end_sec")
                out += SkipSegment(kind, start, end, SkipSegment.Source.INTRO_DB)
            }
            return out
        }
    }
}
