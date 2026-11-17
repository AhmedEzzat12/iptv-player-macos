// Port of Sources/TunerCore/Metadata/CinemetaClient.swift @ 666f598
package app.tuner.core.metadata

import app.tuner.core.net.LenientObject
import app.tuner.core.net.urlPathEncoded
import app.tuner.core.parsing.ChannelNameNormalizer

/**
 * Stremio's public Cinemeta catalogue (IMDb-based, English, no key). Search, then fetch the full meta of the best match.
 * Artwork comes from metahub.space (poster/background/logo by IMDb id).
 */
public class CinemetaClient(private val fetch: MetadataFetch) {
    public data class SearchResult(val id: String, val name: String, val releaseInfo: String?, val poster: String?, val background: String?)

    /** null = no acceptable match. Throws on network/server errors. */
    public suspend fun lookup(query: TitleMatcher.Query, kind: MediaMetadata.Kind): MediaMetadata? {
        // Cinemeta only knows (English) IMDb titles: a query without any Latin letters can't match.
        if (!isSearchable(query.title)) return null
        var results = search(query.title, kind)
        var best = bestMatch(query, results, kind)
        if (best == null && query.literalTitle != null) {
            results = search(query.literalTitle, kind)
            best = bestMatch(query, results, kind)
        }
        if (best == null) return null
        val match = results[best.first]
        val meta = meta(match.id, kind)
        val md = meta?.let { map(it, kind) }
        // The search hit is trustworthy even when its full meta is missing: keep title and artwork.
        if (meta == null || md == null) return map(match, kind)
        // Ids missing from Cinemeta's catalogue redirect to a live IMDb proxy whose record can differ from the search
        // hit: re-check the match against the full meta.
        val (start, end) = TitleMatcher.parseYearRange(meta.string("releaseInfo") ?: meta.string("year"))
        val verified = TitleMatcher.Candidate(listOf(md.title), start, end)
        return if (TitleMatcher.score(query, verified, kind) >= TitleMatcher.ACCEPT_SCORE) md else null
    }

    internal suspend fun search(title: String, kind: MediaMetadata.Kind): List<SearchResult> =
        parseSearch(fetch("$BASE/catalog/${kind.cinemetaType}/top/search=${title.urlPathEncoded}.json", emptyMap()))

    internal suspend fun meta(id: String, kind: MediaMetadata.Kind): LenientObject? = try {
        fetch("$BASE/meta/${kind.cinemetaType}/${id.urlPathEncoded}.json", emptyMap()).obj("meta")
    } catch (e: Exception) {
        if (MetadataHTTP.isNotFound(e)) null else throw e
    }

