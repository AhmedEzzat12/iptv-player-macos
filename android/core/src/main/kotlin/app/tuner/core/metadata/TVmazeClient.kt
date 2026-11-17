// Port of Sources/TunerCore/Metadata/TVmazeClient.swift @ 666f598
package app.tuner.core.metadata

import app.tuner.core.net.LenientObject
import app.tuner.core.net.urlPathEncoded

/**
 * TVmaze's public API (no key; data CC BY-SA, credited in the UI) as a second source of episode pictures: Cinemeta lists
 * a still for every episode, but its image host has none for many later seasons.
 */
public class TVmazeClient(private val fetch: MetadataFetch) {
    public data class Episode(val season: Int, val episode: Int, val imageURL: String?)

    /** The show's numbered episodes, or [] when TVmaze doesn't know this IMDb id. Throws on network/server errors. */
    public suspend fun episodes(imdbId: String): List<Episode> {
        val show = try {
            fetch("$BASE/lookup/shows?imdb=${imdbId.urlPathEncoded}", emptyMap()) // redirects to /shows/{id}
        } catch (e: Exception) {
            if (MetadataHTTP.isNotFound(e)) return emptyList() else throw e
        }
        val id = show.int("id") ?: return emptyList()
        return parseEpisodes(fetch("$BASE/shows/$id?embed=episodes", emptyMap()))
    }

    public companion object {
        public const val BASE: String = "https://api.tvmaze.com"

        /** Episodes from a `/shows/{id}?embed=episodes` body; specials without an episode number are dropped. */
        internal fun parseEpisodes(show: LenientObject): List<Episode> =
            (show.obj("_embedded")?.objects("episodes") ?: emptyList()).mapNotNull { e ->
                val season = e.int("season") ?: return@mapNotNull null
                val number = e.int("number") ?: return@mapNotNull null
                val image = e.obj("image")
                Episode(season, number, image?.string("original") ?: image?.string("medium"))
            }

        /**
         * Adds TVmaze pictures as fallbacks (or as the still, when an episode has none). A season is only used when both
         * sources count the same episodes in it: a mismatched picture is worse than none.
         */
        internal fun addFallbackStills(episodes: List<EpisodeMetadata>, tvmaze: List<Episode>): List<EpisodeMetadata> {
            val ownCounts = episodes.groupingBy { it.season }.eachCount()
            val theirCounts = tvmaze.groupingBy { it.season }.eachCount()
            val pictures = HashMap<Int, HashMap<Int, String>>()
            for (e in tvmaze) {
                val url = e.imageURL ?: continue
                if (ownCounts[e.season] != theirCounts[e.season]) continue
                pictures.getOrPut(e.season) { HashMap() }[e.episode] = url
            }
            return episodes.map { episode ->
                val picture = pictures[episode.season]?.get(episode.episode)
                when {
                    picture == null || picture == episode.stillURL -> episode
                    episode.stillURL == null -> episode.copy(stillURL = picture)
                    else -> episode.copy(fallbackStillURL = picture)
                }
            }
        }
    }
}
