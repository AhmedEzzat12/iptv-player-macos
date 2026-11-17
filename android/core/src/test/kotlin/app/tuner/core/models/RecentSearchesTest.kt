package app.tuner.core.models

import kotlin.test.Test
import kotlin.test.assertEquals

class RecentSearchesTest {
    @Test fun newestFirstWithoutCaseInsensitiveDuplicates() {
        assertEquals(listOf("Batman", "dune"), RecentSearches.remember(listOf("dune", "batman"), "  Batman "))
    }

    @Test fun shortQueriesAreNotKept() {
        assertEquals(listOf("dune"), RecentSearches.remember(listOf("dune"), "b"))
    }

    @Test fun keepsOnlyTheLimit() {
        val full = (1..12).map { "query $it" }
        val out = RecentSearches.remember(full, "new")
        assertEquals(12, out.size)
        assertEquals("new", out.first())
        assertEquals("query 11", out.last())
    }
}