    public companion object {
        public const val BASE: String = "https://v3-cinemeta.strem.io"

        internal val MediaMetadata.Kind.cinemetaType: String get() = if (this == MediaMetadata.Kind.movie) "movie" else "series"

        internal fun parseSearch(json: LenientObject): List<SearchResult> = json.objects("metas").mapNotNull { m ->
            val id = m.string("imdb_id") ?: m.string("id") ?: return@mapNotNull null
            val name = m.string("name") ?: return@mapNotNull null
            SearchResult(id, name, m.string("releaseInfo") ?: m.string("year"), m.string("poster"), m.string("background"))
        }

        /** Minimal metadata from a search hit (when `/meta` has nothing for it). */
        internal fun map(result: SearchResult, kind: MediaMetadata.Kind, fetchedAt: Long = System.currentTimeMillis()): MediaMetadata =
            MediaMetadata(kind = kind, source = "Cinemeta", title = result.name, fetchedAt = fetchedAt,
                imdbId = result.id.takeIf { it.startsWith("tt") },
                year = MetadataFormat.displayYear(result.releaseInfo, kind),
                posterURL = upgradedPoster(result.poster),
                backdropURL = result.background)

        internal fun bestMatch(query: TitleMatcher.Query, results: List<SearchResult>, kind: MediaMetadata.Kind): Pair<Int, Double>? {
            val candidates = results.map { r ->
                val (start, end) = TitleMatcher.parseYearRange(r.releaseInfo)
                TitleMatcher.Candidate(listOf(r.name), start, end)
            }
            return TitleMatcher.bestMatch(query, candidates, kind)
        }

        internal fun isSearchable(title: String): Boolean {
            // Apple folding without case: accents off Latin, Greek and Cyrillic letters, full width narrowed.
            val folded = ChannelNameNormalizer.foldKeepingCase(title)
            val letters = folded.codePoints().filter { Character.isLetter(it) }.toArray()
            if (letters.isEmpty()) return folded.codePoints().anyMatch { Character.getType(it).toByte().let { t ->
                t == Character.DECIMAL_DIGIT_NUMBER || t == Character.LETTER_NUMBER || t == Character.OTHER_NUMBER } }
            return letters.any { it < 0x80 }
        }

        internal fun map(m: LenientObject, kind: MediaMetadata.Kind, fetchedAt: Long = System.currentTimeMillis()): MediaMetadata? {
            val name = m.string("name") ?: return null
            var genres = m.stringList("genres")
            if (genres.isEmpty()) genres = m.stringList("genre")
            return MediaMetadata(
                kind = kind, source = "Cinemeta", title = name, fetchedAt = fetchedAt,
                imdbId = listOfNotNull(m.string("imdb_id"), m.string("id")).firstOrNull { it.startsWith("tt") },
                tmdbId = m.string("moviedb_id"),
                year = MetadataFormat.displayYear(m.string("releaseInfo") ?: m.string("year") ?: m.string("released"), kind),
                overview = m.string("description"),
                posterURL = upgradedPoster(m.string("poster")),
                backdropURL = m.string("background"),
                logoURL = m.string("logo"),
                genres = genres,
                runtimeMinutes = MetadataFormat.minutes(m.string("runtime")),
                rating = MetadataFormat.rating(m.double("imdbRating")),
                releaseDate = MetadataFormat.isoDay(m.string("released")),
                country = m.string("country"),
                cast = m.stringList("cast").map { CastMember(it) },
                directors = m.stringList("director"),
                writers = m.stringList("writer"),
                trailerYouTubeId = trailer(m),
                episodes = if (kind == MediaMetadata.Kind.series) episodes(m) else emptyList(),
            )
        }

        /** metahub "small" posters are 300×450; "large" stays sharp. IMDb's Amazon posters: ask for 780 px wide. */
        internal fun upgradedPoster(url: String?): String? {
            if (url == null) return null
            if (url.contains("metahub.space/poster/")) return url.replace("/poster/small/", "/poster/large/").replace("/poster/medium/", "/poster/large/")
            if (url.contains("media-amazon.com")) return url.replace(Regex("""\._V1_[^/]*\.jpg$"""), "._V1_SX780.jpg")
            return url
        }

        internal fun trailer(m: LenientObject): String? {
            val trailers = m.objects("trailers")
            val t = trailers.firstOrNull { it.string("type")?.lowercase() == "trailer" } ?: trailers.firstOrNull()
            t?.string("source")?.let { return it }
            return m.objects("trailerStreams").firstNotNullOfOrNull { it.string("ytId") }
        }

        internal fun episodes(m: LenientObject): List<EpisodeMetadata> {
            val seen = HashSet<String>()
            val out = mutableListOf<EpisodeMetadata>()
            for (v in m.objects("videos")) {
                val season = v.int("season") ?: continue
                val number = v.int("episode") ?: v.int("number") ?: continue
                if (!seen.add("${season}x$number")) continue
                out += EpisodeMetadata(
                    season = season, episode = number,
                    title = v.string("name") ?: v.string("title"),
                    overview = v.string("overview") ?: v.string("description"),
                    stillURL = v.string("thumbnail"),
                    airDate = MetadataFormat.isoDay(v.string("firstAired") ?: v.string("released")),
                    rating = MetadataFormat.rating(v.double("rating")),
                )
            }
            return out.sortedWith(compareBy({ it.season }, { it.episode }))
        }
    }
}
