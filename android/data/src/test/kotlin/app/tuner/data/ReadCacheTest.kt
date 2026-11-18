package app.tuner.data

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ReadCacheTest {
    private val library = arrayOf(Change.LIBRARY)
    private val user = arrayOf(Change.USER)

    @Test fun keepsAReadUntilAWriteItDependsOn() {
        val cache = ReadCache()
        cache.put("movies", listOf("a"), library, cache.generation(library))
        cache.put("progress", listOf("p"), user, cache.generation(user))
        cache.invalidate(Change.USER)
        assertEquals(listOf("a"), cache.get<List<String>>("movies"))
        assertNull(cache.get<List<String>>("progress"))
        cache.invalidate(Change.LIBRARY)
        assertNull(cache.get<List<String>>("movies"))
    }

    @Test fun aReadThatStartedBeforeAWriteIsNotStored() {
        val cache = ReadCache()
        val before = cache.generation(library)
        cache.invalidate(Change.LIBRARY) // the write lands while the read is still running
        cache.put("movies", listOf("stale"), library, before)
        assertNull(cache.get<List<String>>("movies"))
    }

    @Test fun dropsTheLeastRecentlyUsedPastCapacity() {
        val cache = ReadCache(capacity = 2)
        cache.put("a", 1, library, 0)
        cache.put("b", 2, library, 0)
        cache.get<Int>("a")
        cache.put("c", 3, library, 0)
        assertEquals(1, cache.get<Int>("a"))
        assertNull(cache.get<Int>("b"))
    }
}

class TimedCacheTest {
    @Test fun entriesExpire() {
        var now = 0L
        val cache = TimedCache<String, String>(capacity = 4, ttlMillis = 100) { now }
        cache.put("a", "x")
        now = 100
        assertEquals("x", cache.get("a"))
        now = 101
        assertNull(cache.get("a"))
    }
}
