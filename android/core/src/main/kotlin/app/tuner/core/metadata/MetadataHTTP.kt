// Port of Sources/TunerCore/Metadata/MetadataHTTP.swift @ 666f598
package app.tuner.core.metadata

import app.tuner.core.net.HttpClient
import app.tuner.core.net.HttpException
import app.tuner.core.net.LenientObject
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** GETs a URL and returns its top-level JSON object. Injected into the clients so tests can serve fixtures. */
public typealias MetadataFetch = suspend (url: String, headers: Map<String, String>) -> LenientObject

public object MetadataHTTP {
    public const val USER_AGENT: String = "Tuner/1.0 (Android TV)"

    /**
     * Live fetcher: HttpClient's retries (two, Cinemeta's search sometimes answers 504 after ~15 s) and lenient parse.
     * Never logs URLs: TMDB v3 keys travel in the query string.
     */
    public fun live(http: HttpClient = HttpClient(USER_AGENT, timeoutSeconds = 20)): MetadataFetch = { url, headers ->
        val data = http.data(url, mapOf("Accept" to "application/json") + headers, retries = 2)
        if (data.isEmpty()) throw HttpException.EmptyBody()
        LenientObject.of(HttpClient.parseJSONLeniently(data)) ?: throw HttpException.InvalidJSON(HttpClient.preview(data))
    }

    /** "This credential is wrong" (fall back to another provider, don't retry). */
    public fun isAuthError(e: Throwable): Boolean = e is HttpException.Status && (e.code == 401 || e.code == 403)

    public fun isNotFound(e: Throwable): Boolean = e is HttpException.Status && e.code == 404
}

/** Objects in an array field (non-objects are skipped). */
internal fun LenientObject.objects(key: String): List<LenientObject> = array(key).mapNotNull { LenientObject.of(it) }

/** Names from an array of strings, an array of `{name: …}` objects, or a comma-separated string; trimmed, unique. */
internal fun LenientObject.stringList(key: String): List<String> {
    val out = mutableListOf<String>()
    when (val v = raw[key]) {
        is JsonArray -> for (item in v) {
            when {
                item is JsonPrimitive && item.isString -> out.add(item.content)
                item is JsonObject -> LenientObject(item).string("name")?.let { out.add(it) }
            }
        }
        is JsonPrimitive -> if (v.isString) out.addAll(v.content.split(','))
        else -> Unit
    }
    val seen = HashSet<String>()
    return out.map { it.trim() }.filter { it.isNotEmpty() && seen.add(it) }
}

internal object MetadataFormat {
    private val isoDay = Regex("^\\d{4}-\\d{2}-\\d{2}$")
    private val hours = Regex("""(\d+)\s*h(?:ours?|rs?)?\s*(?:(\d+)\s*m)?""")

    /** "2024-03-01T00:00:00.000Z" / "2024-03-01" → "2024-03-01". */
    fun isoDay(s: String?): String? {
        val t = s?.trim(' ', '\t') ?: return null
        if (t.length < 10) return null
        val day = t.take(10)
        return if (isoDay.matches(day)) day else null
    }

    /** "155 min", "2h 35min", "1 h 5 m", "49" → minutes. */
    fun minutes(s: String?): Int? {
        val t = s?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        val m = hours.find(t)
        if (m != null) {
            val digits = m.value.split(Regex("\\D+")).filter { it.isNotEmpty() }.mapNotNull { it.toIntOrNull() }
            val total = (digits.firstOrNull() ?: 0) * 60 + (digits.getOrNull(1) ?: 0)
            return if (total > 0) total else null
        }
        val digits = t.takeWhile { it.isDigit() || it == ' ' }.filter { it.isDigit() }
        return digits.toIntOrNull()?.takeIf { it > 0 }
    }

    /** Display year: "2024"; series runs "2008–2013" (en dash); an open run shows its start year. */
    fun displayYear(s: String?, kind: MediaMetadata.Kind): String? {
        val (start, end) = TitleMatcher.parseYearRange(s)
        if (start == null) return null
        if (kind == MediaMetadata.Kind.series && end != null && end > start) return "$start–$end"
        return start.toString()
    }

    /** A rating in 0–10 rounded to one decimal, or null for missing/zero values. */
    fun rating(value: Double?): Double? {
        if (value == null || value <= 0 || value > 10) return null
        return Math.round(value * 10) / 10.0
    }
}
