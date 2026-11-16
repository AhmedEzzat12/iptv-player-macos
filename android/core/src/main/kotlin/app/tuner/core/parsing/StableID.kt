// Port of Sources/TunerCore/Parsing/StableID.swift @ 666f598
package app.tuner.core.parsing

/** Deterministic identifiers so favourites, hidden flags and EPG overrides survive resyncs. Must match Swift exactly. */
public object StableID {
    /** DJB2 over the UTF-8 bytes (wrapping Int32, absolute value, base-36, max 8 chars), same scheme as ynotv. */
    public fun hash(string: String): String {
        var h = 5381
        for (b in string.toByteArray(Charsets.UTF_8)) {
            h = h * 33 + (b.toInt() and 0xFF) // bytes are unsigned in Swift; Int wraps like &* / &+
        }
        val magnitude: Long = if (h == Int.MIN_VALUE) 2_147_483_648L else kotlin.math.abs(h).toLong()
        return magnitude.toString(36).take(8)
    }

    /** Replaces anything outside `[A-Za-z0-9._-]` with `_`, one `_` per code point. */
    public fun sanitize(string: String): String {
        val out = StringBuilder(string.length)
        string.codePoints().forEach { cp ->
            val keep = cp in 'a'.code..'z'.code || cp in 'A'.code..'Z'.code || cp in '0'.code..'9'.code ||
                cp == '.'.code || cp == '_'.code || cp == '-'.code
            if (keep) out.appendCodePoint(cp) else out.append('_')
        }
        return out.toString()
    }

    /** Lowercased slug keeping Unicode letters, marks and numbers; runs of anything else become one `-`. */
    public fun slug(string: String): String {
        val out = StringBuilder()
        var lastWasDash = false
        string.lowercase().codePoints().forEach { cp ->
            if (isAlphanumeric(cp)) {
                out.appendCodePoint(cp)
                lastWasDash = false
            } else if (!lastWasDash && out.isNotEmpty()) {
                out.append('-')
                lastWasDash = true
            }
        }
        while (out.endsWith("-")) out.setLength(out.length - 1)
        return if (out.isEmpty()) "category-${hash(string)}" else out.toString()
    }

    /** Apple's `CharacterSet.alphanumerics`: general categories L*, M* and N*. */
    internal fun isAlphanumeric(cp: Int): Boolean = when (Character.getType(cp).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER, Character.MODIFIER_LETTER,
        Character.OTHER_LETTER, Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK,
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }
}

/** Builds unique channel ids for one M3U source during a parse. */
internal class M3UChannelIDAllocator(private val sourceId: String) {
    private val used = HashSet<String>()

    fun allocate(tvgId: String?, url: String): String {
        val base: String
        val tvg = tvgId?.trim()?.takeIf { it.isNotEmpty() }
        if (tvg != null) {
            val primary = "${sourceId}_${StableID.sanitize(tvg)}"
            if (used.add(primary)) return primary
            base = "${primary}_${StableID.hash(url)}"
        } else {
            base = "${sourceId}_url_${StableID.hash(url)}"
        }
        if (used.add(base)) return base
        var n = 2
        while (!used.add("${base}_$n")) n++
        return "${base}_$n"
    }
}
