// Port of Sources/TunerCore/Models/CategoryGrouping.swift @ 666f598
package app.tuner.core.models

import java.util.concurrent.ConcurrentHashMap

/**
 * Groups a provider's categories (often 50–200, named like "Arabic Movies - عربي 2024" or "Bein Sport [ FHD ] | [ … ]")
 * into a handful of browsable groups, and cleans their names. Keyword based, English and Arabic; first rule wins.
 */
public enum class CategoryGroup(public val raw: String, public val title: String, public val shortTitle: String) {
    FEATURED("featured", "Featured", "Featured"),
    BY_YEAR("byYear", "By Year", "By Year"),
    SPORTS("sports", "Sports", "Sports"),
    KIDS("kids", "Kids", "Kids"),
    PLATFORMS("platforms", "Platforms", "Platforms"),
    QUALITY("quality", "Quality & Subtitles", "Quality"),
    GENRES("genres", "Genres", "Genres"),
    LANGUAGES("languages", "Languages & Countries", "Languages"),
    MORE("more", "More", "More");

    public companion object {
        /** Order of the group chips in the UI (most useful first). */
        public val displayOrder: List<CategoryGroup> = listOf(FEATURED, LANGUAGES, PLATFORMS, GENRES, BY_YEAR, SPORTS, KIDS, QUALITY, MORE)
    }
}

/** How category names are shown: the provider's full name, or one language's part of a bilingual name. */
public enum class CategoryNameStyle(public val raw: String, public val title: String) {
    /** The English part when there is one, otherwise the Arabic part. */
    AUTOMATIC("automatic", "English When Available"),
    /** The Arabic part when there is one, otherwise the English part. */
    ARABIC("arabic", "Arabic When Available"),
    /** Exactly as the provider names it. */
    ORIGINAL("original", "As the Provider Names Them");

    public companion object {
        public fun of(raw: String): CategoryNameStyle? = entries.firstOrNull { it.raw == raw }
    }
}

/** A category's group and its name split by script. */
public data class CategoryFacet(
    val group: CategoryGroup,
    /** Latin-script parts of the name, joined with " · " ("Bein Sport · FHD"); null if there are none. */
    val latinName: String?,
    /** Arabic-script parts of the name; null if there are none. */
    val arabicName: String?,
    /** Year or year range mentioned in the name ("2024", "2010–2016"). */
    val yearLabel: String?,
    /** Latest year mentioned, for sorting By Year newest first. */
    val latestYear: Int?,
    val original: String,
) {
    public fun displayName(style: CategoryNameStyle): String {
        val base = when (style) {
            CategoryNameStyle.ORIGINAL -> return original
            CategoryNameStyle.AUTOMATIC -> latinName ?: arabicName
            CategoryNameStyle.ARABIC -> arabicName ?: latinName
        }
        var name = base?.trim()?.takeIf { it.isNotEmpty() } ?: return original
        if (yearLabel != null && !name.contains(yearLabel) && !(latestYear?.let { name.contains(it.toString()) } ?: false)) {
            name += " $yearLabel"
        }
        return name
    }
}

public object CategoryClassifier {
    /** Facets by name: browse pages ask for the same few hundred names on every render. */
    private val facets = ConcurrentHashMap<String, CategoryFacet>()
    private const val CACHE_LIMIT = 5_000

    public fun facet(name: String): CategoryFacet {
        facets[name]?.let { return it }
        val facet = classify(name)
        if (facets.size >= CACHE_LIMIT) facets.clear()
        facets[name] = facet
        return facet
    }

    /** `facet` without the cache. */
    internal fun classify(name: String): CategoryFacet {
        val (latin, arabic) = split(name)
        val years = yearsMentioned(name)
        return CategoryFacet(
            group = group(name, years.isNotEmpty()),
            latinName = if (latin.isEmpty()) null else latin.joinToString(" · "),
            arabicName = if (arabic.isEmpty()) null else arabic.joinToString(" · "),
            yearLabel = yearLabel(years),
            latestYear = years.maxOrNull(),
            original = name,
        )
    }

    internal fun group(name: String, hasYear: Boolean): CategoryGroup {
        val text = " " + normalized(name) + " "
        fun has(words: List<String>) = words.any { text.contains(it) }
        // Seasonal and award shelves stay featured even with a year ("RAMADAN 2026 مصر", "Oscar 2023").
        if (has(Keywords.seasonal)) return CategoryGroup.FEATURED
        // A year (or range) with a language/region reads as a release-year shelf: "Arabic Movies 2024".
        if (hasYear && (has(Keywords.languages) || has(Keywords.yearShelves))) return CategoryGroup.BY_YEAR
        if (has(Keywords.sports)) return CategoryGroup.SPORTS
        if (has(Keywords.kids)) return CategoryGroup.KIDS
        if (has(Keywords.platforms)) return CategoryGroup.PLATFORMS
        if (has(Keywords.featured) || hasYear) return CategoryGroup.FEATURED
        if (has(Keywords.genres)) return CategoryGroup.GENRES
        if (has(Keywords.quality)) return CategoryGroup.QUALITY
        if (has(Keywords.languages) || has(Keywords.countries)) return CategoryGroup.LANGUAGES
        return CategoryGroup.MORE
    }

