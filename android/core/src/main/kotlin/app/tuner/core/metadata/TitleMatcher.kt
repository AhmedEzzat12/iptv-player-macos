// Port of Sources/TunerCore/Metadata/TitleMatcher.swift @ 666f598
package app.tuner.core.metadata

import app.tuner.core.parsing.UnicodeRegex
import app.tuner.core.models.toIntStrict
import app.tuner.core.parsing.ChannelNameNormalizer
import app.tuner.core.parsing.TitleParser
import java.util.Locale
import java.util.regex.Matcher
import java.util.regex.Pattern
import kotlin.math.abs

/**
 * Turns messy IPTV VOD names into catalogue search queries and scores search results against them. A wrong match is
 * worse than none, so a candidate must reach `ACCEPT_SCORE`. Checked against Swift by vectors.
 */
public object TitleMatcher {
    /** A cleaned search query. */
    public data class Query(
        /** Cleaned title used for searching, e.g. "The Matrix". */
        val title: String,
        /** Release year (from the provider's year field, else from the name). */
        val year: Int? = null,
        /** Set when the name ended in a bare year-like number ("Blade Runner 2049"): both readings are scored. */
        val literalTitle: String? = null,
        /** Year that goes with `literalTitle` (only one that came from elsewhere, e.g. the provider field). */
        val literalYear: Int? = null,
    )

    /** A search result to score: its title(s) and year range (series run "2008–2013" → 2008…2013). */
    internal data class Candidate(val titles: List<String>, val year: Int?, val endYear: Int? = null)

    /** Minimum score for a match. Exact title = 1.0; year agreement adds up to 0.15, a clear disagreement −0.35. */
    internal const val ACCEPT_SCORE: Double = 0.85


    /** Cleans an IPTV name (and optional provider year field) into a search query; null when nothing meaningful remains. */
    public fun query(name: String, year: String? = null, kind: MediaMetadata.Kind): Query? {
        var s = name.replace("_", " ").replace(" ", " ").trim()
        // Scene-style "The.Matrix.1999.1080p" (dots instead of spaces).
        if (!s.contains(" ") && s.count { it == '.' } >= 2) s = s.replace(".", " ")
        s = stripPrefixTags(s)
        s = stripSuffixTags(s)
        val (splitTitle, splitYear) = TitleParser.splitYear(s)
        s = splitTitle
        val nameYear = splitYear?.toIntStrict()
        val fieldYear = year?.let { parseYear(it) }
        val debracketed = removeBrackets(s)
        s = if (collapse(debracketed).isEmpty()) s.replace(Regex("[\\[\\](){}]"), " ") else debracketed
        s = removeJunk(s)
        if (kind == MediaMetadata.Kind.series) s = removeSeasonMarker(s)
        s = collapse(s)

        var resolvedYear = fieldYear ?: nameYear
        var literal: String? = null
        var literalYear: Int? = null
        // A bare trailing year-like number: "Oppenheimer 2023" vs "Blade Runner 2049".
        val m = trailingNumber.matcher(s)
        if (m.find()) {
            val number = m.group(2).toIntStrict()
            val head = collapse(m.group(1))
            if (number != null && head.isNotEmpty()) {
                if (resolvedYear == null) {
                    resolvedYear = number
                    literal = s
                    s = head
                } else if (resolvedYear == number) {
                    literal = s
                    literalYear = resolvedYear
                    s = head
                }
                // A different known year: the number is part of the title ("Blade Runner 2049" (2017)).
            }
        }
        s = reorderArticle(s)
        if (s.isEmpty() || !s.codePoints().anyMatch { Character.isAlphabetic(it) || isNumber(it) }) return null
        return Query(s, resolvedYear, literal?.let { reorderArticle(it) }, literalYear)
    }

    /** Display-friendly cleaned title ("EN - The Matrix (1999) [4K]" → "The Matrix"), or the input. */
    public fun cleanTitle(name: String, kind: MediaMetadata.Kind = MediaMetadata.Kind.movie): String {
        val q = query(name, kind = kind) ?: return name
        return q.literalTitle ?: q.title
    }

