// Port of Sources/TunerCore/Metadata/TMDBClient.swift @ 666f598
package app.tuner.core.metadata

import app.tuner.core.models.toIntStrict
import app.tuner.core.net.LenientObject
import app.tuner.core.net.urlPathEncoded
import app.tuner.core.net.urlQueryEncoded
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import java.util.Locale

/**
 * The Movie Database (with the user's own key): search in the title's script language, the chosen language and English,
 * then full details (credits, videos, images, external ids) and, for shows, every season's episodes.
 */
public class TMDBClient private constructor(
    internal val credential: Credential,
    public val language: String,
    private val fetch: MetadataFetch,
) {
    public sealed class Credential {
        public data class ApiKey(val key: String) : Credential()
        public data class Bearer(val token: String) : Credential()
    }

    internal val lang2: String get() = language.take(2)

    internal val headers: Map<String, String>
        get() = (credential as? Credential.Bearer)?.let { mapOf("Authorization" to "Bearer ${it.token}") } ?: emptyMap()

    internal fun url(path: String, params: List<Pair<String, String>>): String {
        val items = params.toMutableList()
        (credential as? Credential.ApiKey)?.let { items.add("api_key" to it.key) }
        val query = items.joinToString("&") { "${it.first}=${it.second.urlQueryEncoded}" }
        return if (query.isEmpty()) BASE + path else "$BASE$path?$query"
    }

    private suspend fun get(path: String, params: List<Pair<String, String>> = emptyList()): LenientObject = fetch(url(path, params), headers)

    /** Checks the key (Settings → Metadata). */
    public suspend fun validate() {
        get("/configuration")
    }

    public suspend fun lookup(query: TitleMatcher.Query, kind: MediaMetadata.Kind, tmdbId: String? = null): MediaMetadata? {
        val id = tmdbId?.trim(' ', '\t')
        if (id != null && (id.toIntStrict() ?: 0) > 0) {
            try {
                details(id, kind)?.let { return it }
            } catch (e: Exception) {
                if (!MetadataHTTP.isNotFound(e)) throw e // a stale provider id: fall back to searching
            }
        }
        val found = searchBestId(query, kind) ?: return null
        return details(found, kind)
    }

    public data class SearchResult(val id: String, val title: String, val originalTitle: String?, val date: String?)

    internal suspend fun searchBestId(query: TitleMatcher.Query, kind: MediaMetadata.Kind): String? {
        val languages = mutableListOf<String>()
        for (lang in listOfNotNull(scriptLanguage(query.title), language, "en-US")) {
            if (languages.none { it.take(2) == lang.take(2) }) languages.add(lang)
        }
        languages.forEachIndexed { i, lang ->
            // Full set of attempts in the first language; just the plain title in the others (keeps misses cheap).
            val attempts = mutableListOf<Pair<String, Int?>>(query.title to null)
            if (i == 0 && query.year != null) attempts.add(query.title to query.year)
            if (i == 0 && query.literalTitle != null) attempts.add(query.literalTitle to query.literalYear)
            for ((title, year) in attempts) {
                val results = search(title, year, kind, lang)
                bestMatch(query, results, kind)?.let { return results[it.first].id }
            }
        }
        return null
    }

    internal suspend fun search(title: String, year: Int?, kind: MediaMetadata.Kind, language: String): List<SearchResult> {
        val params = mutableListOf("query" to title, "include_adult" to "false", "language" to language, "page" to "1")
        if (year != null) params.add((if (kind == MediaMetadata.Kind.movie) "year" else "first_air_date_year") to year.toString())
        return parseSearch(get(if (kind == MediaMetadata.Kind.movie) "/search/movie" else "/search/tv", params), kind)
    }

    internal suspend fun details(id: String, kind: MediaMetadata.Kind): MediaMetadata? {
        val append = mutableListOf("credits", "videos", "images", "external_ids")
        if (lang2 != "en") append.add("translations")
        val languages = listOf(lang2, "en").distinct().joinToString(",") + ",null"
        val params = listOf(
            "language" to language,
            "append_to_response" to append.joinToString(","),
            "include_image_language" to languages,
            "include_video_language" to languages,
        )
        return when (kind) {
            MediaMetadata.Kind.movie -> mapMovie(get("/movie/${id.urlPathEncoded}", params), language)
            MediaMetadata.Kind.series -> {
                val json = get("/tv/${id.urlPathEncoded}", params)
                mapSeries(json, seasons(id, seasonNumbers(json)), language)
            }
        }
    }

    /** Seasons three at a time; failures are skipped, unless every season failed (then the first error is thrown). */
    internal suspend fun seasons(tvId: String, numbers: List<Int>): List<LenientObject> {
        if (numbers.isEmpty()) return emptyList()
        val gate = Semaphore(SEASON_CONCURRENCY)
        val results = coroutineScope {
            numbers.map { n ->
                async { gate.withPermit { runCatching { get("/tv/${tvId.urlPathEncoded}/season/$n", listOf("language" to language)) } } }
            }.awaitAll()
        }
        val ok = results.mapNotNull { it.getOrNull() }
        if (ok.isEmpty()) results.first().exceptionOrNull()?.let { if (it is kotlinx.coroutines.CancellationException) throw it; throw it }
        return ok
    }

    public companion object {
        public const val BASE: String = "https://api.themoviedb.org/3"
        public const val IMAGE_BASE: String = "https://image.tmdb.org/t/p/"
        internal const val MAX_SEASONS: Int = 30
        internal const val SEASON_CONCURRENCY: Int = 3

        /** null without a key. */
        public fun create(key: String?, language: String, fetch: MetadataFetch): TMDBClient? =
            credential(key)?.let { TMDBClient(it, normalizedLanguage(language), fetch) }

        /** A v4 read-access token (JWT) is sent as a bearer header; a v3 key travels as `api_key`. */
        internal fun credential(key: String?): Credential? {
            val k = key?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            if (k.startsWith("eyJ") || k.split('.').filter { it.isNotEmpty() }.size == 3) return Credential.Bearer(k)
            return Credential.ApiKey(k)
        }

        internal fun normalizedLanguage(s: String): String {
            val parts = s.replace('_', '-').split('-').filter { it.isNotEmpty() }
            val first = parts.firstOrNull()
            if (first == null || first.length != 2 || !first.all { it.isLetter() }) return "en-US"
            val lang = first.lowercase()
            val region = parts.drop(1).firstOrNull { it.length == 2 && it.all { c -> c.isLetter() } }
            return if (region != null) "$lang-${region.uppercase()}" else lang
        }

        internal fun parseSearch(json: LenientObject, kind: MediaMetadata.Kind): List<SearchResult> = json.objects("results").mapNotNull { r ->
            val id = r.string("id") ?: return@mapNotNull null
            val movie = kind == MediaMetadata.Kind.movie
            val title = if (movie) r.string("title") else r.string("name")
            val original = if (movie) r.string("original_title") else r.string("original_name")
            val display = title ?: original ?: return@mapNotNull null
            SearchResult(id, display, original, if (movie) r.string("release_date") else r.string("first_air_date"))
        }

        internal fun bestMatch(query: TitleMatcher.Query, results: List<SearchResult>, kind: MediaMetadata.Kind): Pair<Int, Double>? {
            val candidates = results.map { r ->
                TitleMatcher.Candidate(listOfNotNull(r.title, r.originalTitle), r.date?.let { TitleMatcher.parseYear(it) }, null)
            }
            return TitleMatcher.bestMatch(query, candidates, kind)
        }

        private fun ratingOf(j: LenientObject) = if ((j.int("vote_count") ?: 1) > 0) MetadataFormat.rating(j.double("vote_average")) else null

        internal fun mapMovie(j: LenientObject, language: String, fetchedAt: Long = System.currentTimeMillis()): MediaMetadata? {
            val id = j.string("id") ?: return null
            val title = j.string("title") ?: j.string("original_title") ?: return null
            val lang2 = normalizedLanguage(language).take(2)
            val releaseDate = MetadataFormat.isoDay(j.string("release_date"))
            val credits = j.obj("credits")
            val crew = credits?.objects("crew") ?: emptyList()
            val md = MediaMetadata(
                kind = MediaMetadata.Kind.movie, source = "TMDB", title = title, fetchedAt = fetchedAt,
                tmdbId = id,
                imdbId = j.obj("external_ids")?.string("imdb_id") ?: j.string("imdb_id"),
                originalTitle = j.string("original_title")?.takeIf { it != title },
                releaseDate = releaseDate,
                year = releaseDate?.take(4),
                overview = j.string("overview") ?: englishTranslation(j, "overview"),
                tagline = j.string("tagline"),
                genres = j.objects("genres").mapNotNull { it.string("name") },
                runtimeMinutes = j.int("runtime")?.takeIf { it > 0 },
                rating = ratingOf(j),
                country = countries(j, language),
                cast = cast(credits),
                directors = uniqueNames(crew.filter { it.string("job") == "Director" }),
                writers = uniqueNames(crew.filter { it.string("department") == "Writing" }).take(6),
                trailerYouTubeId = trailer(j.obj("videos"), lang2),
            )
            fillArtwork(md, j, lang2)
            return md
        }

        internal fun mapSeries(j: LenientObject, seasons: List<LenientObject>, language: String, fetchedAt: Long = System.currentTimeMillis()): MediaMetadata? {
            val id = j.string("id") ?: return null
            val title = j.string("name") ?: j.string("original_name") ?: return null
            val lang2 = normalizedLanguage(language).take(2)
            val releaseDate = MetadataFormat.isoDay(j.string("first_air_date"))
            var year: String? = null
            val start = releaseDate?.take(4)
            if (start != null) {
                val ended = (j.string("status")?.lowercase() ?: "") in setOf("ended", "canceled", "cancelled")
                val end = j.string("last_air_date")?.take(4)
                year = if (ended && end != null && end > start) "$start–$end" else start
            }
            val runtime = j.array("episode_run_time").mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> !p.isString }?.doubleOrNull?.toInt() }
                .firstOrNull { it > 0 } ?: j.obj("last_episode_to_air")?.int("runtime")?.takeIf { it > 0 }
            val md = MediaMetadata(
                kind = MediaMetadata.Kind.series, source = "TMDB", title = title, fetchedAt = fetchedAt,
                tmdbId = id,
                imdbId = j.obj("external_ids")?.string("imdb_id"),
                originalTitle = j.string("original_name")?.takeIf { it != title },
                releaseDate = releaseDate,
                year = year,
                overview = j.string("overview") ?: englishTranslation(j, "overview"),
                tagline = j.string("tagline"),
                genres = j.objects("genres").mapNotNull { it.string("name") },
                runtimeMinutes = runtime,
                rating = ratingOf(j),
                country = countries(j, language),
                cast = cast(j.obj("credits")),
                // Like Cinemeta, series credit their creators as writers.
                writers = uniqueNames(j.objects("created_by")),
                trailerYouTubeId = trailer(j.obj("videos"), lang2),
                episodes = episodes(seasons),
            )
            fillArtwork(md, j, lang2)
            return md
        }

        internal fun seasonNumbers(j: LenientObject): List<Int> {
            var numbers = j.objects("seasons").mapNotNull { s ->
                val n = s.int("season_number") ?: return@mapNotNull null
                if ((s.int("episode_count") ?: 1) > 0) n else null
            }
            val count = j.int("number_of_seasons")
            if (numbers.isEmpty() && count != null && count > 0) numbers = (1..minOf(count, MAX_SEASONS)).toList()
            val regular = numbers.filter { it > 0 }.sorted().distinct()
            return (regular + if (0 in numbers) listOf(0) else emptyList()).take(MAX_SEASONS)
        }

        internal fun episodes(seasons: List<LenientObject>): List<EpisodeMetadata> {
            val seen = HashSet<String>()
            val out = mutableListOf<EpisodeMetadata>()
            for (s in seasons) for (e in s.objects("episodes")) {
                val season = e.int("season_number") ?: s.int("season_number") ?: continue
                val number = e.int("episode_number") ?: continue
                if (!seen.add("${season}x$number")) continue
                out += EpisodeMetadata(season, number, e.string("name"), e.string("overview"), image(e.string("still_path"), "w300"),
                    airDate = MetadataFormat.isoDay(e.string("air_date")), rating = ratingOf(e))
            }
            return out.sortedWith(compareBy({ it.season }, { it.episode }))
        }

        internal fun image(path: String?, size: String): String? = if (path != null && path.startsWith("/")) IMAGE_BASE + size + path else null

        internal fun fillArtwork(md: MediaMetadata, j: LenientObject, lang2: String) {
            val images = j.obj("images")
            md.posterURL = image(j.string("poster_path"), "w500")
                ?: pick(images?.objects("posters") ?: emptyList(), lang2, allowNeutral = true)?.let { image(it, "w500") }
            md.backdropURL = image(j.string("backdrop_path"), "w1280")
                ?: pick((images?.objects("backdrops") ?: emptyList()).filter { it.string("iso_639_1") == null }, lang2, allowNeutral = true)
                    ?.let { image(it, "w1280") }
            var logo = pick(images?.objects("logos") ?: emptyList(), lang2, allowNeutral = true, preferPNG = true)
            if (logo != null) {
                // TMDB serves a PNG rendition of every SVG logo under the same name.
                if (logo.lowercase().endsWith(".svg")) logo = logo.dropLast(4) + ".png"
                md.logoURL = image(logo, "w500")
            }
        }

        internal fun pick(images: List<LenientObject>, lang2: String, allowNeutral: Boolean, preferPNG: Boolean = false): String? {
            data class Rank(val lang: Int, val png: Int, val votes: Double)
            fun rank(i: LenientObject): Rank {
                val lang = i.string("iso_639_1")
                val langRank = when (lang) { lang2 -> 0; "en" -> 1; null -> 2; else -> 9 }
                val pngRank = if (preferPNG && !(i.string("file_path") ?: "").lowercase().endsWith(".png")) 1 else 0
                return Rank(langRank, pngRank, -(i.double("vote_average") ?: 0.0))
            }
            return images.filter { it.string("file_path") != null && rank(it).lang <= (if (allowNeutral) 2 else 1) }
                .minWithOrNull(compareBy<LenientObject>({ rank(it).lang }, { rank(it).png }, { rank(it).votes }))
                ?.string("file_path")
        }

        internal fun trailer(videos: LenientObject?, lang2: String): String? {
            fun typeRank(v: LenientObject) = when (v.string("type")?.lowercase()) { "trailer" -> 0; "teaser" -> 1; else -> 9 }
            fun langRank(v: LenientObject) = when (v.string("iso_639_1")) { lang2 -> 0; "en" -> 1; else -> 2 }
            return (videos?.objects("results") ?: emptyList())
                .filter { it.string("site")?.lowercase() == "youtube" && it.string("key") != null && typeRank(it) < 9 }
                .minWithOrNull(compareBy<LenientObject>({ typeRank(it) }, { langRank(it) }, { if (it.bool("official")) 0 else 1 }))
                ?.string("key")
        }

        internal fun cast(credits: LenientObject?): List<CastMember> =
            (credits?.objects("cast") ?: emptyList()).withIndex()
                .sortedWith(compareBy({ it.value.int("order") ?: Int.MAX_VALUE }, { it.index }))
                .map { it.value }
                .take(20)
                .mapNotNull { c -> c.string("name")?.let { CastMember(it, c.string("character"), image(c.string("profile_path"), "w185")) } }

        internal fun countries(j: LenientObject, language: String): String? {
            var codes = j.array("origin_country").mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            if (codes.isEmpty()) codes = j.objects("production_countries").mapNotNull { it.string("iso_3166_1") }
            val locale = Locale.forLanguageTag(normalizedLanguage(language))
            val names = codes.distinct().take(3).map { code ->
                runCatching { Locale.Builder().setRegion(code).build().getDisplayCountry(locale) }.getOrNull()?.ifEmpty { null } ?: code
            }
            return if (names.isEmpty()) null else names.joinToString(", ")
        }

        internal fun englishTranslation(j: LenientObject, field: String): String? {
            val english = (j.obj("translations")?.objects("translations") ?: emptyList()).filter { it.string("iso_639_1") == "en" }
            val best = english.firstOrNull { it.string("iso_3166_1") == "US" } ?: english.firstOrNull()
            return best?.obj("data")?.string(field)
        }

        internal fun uniqueNames(people: List<LenientObject>): List<String> = people.mapNotNull { it.string("name") }.distinct()

        /** The search language a title's script suggests (Arabic, Cyrillic, Hebrew, Greek, Devanagari, Thai, CJK). */
        internal fun scriptLanguage(title: String): String? {
            for (cp in title.codePoints().toArray()) {
                if (!Character.isAlphabetic(cp) || cp < 0x80) continue
                when (cp) {
                    in 0x0600..0x06FF, in 0x0750..0x077F, in 0xFB50..0xFDFF, in 0xFE70..0xFEFF -> return "ar-SA"
                    in 0x0400..0x04FF -> return "ru-RU"
                    in 0x0590..0x05FF -> return "he-IL"
                    in 0x0370..0x03FF -> return "el-GR"
                    in 0x0900..0x097F -> return "hi-IN"
                    in 0x0E00..0x0E7F -> return "th-TH"
                    in 0x3040..0x30FF -> return "ja-JP"
                    in 0xAC00..0xD7AF, in 0x1100..0x11FF -> return "ko-KR"
                    in 0x4E00..0x9FFF -> return "zh-CN"
                }
            }
            return null
        }
    }
}