    private val folds = listOf("أ" to "ا", "إ" to "ا", "آ" to "ا", "ة" to "ه", "ى" to "ي", "ـ" to "", "ٍ" to "", "ً" to "",
        "َ" to "", "ُ" to "", "ِ" to "", "ّ" to "")
    private const val SEPARATORS = "-|[](){}_/:,.+"

    /** Lowercased, Arabic letter variants folded (أ/إ/آ→ا, ة→ه, ى→ي), punctuation turned into spaces, spaces collapsed. */
    internal fun normalized(name: String): String {
        var s = name.lowercase()
        for ((from, to) in folds) s = s.replace(from, to)
        val sb = StringBuilder(s.length)
        s.codePoints().forEach { cp -> if (cp < 0x80 && cp.toChar() in SEPARATORS) sb.append(' ') else sb.appendCodePoint(cp) }
        return sb.split { isWhitespace(it) }
    }

    /**
     * Splits "Arabic Movies -  [  2010 - 2016 ] عربي" into Latin ("Arabic Movies") and Arabic ("عربي") parts; bare
     * numbers (years) are left out of both.
     */
    internal fun split(name: String): Pair<List<String>, List<String>> {
        val segments = mutableListOf<String>()
        val current = StringBuilder()
        val scalars = name.codePoints().toArray()
        for (i in scalars.indices) {
            val cp = scalars[i]
            val isBracket = cp < 0x80 && cp.toChar() in "[](){}|"
            // A dash separates only when spaced on at least one side ("Drama- افلام", "Arabic - عربي"), not "Sci-Fi".
            val isDash = (cp == '-'.code || cp == '–'.code) &&
                ((i > 0 && isWhitespace(scalars[i - 1])) || (i + 1 < scalars.size && isWhitespace(scalars[i + 1])))
            if (isBracket || isDash) {
                segments.add(current.toString())
                current.setLength(0)
            } else {
                current.appendCodePoint(cp)
            }
        }
        segments.add(current.toString())

        val latin = mutableListOf<String>()
        val arabic = mutableListOf<String>()
        for (raw in segments) {
            val segment = StringBuilder(raw).split { isWhitespace(it) }
            if (segment.codePoints().noneMatch { Character.isAlphabetic(it) }) continue // years, "4", stray punctuation
            if (segment.codePoints().anyMatch { isArabic(it) }) {
                // "2026 اجنبي": keep the words, drop the year (it's shown separately).
                val words = segment.split(' ').filter { word -> !word.codePoints().allMatch { isNumber(it) } }.joinToString(" ")
                if (words.isNotEmpty()) arabic.add(words)
            } else {
                latin.add(segment)
            }
        }
        return latin to arabic
    }

    internal fun isArabic(cp: Int): Boolean = cp in 0x0600..0x06FF || cp in 0x0750..0x077F || cp in 0xFB50..0xFDFF || cp in 0xFE70..0xFEFF

    internal fun yearsMentioned(name: String): List<Int> {
        val sb = StringBuilder()
        name.codePoints().forEach { cp -> if (Character.getType(cp).toByte() == Character.DECIMAL_DIGIT_NUMBER) sb.appendCodePoint(cp) else sb.append(' ') }
        return sb.split(' ').filter { it.isNotEmpty() }.mapNotNull { token ->
            if (token.codePointCount(0, token.length) != 4) return@mapNotNull null
            token.toIntStrict()?.takeIf { it in 1950..2100 }
        }
    }

    internal fun yearLabel(years: List<Int>): String? {
        val low = years.minOrNull() ?: return null
        val high = years.max()
        return if (low == high) low.toString() else "$low–$high"
    }

    /** Unicode White_Space (Swift's `properties.isWhitespace` / `Character.isWhitespace`). */
    private fun isWhitespace(cp: Int) = Character.isWhitespace(cp) || Character.isSpaceChar(cp)

    private fun isNumber(cp: Int) = when (Character.getType(cp).toByte()) {
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }

    /** Splits on whitespace (dropping empty pieces) and joins with single spaces. */
    private fun CharSequence.split(isSeparator: (Int) -> Boolean): String {
        val words = mutableListOf<String>()
        val word = StringBuilder()
        toString().codePoints().forEach { cp ->
            if (isSeparator(cp)) { if (word.isNotEmpty()) { words.add(word.toString()); word.setLength(0) } } else word.appendCodePoint(cp)
        }
        if (word.isNotEmpty()) words.add(word.toString())
        return words.joinToString(" ")
    }
}