    /** Tags that may prefix (or suffix) a title with a separator: languages, countries, platforms, quality. */
    internal val knownTags: Set<String> by lazy {
        val tags = mutableSetOf(
            "EN", "AR", "UK", "LAT", "LATAM", "LATINO", "ENG", "ARA", "ARB", "FRE", "FRA", "GER", "DEU", "SPA",
            "ESP", "ITA", "POR", "TUR", "RUS", "HIN", "PER", "FAR", "KUR", "URD", "SWE", "NOR", "DAN", "FIN",
            "POL", "GRE", "HEB", "CHI", "JAP", "JPN", "KOR", "NF", "NFX", "NETFLIX", "AMZ", "AMZN", "AMAZON",
            "PRIME", "DSNP", "DSNY", "DISNEY", "DISNEY+", "HBO", "HBOMAX", "HMAX", "MAX", "ATVP", "APPLE",
            "APPLETV", "HULU", "PCOK", "PEACOCK", "PMTP", "PARAMOUNT", "PARAMOUNT+", "STARZ", "SHO", "OSN",
            "OSN+", "SHAHID", "STC", "WATCHIT", "YANGO", "TOD", "BEIN", "CRAV", "CRAVE", "MUBI", "4K", "8K",
            "UHD", "FHD", "HD", "SD", "HDR", "3D", "VIP", "MULTI", "SUB", "DUB", "VOD", "VOSTFR", "VF", "VO",
            "4K+", "IMAX", "TOP", "NEW",
        )
        Locale.getISOCountries().filter { it.length == 2 }.forEach { tags.add(it.uppercase()) }
        Locale.getISOLanguages().filter { it.length == 2 }.forEach { tags.add(it.uppercase()) }
        tags
    }

    /** "EN - ", "AR:", "NF: ", "4K-", "AR| " at the start (the tag itself is checked separately). */
    private val prefixTag = UnicodeRegex.compile("""^\s*([A-Za-z0-9][A-Za-z0-9+]{1,8})\s*[:|\-–—]+\s*(?=\S)""")
    /** "|AR|", "[US]", "(EN)", "[MULTI-SUB]" at the start. */
    private val prefixBracket = UnicodeRegex.compile("""^\s*[\[(|]\s*([^\])|]{1,24}?)\s*[\])|]\s*[:|\-–—]*\s*""")
    /** " - EN", " | AR" at the end. */
    private val suffixTag = UnicodeRegex.compile("""\s*[:|\-–—]+\s*([A-Za-z0-9][A-Za-z0-9+]{1,8})\s*$""")

    internal fun stripPrefixTags(input: String): String {
        var s = input
        repeat(6) {
            var changed = false
            val b = prefixBracket.matcher(s)
            if (b.find()) {
                val tag = b.group(1)
                val rest = s.substring(b.end())
                val digitsOnly = tag.codePoints().allMatch { isNumber(it) }
                if (!digitsOnly && rest.codePoints().anyMatch { Character.isAlphabetic(it) } && (tag == tag.uppercase() || isJunkPhrase(tag))) {
                    s = rest
                    changed = true
                }
            }
            if (!changed) {
                val t = prefixTag.matcher(s)
                if (t.find()) {
                    val tag = t.group(1)
                    if (tag == tag.uppercase() && tag in knownTags) {
                        s = s.substring(t.end())
                        changed = true
                    }
                }
            }
            if (!changed) return s
        }
        return s
    }

    internal fun stripSuffixTags(input: String): String {
        var s = input
        repeat(3) {
            val m = suffixTag.matcher(s)
            if (!m.find()) return s
            val tag = m.group(1)
            val head = s.substring(0, m.start())
            if (tag != tag.uppercase() || tag !in knownTags || !head.codePoints().anyMatch { Character.isAlphabetic(it) }) return s
            s = head
        }
        return s
    }

    private val squareOrCurly = Pattern.compile("""\[[^\]]*\]|\{[^}]*\}""")
    private val parenthesised = Pattern.compile("""\(([^)]*)\)""")

    /** Drops `[...]`/`{...}` groups and `(...)` groups unless they hold only digits ("(500) Days of Summer"). */
    internal fun removeBrackets(input: String): String {
        val s = squareOrCurly.matcher(input).replaceAll(" ")
        val out = StringBuilder()
        var last = 0
        val m = parenthesised.matcher(s)
        while (m.find()) {
            val inner = m.group(1).trim(' ', '\t')
            if (inner.isNotEmpty() && inner.codePoints().allMatch { isNumber(it) }) continue
            out.append(s, last, m.start()).append(' ')
            last = m.end()
        }
        out.append(s.substring(last))
        // Unbalanced leftovers: "Title (4K" / "Title 4K)".
        return out.toString().replace(Regex("[\\[\\]{}]"), " ")
    }

    private const val BOUNDARY_START = """(?<![\p{L}\p{N}])"""
    private const val BOUNDARY_END = """(?![\p{L}\p{N}])"""

