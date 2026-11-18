package app.tuner.core.models

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class VODItemTest {
    private fun movie(id: String, poster: String? = "p", backdrop: String? = null) =
        Movie(id, "src", null, "Movie $id", id, providerOrder = 0, posterURL = poster, backdropURL = backdrop)
    private fun show(id: String, cover: String? = "c") = Series(id, "src", null, "Show $id", id, providerOrder = 0, coverURL = cover)

    @Test fun heroAlternatesMoviesAndShows() {
        val picks = VODItem.heroPicks(listOf(movie("1"), movie("2"), movie("3")), listOf(show("a")))
        assertEquals(listOf("m:1", "s:a", "m:2", "m:3"), picks.map { it.id })
    }

    @Test fun heroSkipsTitlesWithoutArtworkAndKeepsSix() {
        val movies = (1..8).map { movie("$it") } + movie("bare", poster = null)
        val picks = VODItem.heroPicks(listOf(movie("bare", poster = null)) + movies, listOf(show("x", cover = "")))
        assertEquals(6, picks.size)
        assertEquals("m:1", picks.first().id)
    }

    @Test fun backdropAloneCountsAsArtwork() {
        assertEquals(listOf("m:1"), VODItem.heroPicks(listOf(movie("1", poster = null, backdrop = "b")), emptyList()).map { it.id })
    }

    @Test fun metadataLine() {
        val m = movie("1").copy(year = "0", releaseDate = "2019-05-01", genre = "Drama / Crime / Thriller", rating = 7.44)
        assertEquals("2019 · Drama, Crime · ★ 7.4", VODItem.MovieItem(m).metadataLine)
        assertEquals("", VODItem.MovieItem(movie("2").copy(rating = 0.0)).metadataLine)
    }

    @Test fun yearFallsBackToReleaseDateDigits() {
        assertEquals("2008", VODFormat.year("2008-01", null))
        assertNull(VODFormat.year(null, "TBA 2020"))
    }
}
