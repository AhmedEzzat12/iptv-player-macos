// Port of Sources/TunerCore/Models/VOD.swift @ 666f598
package app.tuner.core.models

import java.time.Instant

public data class Movie(
    var id: String,
    var sourceId: String,
    var categoryId: String?,
    var name: String,
    /** Raw provider id (Xtream stream_id / Stalker video id). */
    var providerId: String,
    /** Direct URL (M3U VOD / Stalker locator); empty for Xtream (built at play time). */
    var streamURL: String = "",
    var providerOrder: Int,
    var year: String? = null,
    var posterURL: String? = null,
    var backdropURL: String? = null,
    var containerExtension: String? = null,
    var rating: Double? = null,
    var plot: String? = null,
    var genre: String? = null,
    var cast: String? = null,
    var director: String? = null,
    var releaseDate: String? = null,
    var durationSeconds: Int? = null,
    var addedAt: Instant? = null,
    var trailer: String? = null,
    var tmdbId: String? = null,
)

public data class Series(
    var id: String,
    var sourceId: String,
    var categoryId: String?,
    var name: String,
    var providerId: String,
    /** Stalker playback command for the series (episodes resolve from it). */
    var streamURL: String = "",
    var providerOrder: Int,
    var year: String? = null,
    var coverURL: String? = null,
    var backdropURL: String? = null,
    var rating: Double? = null,
    var plot: String? = null,
    var genre: String? = null,
    var cast: String? = null,
    var director: String? = null,
    var releaseDate: String? = null,
    var addedAt: Instant? = null,
    var lastModified: Instant? = null,
    var trailer: String? = null,
)

public data class Episode(
    var id: String,
    var seriesId: String,
    var sourceId: String,
    var season: Int,
    var number: Int,
    var title: String,
    var providerId: String,
    var streamURL: String = "",
    var plot: String? = null,
    var imageURL: String? = null,
    var durationSeconds: Int? = null,
    var containerExtension: String? = null,
    var airDate: String? = null,
) {
    public val code: String get() = "S%02dE%02d".format(season, number)
}

/** Extra details fetched lazily when a movie or series is opened. */
public data class VODDetails(
    var plot: String? = null,
    var cast: String? = null,
    var director: String? = null,
    var genre: String? = null,
    var releaseDate: String? = null,
    var rating: Double? = null,
    var durationSeconds: Int? = null,
    var backdropURL: String? = null,
    var posterURL: String? = null,
    var trailer: String? = null,
    var containerExtension: String? = null,
    var tmdbId: String? = null,
    var episodes: MutableList<Episode> = mutableListOf(),
)

public enum class MediaKind(public val raw: String) {
    MOVIE("movie"), EPISODE("episode"), CHANNEL("channel");

    public companion object {
        public fun of(raw: String): MediaKind? = entries.firstOrNull { it.raw == raw }
    }
}

/** Resume position for movies and episodes. */
public data class WatchProgress(
    var mediaId: String,
    var kind: MediaKind,
    var sourceId: String,
    var seriesId: String? = null,
    var title: String,
    var subtitle: String? = null,
    var posterURL: String? = null,
    var position: Double,
    var duration: Double,
    var completed: Boolean = false,
    var updatedAt: Instant = Instant.now(),
) {
    public val id: String get() = mediaId
    public val fraction: Double get() = if (duration > 0) (position / duration).coerceIn(0.0, 1.0) else 0.0

    /** Season and episode number parsed from `subtitle` (`"S2, E4 · Title"` or `"Special 3"`). */
    public val episodePosition: Pair<Int, Int>?
        get() {
            val s = subtitle ?: return null
            if (s.startsWith("S")) {
                val rest = s.substring(1)
                val comma = rest.indexOf(',').takeIf { it >= 0 } ?: return null
                val season = rest.substring(0, comma).toIntStrict() ?: return null
                val after = rest.substring(comma + 1).trimStart(' ')
                if (!after.startsWith("E")) return null
                val number = after.substring(1).takeWhile { it.isDigit() }.toIntStrict() ?: return null
                return season to number
            }
            if (s.startsWith("Special ")) {
                val number = s.removePrefix("Special ").takeWhile { it.isDigit() }.toIntStrict() ?: return null
                return 0 to number
            }
            return null
        }

    public companion object {
        /** Matches ynotv: ≥90% watched or within 5 s of the end counts as finished. */
        public fun isComplete(position: Double, duration: Double): Boolean {
            if (duration <= 0) return false
            return position / duration >= 0.9 || duration - position <= 5
        }
    }
}

/** Swift `Int(String)`: optional sign, ASCII digits only, no spaces. */
internal fun String.toIntStrict(): Int? = if (isNotEmpty() && all { it in '0'..'9' || it == '-' || it == '+' }) toIntOrNull() else null

public data class CustomGroup(var id: String, var name: String, var sortIndex: Int)
