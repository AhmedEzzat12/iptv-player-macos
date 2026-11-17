// Port of TitleParser in Sources/TunerCore/Parsing/M3UParser.swift @ 666f598
package app.tuner.core.parsing

import app.tuner.core.models.toIntStrict
import app.tuner.core.nilIfEmpty
import java.util.regex.Pattern

/** Heuristics for VOD titles. Patterns use Unicode classes, as ICU does in Swift. */
public object TitleParser {
    /** A year in brackets anywhere: "Title (2024)", "Title ( 2026 ) Pure", "Title [2019]". */
    private val bracketYear = UnicodeRegex.compile("""[(\[]\s*((?:19|20)\d{2})\s*[)\]]""")

    /** A trailing year after an explicit separator: "Title - 2024", "Title.2024". "Blade Runner 2049" is not a year. */
    private val separatedYear = UnicodeRegex.compile("""^(.*?)(?:\s+-\s+|\.)((?:19|20)\d{2})\s*$""")

    private val episodePattern = UnicodeRegex.compile(
        """^(.*?)[\s._\-]*S(\d{1,2})[\s._\-]*E(\d{1,3})(?:[\s._\-]+(.*))?$""", caseInsensitive = true)

    public data class Episode(val show: String, val season: Int, val episode: Int, val title: String?)

    public fun splitYear(name: String): Pair<String, String?> {
        val m = bracketYear.matcher(name)
        if (m.find()) {
            val year = m.group(1)
            var title = name.removeRange(m.start(), m.end())
            title = title.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            title = title.trim(' ', '-', '_', '.')
            return if (title.isEmpty()) name to year else title to year
        }
        val s = separatedYear.matcher(name)
        if (s.find()) {
            val title = s.group(1).trim()
            if (title.isNotEmpty()) return title to s.group(2)
        }
        return name to null
    }

    public fun episodeInfo(name: String): Episode? {
        val m = episodePattern.matcher(name)
        if (!m.find()) return null
        val season = m.group(2).toIntStrict() ?: return null
        val episode = m.group(3).toIntStrict() ?: return null
        val show = m.group(1).trim(' ', '-', '_', '.')
        if (show.isEmpty()) return null
        return Episode(show, season, episode, m.group(4).nilIfEmpty())
    }
}
