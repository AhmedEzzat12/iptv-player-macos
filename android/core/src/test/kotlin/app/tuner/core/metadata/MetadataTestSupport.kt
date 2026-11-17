package app.tuner.core.metadata

import app.tuner.core.Fixtures
import app.tuner.core.models.Movie
import app.tuner.core.models.Series
import app.tuner.core.net.HttpException
import app.tuner.core.net.LenientObject
import kotlinx.coroutines.delay
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import java.util.concurrent.atomic.AtomicInteger

internal fun metadataJSON(name: String): LenientObject =
    LenientObject(Json.parseToJsonElement(String(Fixtures.bytes("metadata/$name"))).jsonObject)

internal fun json(text: String): LenientObject = LenientObject(Json.parseToJsonElement(text).jsonObject)

internal fun movie(id: String, name: String, year: String? = null, tmdbId: String? = null) =
    Movie(id = id, sourceId = "src", categoryId = null, name = name, providerId = id, providerOrder = 0, year = year, tmdbId = tmdbId)

internal fun series(id: String, name: String) = Series(id = id, sourceId = "src", categoryId = null, name = name, providerId = id, providerOrder = 0)

/** Serves fixtures by URL and records requests (port of the Swift StubNetwork). */
internal class StubNetwork(private val delayMs: Long = 0, private val handler: (String) -> LenientObject) {
    val requests: MutableList<String> = java.util.Collections.synchronizedList(mutableListOf())
    private val inFlight = AtomicInteger()
    val maxInFlight = AtomicInteger()

    val fetch: MetadataFetch = { url, _ ->
        requests.add(url)
        val n = inFlight.incrementAndGet()
        maxInFlight.accumulateAndGet(n) { a, b -> maxOf(a, b) }
        try {
            if (delayMs > 0) delay(delayMs)
            handler(url)
        } finally {
            inFlight.decrementAndGet()
        }
    }

    companion object {
        /** Cinemeta fixtures; anything else is an empty search / 404. */
        fun cinemeta(rawURL: String): LenientObject {
            val url = rawURL.lowercase()
            return when {
                url.contains("/catalog/movie/top/search=dune") -> metadataJSON("cinemeta_search_movie_dune.json")
                url.contains("/catalog/series/top/search=breaking") -> metadataJSON("cinemeta_search_series_breaking_bad.json")
                url.contains("/catalog/series/top/search=the%20office") -> metadataJSON("cinemeta_search_series_the_office.json")
                url.endsWith("/meta/movie/tt15239678.json") -> metadataJSON("cinemeta_meta_movie_dune.json")
                url.endsWith("/meta/series/tt0903747.json") -> metadataJSON("cinemeta_meta_series_breaking_bad.json")
                url.contains("/catalog/") -> json("""{"metas":[]}""")
                else -> throw HttpException.Status(404)
            }
        }
    }
}

/** The `mediaMetadata` table in memory. */
internal class MemoryMetadataCache : MetadataCache {
    val rows: MutableMap<String, MetadataCacheEntry> = java.util.concurrent.ConcurrentHashMap()
    override suspend fun entry(mediaId: String) = rows[mediaId]
    override suspend fun cached(mediaIds: List<String>) = mediaIds.mapNotNull { id -> rows[id]?.metadata?.let { id to it } }.toMap()
    override suspend fun save(metadata: MediaMetadata, mediaId: String) {
        // Round-trip through JSON like the database row does.
        val decoded = Json.decodeFromString(MediaMetadata.serializer(), Json.encodeToString(MediaMetadata.serializer(), metadata))
        rows[mediaId] = MetadataCacheEntry(mediaId, metadata.kind, decoded, false, metadata.fetchedAt)
    }
    override suspend fun saveNotFound(mediaId: String, kind: MediaMetadata.Kind, at: Long) {
        rows[mediaId] = MetadataCacheEntry(mediaId, kind, null, true, at)
    }
    override suspend fun touch(mediaId: String, at: Long) {
        rows[mediaId]?.let { rows[mediaId] = it.copy(fetchedAt = at) }
    }
    override suspend fun markAllStale() {
        rows.replaceAll { _, e -> e.copy(fetchedAt = 0) }
    }
    override suspend fun clear() = rows.clear()
}