/** Keyword lists (normalized: lowercase, Arabic variants folded). English keywords padded where they could be inside words. */
internal object Keywords {
    val sports = listOf(
        "sport", " nba ", "tennis", "cricket", " wwe ", " ufc ", "match", " league", "football", "nfl", "boxing",
        "رياض", "مباريات", "مباراه", "مصارع", "دوري", "كاس العالم", "الكره",
    )
    val kids = listOf(" kids", "cartoon", "spacetoon", "children", "اطفال", "كرتون", "سبيستون", "سبيس تون")
    val platforms = listOf(
        "netflix", "shahid", "disney", "watch it", "watchit", "starz", "amazon", "prime video", " osn", " hbo",
        "apple tv", "masspero", "maspero", " mbc", "rotana", "alwan", "shoof", "flix tv", " stc", " art ",
        // Short Arabic names must start a word: "شاهد" also occurs inside "المشاهده" (viewing).
        "نتفليكس", "نت فليكس", " شاهد", "ديزني", " واتش", "ستارز", "امازون", "ماسبيرو", "روتانا", "اللوان", " شوف",
    )
    val featured = listOf(
        "box office", " top ", " imdb", "imdp", "oscar", "trending", " best ", "marvel", " dc ", "weekend", "on demand",
        " new ", "classic", "collection", "salasil", "actors", "now showing",
        "بوكس اوفيس", "افضل", "الاعلي", "مميز", "تعرض حاليا", "انتهت", "طلبات", "جديد", "سلاسل",
        "الزمن الجميل", "كلاسيك", "الممثلين", "عطله", "ايرادات",
    )
    val quality = listOf(
        " 4k", " uhd", " fhd", " hd ", " sd ", "h 265", "hevc", "pure", "multi sub", "multi audio", " sub ", "no sub",
        " 3d ", "فائقه الجوده", "متعدده التراجم", "مترجمه للانجليزيه", "ثلاثيه الابعاد",
    )
    val genres = listOf(
        "action", "drama", "comedy", "horror", "sci fi", "scifi", "science fiction", " war ", "romantic", "romance",
        "crime", "thriller", "mystery", "family", "historical", "history", "documentar", "anime", "animation",
        "musical", " music", "religious", "islamic", "quran", "christian", "chrisitan", "medical", "education",
        "learn", " news", "motivational", "comedies", "masrahiyat", "msarhyat", "plays", "song", "radio",
        "talk show", "concert", "حفلات", "برامج",
        "اكشن", "دراما", "كوميد", "رعب", "خيال علمي", "حروب", "رومانس", "رومانسي", "جريمه", "عائلي", "تاريخي",
        "وثائقي", "انمي", "ديني", "اسلامي", "قران", "القران", "المسيحيه", "طبيه", "تعليم", "اخبار", "مسرحيات",
        "اغاني", "موسيقي", "راديو", "تحفيز", "تحفيذيه",
    )
    val seasonal = listOf("ramadan", "رمضان", "oscar", "اوسكار")
    /** Languages and dubbing/subtitle variants of a language. */
    val languages = listOf(
        "arabic", "english", "foreign", "turkish", "indian", "hindi", "korean", "asian", "japanese", "chinese",
        "spanish", "french", "german", "italian", "latin", "syrian", "lebanese", "egyptian", "saudi", "kuwait",
        "tunisian", "moroccan", "khaleeji", "gulf", "dubbed", "persian", "kurdish", "urdu",
        "عربي", "عربيه", "اجنبي", "اجنبيه", "تركي", "تركيه", "هندي", "هنديه", "كوري", "كوريه", "اسيوي", "اسيويه",
        "ياباني", "صيني", "اسباني", "فرنسي", "الماني", "ايطالي", "لاتيني", "سوري", "سوريه", "لبناني", "لبنانيه",
        "مصري", "مصريه", "سعودي", "سعوديه", "كويتي", "كويتيه", "تونسي", "تونسيه", "مغربي", "مغربيه", "خليجي",
        "مدبلج", "مترجم", "اماراتي", "اماراتيه",
    )
    /** "English Movies 2026"-style shelves whose language word isn't in `languages`. */
    val yearShelves = listOf("movies", "series", "افلام", "مسلسلات")
    val countries = listOf(
        " uk ", " usa ", "egypt", "saudi", "emirates", " uae", "qatar", "lebanon", "algeria", "morocco", "tunisia",
        "syria", "kuwait", "iraq", "libya", "yemen", "sudan", "jordan", "palestine", "oman", "bahrain", "germany",
        "france", "italy", "portugal", "turkey", "spain", "canada", "poland", "netherlands", "sweden", "brazil",
        "argentin", "finland", "australia", "norway", "india", "bulgaria", "romania", "hungar", "russia", "armenia",
        "ukraine", "belgium", "greek", "greece", "denmark", "africa", "swiss", "switzerland", "malta", "austria",
        "serbia", "exyu", "iran", "philippines", "pakistan", "china", "thailand", "japan", "korea", "mexico",
        "مصر", "السعوديه", "الامارات", "قطر", "لبنان", "الجزائر", "المغرب", "تونس", "سوريا", "الكويت", "العراق",
        "ليبيا", "اليمن", "السودان", "الاردن", "فلسطين", "عمان", "البحرين", "المانيا", "فرنسا", "ايطاليا",
        "البرتغال", "تركيا", "اسبانيا", "كندا", "بولندا", "هولندا", "السويد", "البرازيل", "الارجنتين", "فنلندا",
        "استراليا", "النرويج", "الهند", "روسيا", "افريقيا", "ايران", "باكستان", "الصين", "انجلترا", "امريكا",
        "الولايات المتحده",
    )
}
