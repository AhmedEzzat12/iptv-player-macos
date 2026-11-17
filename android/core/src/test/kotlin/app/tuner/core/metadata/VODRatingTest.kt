package app.tuner.core.metadata

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class VODRatingTest {
    private fun meta(source: String, rating: Double?) = MediaMetadata(kind = MediaMetadata.Kind.movie, source = source, title = "T", rating = rating)

    @Test fun metadataRatingWinsWithItsSource() {
        assertEquals("IMDb 8.1", VODRating.of(6.0, meta("Cinemeta", 8.1))?.text)
        assertEquals("TMDB 7.0", VODRating.of(null, meta("TMDB", 7.0))?.text)
    }

    @Test fun providerRatingIsUnlabelled() {
        assertEquals("★ 6.5", VODRating.of(6.5, meta("Cinemeta", null))?.text)
        assertEquals("★ 6.5", VODRating.of(6.5, null)?.text)
    }

    @Test fun noRatingAtAll() {
        assertNull(VODRating.of(0.0, meta("TMDB", 0.0)))
        assertNull(VODRating.of(null, null))
    }
}
