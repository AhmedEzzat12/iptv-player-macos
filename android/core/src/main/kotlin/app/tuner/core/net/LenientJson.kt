// Port of Sources/TunerCore/Networking/LenientJSON.swift @ 666f598
package app.tuner.core.net

import app.tuner.core.models.toIntStrict
import app.tuner.core.nilIfEmpty
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import java.math.BigDecimal
import java.time.Instant

/**
 * Accessors for the loosely-typed JSON IPTV panels return, where the same field can be a number, a numeric string,
 * `null`, `""` or missing depending on the server build. Semantics match Swift's `JSONObject` (checked by vectors).
 */
public class LenientObject(public val raw: JsonObject) {
    public operator fun get(key: String): JsonElement? = raw[key]

    private fun primitive(key: String): JsonPrimitive? = (raw[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }

    /** Non-blank strings; numbers as integers when integral ("1.0" → "1"); booleans as "1"/"0" (NSNumber). */
    public fun string(key: String): String? {
        val p = primitive(key) ?: return null
        if (p.isString) return p.content.nilIfEmpty()
        p.booleanOrNull?.let { return if (it) "1" else "0" }
        val d = p.doubleOrNull ?: return null
        if (d != Math.rint(d) || d.isInfinite()) return BigDecimal(p.content).stripTrailingZeros().toPlainString()
        return BigDecimal(p.content).toLong().toString()
    }

    public fun int(key: String): Int? {
        val p = primitive(key) ?: return null
        if (p.isString) {
            val t = p.content.trim(' ', '\t')
            // Truncate "3.7" to 3; "nan", "inf" and values beyond Swift's Int range ("1e30") are null, as in Swift.
            return t.toIntStrict() ?: t.toSwiftDouble()?.let(::wholeInt)
        }
        p.booleanOrNull?.let { return if (it) 1 else 0 }
        return p.doubleOrNull?.let(::wholeInt)
    }

    /** `d` truncated toward zero, or null when it isn't finite or doesn't fit in Kotlin's 32-bit Int (`toLong().toInt()`
     * wrapped 3000000000 to a negative number; Swift's 64-bit Int keeps it, so null is the closest honest answer). */
    private fun wholeInt(d: Double): Int? {
        val whole = if (d < 0) kotlin.math.ceil(d) else kotlin.math.floor(d)
        return if (!whole.isFinite() || whole < Int.MIN_VALUE || whole > Int.MAX_VALUE) null else whole.toInt()
    }

    public fun double(key: String): Double? {
        val p = primitive(key) ?: return null
        if (p.isString) return p.content.trim(' ', '\t').toSwiftDouble()
        p.booleanOrNull?.let { return if (it) 1.0 else 0.0 }
        return p.doubleOrNull
    }

    public fun bool(key: String): Boolean {
        val p = primitive(key) ?: return false
        if (p.isString) return p.content == "1" || p.content.lowercase() == "true"
        p.booleanOrNull?.let { return it }
        return (p.doubleOrNull?.toLong() ?: 0L).toInt() != 0
    }

    public fun obj(key: String): LenientObject? = (raw[key] as? JsonObject)?.let(::LenientObject)

    public fun array(key: String): List<JsonElement> = (raw[key] as? JsonArray) ?: emptyList()

    /** Unix timestamp (seconds) stored as number or string. */
    public fun date(key: String): Instant? {
        val v = double(key) ?: return null
        if (!(v > 0) || !v.isFinite()) return null
        return Instant.ofEpochMilli((v * 1000).toLong())
    }

    public companion object {
        public fun of(element: JsonElement?): LenientObject? = (element as? JsonObject)?.let(::LenientObject)
    }
}

/**
 * Swift `Double(String)`: decimal, exponent and hex (`0x10`, `0x1p3`) forms, "inf"/"infinity"/"nan" in any case; no
 * surrounding spaces.
 */
internal fun String.toSwiftDouble(): Double? {
    if (isEmpty()) return null
    val body = removePrefix("+").removePrefix("-")
    val sign = if (startsWith("-")) -1.0 else 1.0
    when (body.lowercase()) {
        "inf", "infinity" -> return sign * Double.POSITIVE_INFINITY
        "nan" -> return Double.NaN
    }
    if (body.startsWith("0x") || body.startsWith("0X")) {
        val hex = body.substring(2)
        if (hex.isEmpty() || !hex.all { it.isLetterOrDigit() && it < '\u0080' || it == '.' || it == 'p' || it == 'P' || it == '+' || it == '-' }) return null
        val withExponent = if (hex.contains('p') || hex.contains('P')) hex else hex + "p0"
        return runCatching { sign * java.lang.Double.parseDouble("0x$withExponent") }.getOrNull()
    }
    if (body.isEmpty() || !body.all { it.isDigit() && it < '\u0080' || it == '.' || it == 'e' || it == 'E' || it == '+' || it == '-' }) return null
    return toDoubleOrNull()
}

public object LenientJson {
    /**
     * Normalises list responses: `[...]` → objects; `{}` → []; a single object → [object]; `{"1": {...}, "2": {...}}`
     * keyed dictionaries → their values in numeric key order.
     */
    public fun objects(element: JsonElement?): List<LenientObject> = when (element) {
        is JsonArray -> element.mapNotNull { LenientObject.of(it) }
        is JsonObject -> when {
            element.isEmpty() -> emptyList()
            element.values.all { it is JsonObject } && element.keys.all { it.toIntStrict() != null } ->
                element.entries.sortedBy { it.key.toIntStrict() ?: 0 }.map { LenientObject(it.value as JsonObject) }
            else -> listOf(LenientObject(element))
        }
        else -> emptyList()
    }
}
