// Port of Sources/TunerCore/Parsing/ChannelNameNormalizer.swift @ 666f598
package app.tuner.core.parsing

import java.text.Normalizer
import java.util.regex.Pattern

/**
 * Normalises channel names so a playlist entry like "US| CNN HD ᴴᴰ" matches an XMLTV display name such as "CNN", and
 * duplicate channels across sources can be grouped. Checked against Tests/Vectors/normalizer (generated from Swift).
 */
public object ChannelNameNormalizer {
    /**
     * Quality/packaging tokens that never distinguish one channel from another. Deliberately NOT included: "plus"
     * (Canal+ ≠ Canal), "east"/"west" (different schedules), "live" (often part of a distinct channel name).
     */
    internal val noiseTokens: Set<String> = setOf(
        "hd", "fhd", "uhd", "qhd", "sd", "4k", "8k", "hevc", "h265", "h264", "x265", "x264", "1080p", "1080i",
        "1080", "720p", "720", "576p", "2160p", "50fps", "60fps", "fps", "hdr", "raw", "backup", "vip", "tv",
        "ᴴᴰ", "ᵁᴴᴰ", "ʰᵈ", "multi", "multiaudio", "audio",
    )

    /** Common country prefixes like `US:`, `UK |`, `[CA]`, `|DE|`. */
    private val prefixPattern = Pattern.compile("""^\s*[\[(|]?\s*[A-Za-z]{2,3}\s*[\])|:\-]+\s*""", Pattern.UNICODE_CHARACTER_CLASS)
    private val bracketPattern = Pattern.compile("""[\[({][^\])}]*[\])}]""")

    public fun normalize(name: String): String {
        var s = fold(name)
        s = prefixPattern.matcher(s).replaceFirst("")
        s = bracketPattern.matcher(s).replaceAll(" ")
        s = s.replace("&", " and ").replace("+", " plus ")

        val tokens = ArrayList<String>()
        val current = StringBuilder()
        s.codePoints().forEach { cp ->
            when {
                isLetterOrNumber(cp) -> current.appendCodePoint(cp)
                // A combining mark belongs to the character before it (Swift iterates grapheme clusters).
                isMark(cp) && current.isNotEmpty() -> current.appendCodePoint(cp)
                current.isNotEmpty() -> { tokens.add(current.toString()); current.setLength(0) }
            }
        }
        if (current.isNotEmpty()) tokens.add(current.toString())

        val meaningful = tokens.filter { it !in noiseTokens }
        // Never normalise a name to nothing ("HD" alone keeps its token).
        return (meaningful.ifEmpty { tokens }).joinToString("")
    }

    /**
     * Apple's `folding([.diacriticInsensitive, .caseInsensitive, .widthInsensitive])`: accents removed from Latin,
     * Greek and Cyrillic letters only (Arabic harakat, hamza and Japanese dakuten survive, as the vectors show),
     * lowercased, full-width forms narrowed.
     */
    internal fun fold(s: String): String {
        val decomposed = Normalizer.normalize(s, Normalizer.Form.NFD)
        val out = StringBuilder(decomposed.length)
        var baseScript: Character.UnicodeScript? = null
        decomposed.codePoints().forEach { cp ->
            if (Character.getType(cp).toByte() == Character.NON_SPACING_MARK) {
                if (baseScript !in STRIPPED_SCRIPTS) out.appendCodePoint(cp)
            } else {
                baseScript = Character.UnicodeScript.of(cp)
                out.appendCodePoint(narrow(cp))
            }
        }
        return Normalizer.normalize(out, Normalizer.Form.NFC).lowercase()
    }

    private val STRIPPED_SCRIPTS = setOf(
        Character.UnicodeScript.LATIN, Character.UnicodeScript.GREEK, Character.UnicodeScript.CYRILLIC,
    )

    private fun narrow(cp: Int): Int = when (cp) {
        in 0xFF01..0xFF5E -> cp - 0xFEE0
        0x3000 -> 0x20
        else -> cp
    }

    /** Swift `Character.isLetter` (Unicode Alphabetic) or `isNumber` (any numeric type). */
    private fun isLetterOrNumber(cp: Int): Boolean = Character.isAlphabetic(cp) || when (Character.getType(cp).toByte()) {
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }

    private fun isMark(cp: Int): Boolean = when (Character.getType(cp).toByte()) {
        Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK -> true
        else -> false
    }
}