    /** Quality, packaging, language-track and edition tokens (case-insensitive: distinctive enough). */
    private val junkInsensitive = UnicodeRegex.compile(BOUNDARY_START + "(?:" +
        """4k\s*uhd|4k|8k|uhd|fhd|qhd|hdr10\+?|hdr|dolby[ .\-]?vision|hdtc|hdcam|hdts|hd[ .\-]?rip|hdtv|""" +
        """web[ .\-]?dl|web[ .\-]?rip|blu[ .\-]?ray|brrip|bdrip|dvdrip|dvdscr|x26[45]|h\.?26[45]|hevc|10bit|""" +
        """aac|ac3|ddp?5[ .]1|atmos|2160p|1080p|1080i|720p|576p|480p|""" +
        """multi[ .\-]?subs?|multi[ .\-]?audio|dual[ .\-]?audio|dubbed|subbed|subtitled|vostfr|truefrench|""" +
        """(?:arabic|english|eng|ar|en|fr|french|turkish|tr|hindi|spanish|persian|farsi|kurdish|urdu)[ .\-]?(?:subs?|subbed|subtitled|subtitles|dub|dubbed)|""" +
        """remastered|unrated|extended(?:[ .](?:cut|edition))?|directors?['’]?s?[ .]cut|theatrical[ .]cut|imax(?:[ .]edition)?|""" +
        """فيلم|مسلسل|مترجمة?|مدبلجة?|كاملة?|حصريا|اون لاين|بجودة عالية""" +
        ")" + BOUNDARY_END, caseInsensitive = true)

    /** Short tokens that are only junk in upper case ("CAM" yes, the film "Cam" no). */
    private val junkUppercase = UnicodeRegex.compile(BOUNDARY_START + """(?:HD|SD|TS|TC|CAM|WEB|DUB|SUB|SUBS|MULTI|DV|HC|VIP)""" + BOUNDARY_END)

    internal fun isJunkPhrase(s: String): Boolean = collapse(junkInsensitive.matcher(s).replaceAll(" ")).isEmpty()

    /** Removes junk tokens. A name that is nothing but junk ends up empty → no query. */
    internal fun removeJunk(input: String): String = junkUppercase.matcher(junkInsensitive.matcher(input).replaceAll(" ")).replaceAll(" ")

    private val seasonMarker = UnicodeRegex.compile(BOUNDARY_START + "(?:" +
        """S\d{1,2}(?:[\s._\-]*E\d{1,3})?|""" +
        """(?:season|saison|temporada|staffel|sezon|stagione|seizoen)[\s._\-]*(?:\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten)|""" +
        """complete[\s._\-]+series|الموسم|الحلقة""" +
        ")" + BOUNDARY_END + ".*$", caseInsensitive = true)

    /** "Wednesday S01", "Breaking Bad - Season 1", "Game of Thrones S08E06 The Iron Throne" → the show name. */
    internal fun removeSeasonMarker(input: String): String {
        val s = seasonMarker.matcher(input).replaceAll("")
        return if (collapse(s).isEmpty()) input else s
    }

    private val trailingNumber = UnicodeRegex.compile("""^(.*\S)\s+((?:19|20)\d{2})$""")
    private val articleSuffix = UnicodeRegex.compile("""^(.+),\s*(The|A|An)$""", caseInsensitive = true)
    private val yearPattern = UnicodeRegex.compile("""(?<!\d)((?:19|20)\d{2})(?!\d)""")

    /** "Matrix, The" → "The Matrix". */
    internal fun reorderArticle(s: String): String {
        val m = articleSuffix.matcher(s)
        return if (m.find()) "${m.group(2)} ${m.group(1)}" else s
    }

    /** First plausible year in a string ("2024", "2024-03-01", "2008–2013"). */
    internal fun parseYear(s: String): Int? {
        val m = yearPattern.matcher(s)
        return if (m.find()) m.group(1).toIntStrict() else null
    }

    /** Start and end year of a range such as "2008–2013" or "2025-" (end null when open/missing). */
    internal fun parseYearRange(s: String?): Pair<Int?, Int?> {
        if (s == null) return null to null
        val years = mutableListOf<Int>()
        val m: Matcher = yearPattern.matcher(s)
        while (m.find()) m.group(1).toIntStrict()?.let { years.add(it) }
        return years.firstOrNull() to years.getOrNull(1)
    }

    /** Collapses whitespace and trims separators. */
    internal fun collapse(s: String): String {
        val words = mutableListOf<String>()
        val w = StringBuilder()
        s.codePoints().forEach { cp ->
            if (Character.isWhitespace(cp) || Character.isSpaceChar(cp)) { if (w.isNotEmpty()) { words.add(w.toString()); w.setLength(0) } }
            else w.appendCodePoint(cp)
        }
        if (w.isNotEmpty()) words.add(w.toString())
        return words.joinToString(" ").trim(' ', '-', '–', '—', '_', '.', ':', '|', ',', ';', '/', '+')
    }

    // Scoring

