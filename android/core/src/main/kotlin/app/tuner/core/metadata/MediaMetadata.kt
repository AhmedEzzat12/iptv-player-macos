// Port of Sources/TunerCore/Metadata/MediaMetadata.swift @ 666f598
package app.tuner.core.metadata

import kotlinx.serialization.Serializable

/** A cast member as shown on detail pages. */
@Serializable
public data class CastMember(val name: String, val character: String? = null, val photoURL: String? = null)

/** Per-episode artwork and text from the online catalogue (matched to provider episodes by season/number). */
@Serializable
public data class EpisodeMetadata(
    val season: Int,
    val episode: Int,
    val title: String? = null,
    val overview: String? = null,
    val stillURL: String? = null,
    /** A second picture source, tried when `stillURL` doesn't load (Cinemeta lists stills that don't exist). */
    val fallbackStillURL: String? = null,
    val airDate: String? = null,
    val rating: Double? = null,
)

/** Rich metadata for a movie or series from an online catalogue (Cinemeta or TMDB). Cached as JSON. */
@Serializable
public data class MediaMetadata(
    var kind: Kind,
    /** Human-readable source, e.g. "Cinemeta" or "TMDB". */
    var source: String,
    var title: String,
    /** Epoch milliseconds. */
    var fetchedAt: Long = System.currentTimeMillis(),
    var imdbId: String? = null,
    var tmdbId: String? = null,
    var originalTitle: String? = null,
    var year: String? = null,
    var overview: String? = null,
    var tagline: String? = null,
    var posterURL: String? = null,
    var backdropURL: String? = null,
    /** Transparent title artwork (used instead of text on heroes, like the TV app). */
    var logoURL: String? = null,
    var genres: List<String> = emptyList(),
    var runtimeMinutes: Int? = null,
    /** 0–10 (IMDb or TMDB vote average). */
    var rating: Double? = null,
    var releaseDate: String? = null,
    var country: String? = null,
    var cast: List<CastMember> = emptyList(),
    var directors: List<String> = emptyList(),
    var writers: List<String> = emptyList(),
    var trailerYouTubeId: String? = null,
    var episodes: List<EpisodeMetadata> = emptyList(),
) {
    @Serializable
    public enum class Kind { movie, series }

    public fun episode(season: Int, number: Int): EpisodeMetadata? = episodes.firstOrNull { it.season == season && it.episode == number }
}

/** User-facing metadata configuration. */
public data class MetadataSettings(
    /** Master switch for online lookups (cached results are still shown when off). */
    val enabled: Boolean = true,
    /** Optional TMDB API key (v3 key or v4 read-access token). When set, TMDB is preferred over Cinemeta. */
    val tmdbAPIKey: String? = null,
    /** BCP-47 language for TMDB text, e.g. "en-US". */
    val language: String = "en-US",
)
