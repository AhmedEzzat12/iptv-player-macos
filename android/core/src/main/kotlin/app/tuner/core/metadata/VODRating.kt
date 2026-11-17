// Port of VODEnrichment.rating / ratingSource (Sources/Tuner/Views/VOD/VODCards.swift)
package app.tuner.core.metadata

/** A rating and where it comes from: "IMDb", "TMDB", or null for the provider's own unlabelled rating. */
public data class VODRating(val source: String?, val value: Double) {
    /** "IMDb 8.0", or "★ 7.4" for an unlabelled rating. */
    val text: String get() = if (source != null) "$source ${"%.1f".format(java.util.Locale.ROOT, value)}" else "★ ${"%.1f".format(java.util.Locale.ROOT, value)}"

    public companion object {
        /** The metadata's rating with its source (it wins: providers' ratings are unlabelled and often made up), else
         * the provider's. */
        public fun of(provider: Double?, metadata: MediaMetadata?): VODRating? {
            val r = metadata?.rating
            if (metadata != null && r != null && r > 0) return VODRating(sourceLabel(metadata), r)
            if (provider != null && provider > 0) return VODRating(null, provider)
            return null
        }

        /** "IMDb" for Cinemeta, whose ratings are IMDb's. */
        public fun sourceLabel(metadata: MediaMetadata): String = when (metadata.source.lowercase()) {
            "cinemeta", "imdb" -> "IMDb"
            "tmdb", "themoviedb" -> "TMDB"
            else -> metadata.source
        }
    }
}
