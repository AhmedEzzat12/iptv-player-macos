// Port of VODItem, VODFormat.year/genres and HomeView.heroPicks (Sources/Tuner/Views/VOD/VODCards.swift, HomeView.swift).
// They live in the Apple app target; here they sit in core so the rules are tested.
package app.tuner.core.models

/** A movie or a show, as the Home hero and mixed rows (Top Rated) show them. */
public sealed class VODItem {
    public data class MovieItem(val movie: Movie) : VODItem()
    public data class SeriesItem(val series: Series) : VODItem()

    /** Unique across both kinds ("m:<id>", "s:<id>"). */
    public val id: String get() = when (this) { is MovieItem -> "m:${movie.id}"; is SeriesItem -> "s:${series.id}" }
    /** Database id (favourites, progress). */
    public val mediaId: String get() = when (this) { is MovieItem -> movie.id; is SeriesItem -> series.id }
    public val title: String get() = when (this) { is MovieItem -> movie.name; is SeriesItem -> series.name }
    public val year: String? get() = when (this) {
        is MovieItem -> VODFormat.year(movie.year, movie.releaseDate)
        is SeriesItem -> VODFormat.year(series.year, series.releaseDate)
    }
    public val posterURL: String? get() = when (this) { is MovieItem -> movie.posterURL; is SeriesItem -> series.coverURL }?.ifEmpty { null }
    public val backdropURL: String? get() = when (this) { is MovieItem -> movie.backdropURL; is SeriesItem -> series.backdropURL }?.ifEmpty { null }
    /** Provider rating; zero means "unknown" for most panels. */
    public val rating: Double? get() = when (this) { is MovieItem -> movie.rating; is SeriesItem -> series.rating }?.takeIf { it > 0 }
    public val plot: String? get() = when (this) { is MovieItem -> movie.plot; is SeriesItem -> series.plot }?.ifEmpty { null }
    public val genre: String? get() = when (this) { is MovieItem -> movie.genre; is SeriesItem -> series.genre }?.ifEmpty { null }
    public val isMovie: Boolean get() = this is MovieItem
    public val kindLabel: String get() = if (isMovie) "Movie" else "TV Show"

    /** "2019 · Drama, Crime · ★ 7.4" */
    public val metadataLine: String get() = listOfNotNull(year, VODFormat.genres(genre, 2), rating?.let { "★ ${VODFormat.rating(it)}" }).joinToString(" · ")

    public companion object {
        /**
         * The Home hero: up to six recently added titles with artwork, alternating movies and shows (newest first in
         * each), so the carousel shows both kinds. Order stays stable as details arrive, so the carousel doesn't jump.
         */
        public fun heroPicks(movies: List<Movie>, shows: List<Series>, limit: Int = 6): List<VODItem> {
            val mixed = ArrayList<VODItem>()
            for (i in 0 until maxOf(movies.size, shows.size)) {
                if (i < movies.size) mixed += MovieItem(movies[i])
                if (i < shows.size) mixed += SeriesItem(shows[i])
            }
            return mixed.filter { it.backdropURL != null || it.posterURL != null }.take(limit)
        }
    }
}

public object VODFormat {
    /** The year to show: the provider's year (not "0"), else the release date's first four digits. */
    public fun year(year: String?, releaseDate: String?): String? {
        year?.takeIf { it.isNotEmpty() && it != "0" }?.let { return it.take(4) }
        val y = releaseDate?.takeIf { it.length >= 4 }?.take(4) ?: return null
        return y.takeIf { it.toIntOrNull() != null }
    }

    /** The first `max` genres of a comma, slash or bar separated list. */
    public fun genres(value: String?, max: Int): String? {
        val parts = value?.split(',', '/', '|')?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
        return if (parts.isEmpty()) null else parts.take(max).joinToString(", ")
    }

    public fun rating(value: Double): String = String.format(java.util.Locale.ROOT, "%.1f", value)
}
