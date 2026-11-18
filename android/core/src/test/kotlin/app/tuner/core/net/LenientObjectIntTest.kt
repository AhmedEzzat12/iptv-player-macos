package app.tuner.core.net

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class LenientObjectIntTest {
    private fun obj(json: String) = LenientObject.of(Json.parseToJsonElement(json) as JsonObject)!!

    @Test fun truncatesFractionsTowardZero() {
        val o = obj("""{"a": 3.7, "b": "-3.7", "c": "42"}""")
        assertEquals(3, o.int("a"))
        assertEquals(-3, o.int("b"))
        assertEquals(42, o.int("c"))
    }

    @Test fun numbersBeyondIntAreNullNotWrapped() {
        val o = obj("""{"n": 3000000000, "s": "3000000000", "neg": -3000000000, "big": "1e30", "nan": "nan"}""")
        assertNull(o.int("n"))
        assertNull(o.int("s"))
        assertNull(o.int("neg"))
        assertNull(o.int("big"))
        assertNull(o.int("nan"))
    }
}
