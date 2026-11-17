package app.tuner.core.parsing

import java.util.regex.Pattern

/**
 * Compiles a pattern with Unicode-aware `\s`, `\d`, `\w` and case folding, like Swift's ICU regexes. Android's regex
 * engine is ICU already and rejects `Pattern.UNICODE_CHARACTER_CLASS`; the desktop JVM (core's tests) needs the flag.
 */
internal object UnicodeRegex {
    private val supported: Boolean = runCatching { Pattern.compile("a", Pattern.UNICODE_CHARACTER_CLASS) }.isSuccess

    fun compile(pattern: String, caseInsensitive: Boolean = false): Pattern {
        var flags = if (caseInsensitive) Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE else 0
        if (supported) flags = flags or Pattern.UNICODE_CHARACTER_CLASS
        return Pattern.compile(pattern, flags)
    }
}