    private val numberWords = mapOf(
        "one" to "1", "two" to "2", "three" to "3", "four" to "4", "five" to "5", "six" to "6", "seven" to "7", "eight" to "8",
        "nine" to "9", "ten" to "10", "ii" to "2", "iii" to "3", "iv" to "4", "v" to "5", "vi" to "6", "vii" to "7", "viii" to "8",
        "ix" to "9", "x" to "10",
    )

    /** Comparison tokens: folded, "&" → "and", apostrophes dropped, numerals as digits, Arabic variants unified. */
    internal fun tokens(s: String): List<String> {
        var t = ChannelNameNormalizer.fold(s)
        t = t.replace("&", " and ")
        t = t.filterNot { it in "'’`´ʼ" }
        val out = mutableListOf<String>()
        val current = StringBuilder()
        fun flush() {
            if (current.isEmpty()) return
            val word = current.toString()
            out.add(numberWords[word] ?: word)
            current.setLength(0)
        }
        t.codePoints().forEach { cp ->
            if (Character.isAlphabetic(cp) || isNumber(cp)) {
                when (cp) {
                    'أ'.code, 'إ'.code, 'آ'.code -> current.append('ا')
                    'ة'.code -> current.append('ه')
                    'ى'.code -> current.append('ي')
                    else -> current.appendCodePoint(cp)
                }
            } else if (isMark(cp) && current.isNotEmpty()) {
                current.appendCodePoint(cp) // marks belong to the letter before (Swift iterates graphemes)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    private val articles = setOf("the", "a", "an")

    /** Title similarity in 0…1: exact > prefix/suffix containment > token overlap. */
    internal fun titleSimilarity(query: String, candidate: String): Double {
        val q = tokens(query)
        val c = tokens(candidate)
        if (q.isEmpty() || c.isEmpty()) return 0.0
        if (q == c || q.joinToString("") == c.joinToString("")) return 1.0
        val qa = if (q.first() in articles && q.size > 1) q.drop(1) else q
        val ca = if (c.first() in articles && c.size > 1) c.drop(1) else c
        if (qa == ca || qa.joinToString("") == ca.joinToString("")) return 0.97
        var best = 0.0
        if (c.size > q.size && (c.take(q.size) == q || c.takeLast(q.size) == q)) best = maxOf(best, 0.6 + 0.3 * q.size / c.size)
        if (q.size > c.size && q.take(c.size) == c) best = maxOf(best, 0.55 + 0.3 * c.size / q.size)
        // Dice coefficient over token multisets.
        val pool = c.toMutableList()
        var common = 0
        for (token in q) {
            val i = pool.indexOf(token)
            if (i >= 0) { pool.removeAt(i); common++ }
        }
        return maxOf(best, 0.75 * 2 * common / (q.size + c.size))
    }

    /** Year agreement bonus/penalty. Series accept any year inside their run; a candidate without a year can't confirm. */
    internal fun yearAdjustment(year: Int?, candidate: Candidate, kind: MediaMetadata.Kind): Double {
        if (year == null) return 0.0
        val start = candidate.year ?: return -0.2
        return when (kind) {
            MediaMetadata.Kind.movie -> when (abs(year - start)) {
                0 -> 0.15
                1 -> 0.08
                2 -> -0.1
                else -> -0.35
            }
            MediaMetadata.Kind.series -> when {
                abs(year - start) <= 1 -> 0.15
                year > start && (candidate.endYear?.let { year <= it + 1 } ?: true) -> 0.05
                else -> -0.35
            }
        }
    }

    /** Best score of a candidate over the query's readings and the candidate's titles. */
    internal fun score(query: Query, candidate: Candidate, kind: MediaMetadata.Kind): Double {
        val readings = mutableListOf(query.title to query.year)
        query.literalTitle?.let { readings.add(it to query.literalYear) }
        var best = Double.NEGATIVE_INFINITY
        for ((title, year) in readings) {
            val similarity = candidate.titles.maxOfOrNull { titleSimilarity(title, it) } ?: 0.0
            if (similarity <= 0) continue
            best = maxOf(best, similarity + yearAdjustment(year, candidate, kind))
        }
        return if (best.isFinite()) best else 0.0
    }

    /** Index and score of the best acceptable candidate (ties go to the earlier, more popular, result). */
    internal fun bestMatch(query: Query, candidates: List<Candidate>, kind: MediaMetadata.Kind): Pair<Int, Double>? {
        var best: Pair<Int, Double>? = null
        candidates.forEachIndexed { i, candidate ->
            val s = score(query, candidate, kind)
            if (s >= ACCEPT_SCORE && s > (best?.second ?: -1.0) + 0.0001) best = i to s
        }
        return best
    }

    private fun isNumber(cp: Int) = when (Character.getType(cp).toByte()) {
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }

    private fun isMark(cp: Int) = when (Character.getType(cp).toByte()) {
        Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK -> true
        else -> false
    }
}
