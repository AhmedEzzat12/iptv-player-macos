import Foundation

/// Text handling for the recommender, the same for English and Arabic (provider libraries mix both, often in one
/// name): normalisation, word tokens without stop words, canonical genres and languages, and a duplicate key per title.
///
/// Arabic normalisation follows common IR practice: diacritics (harakat), tatweel and Quranic marks are removed;
/// alef forms (أ إ آ ٱ) become ا, ى/ی become ي, ة becomes ه, ؤ becomes و, ئ becomes ي, ک becomes ك; Arabic-Indic
/// digits become ASCII digits. The definite article (ال, وال) is stripped from longer words, so "الحب" matches "حب".
enum RecommendationText {
    // MARK: Normalisation

    /// Lowercase, accent-free, Arabic-normalised text with every run of punctuation or whitespace turned into one
    /// space (apostrophes are dropped: "Ocean's" → "oceans").
    static func normalize(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(input.unicodeScalars.count)
        var pendingSpace = false

        func emit(_ value: UInt32) {
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(Unicode.Scalar(value)!)
        }

        for scalar in input.unicodeScalars {
            let v = scalar.value
            if v < 0x80 {
                switch v {
                case 0x41...0x5A: emit(v + 32)
                case 0x61...0x7A, 0x30...0x39: emit(v)
                case 0x27: continue
                default: pendingSpace = true
                }
                continue
            }
            switch v {
            case 0x064B...0x065F, 0x0670, 0x0640, 0x06D6...0x06ED, 0x0300...0x036F, 0x200C...0x200F:
                continue // harakat, superscript alef, tatweel, Quranic marks, combining accents, joiners/marks
            case 0x2019: continue // typographic apostrophe
            case 0x0622, 0x0623, 0x0625, 0x0671: emit(0x0627) // آ أ إ ٱ → ا
            case 0x0649, 0x06CC, 0x0626: emit(0x064A) // ى ی ئ → ي
            case 0x0629: emit(0x0647) // ة → ه
            case 0x0624: emit(0x0648) // ؤ → و
            case 0x06A9: emit(0x0643) // ک → ك
            case 0x0660...0x0669: emit(v - 0x0660 + 0x30) // Arabic-Indic digits
            case 0x06F0...0x06F9: emit(v - 0x06F0 + 0x30) // Extended Arabic-Indic digits
            case 0x0621, 0x0627...0x063A, 0x0641...0x064A, 0x0671...0x06D3:
                emit(v)
            default:
                if scalar.properties.isAlphabetic {
                    // Latin with accents and other scripts: lowercase and fold accents ("Amélie" → "amelie").
                    let folded = String(scalar).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    for s in folded.unicodeScalars where s.properties.isAlphabetic || s.properties.numericType != nil {
                        emit(s.value)
                    }
                } else if scalar.properties.numericType == .decimal, let d = scalar.properties.numericValue {
                    emit(0x30 + UInt32(d))
                } else {
                    pendingSpace = true
                }
            }
        }
        return String(out)
    }

    /// Normalised words, in order (no stop-word filtering).
    static func words(_ input: String) -> [Substring] {
        normalize(input).split(separator: " ")
    }

    /// Strips the Arabic definite article from words long enough to keep a stem ("الحب" → "حب", "والحب" → "حب").
    static func stem(_ word: Substring) -> Substring {
        let scalars = word.unicodeScalars
        guard let first = scalars.first, first.value >= 0x0600, first.value <= 0x06FF else {
            // English: a plural "s" ("detectives" → "detective"), but not "ss" ("boss").
            if word.utf8.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss") { return word.dropLast() }
            return word
        }
        let count = scalars.count
        if count >= 5, word.hasPrefix("وال") || word.hasPrefix("بال") || word.hasPrefix("فال") || word.hasPrefix("كال") {
            return word.dropFirst(3)
        }
        if count >= 4, word.hasPrefix("ال"), word != "الله" {
            return word.dropFirst(2)
        }
        if count >= 4, word.hasPrefix("لل") {
            return word.dropFirst(2)
        }
        return word
    }

    /// Content words of free text (titles, plots): normalised, stemmed, without stop words, numbers or one-letter words.
    static func contentWords(_ input: String) -> [Substring] {
        var result: [Substring] = []
        for word in words(input) {
            guard !stopWords.contains(word) else { continue }
            let stemmed = stem(word)
            guard stemmed.unicodeScalars.count >= 2, !stopWords.contains(stemmed),
                  !stemmed.allSatisfy(\.isNumber) else { continue }
            result.append(stemmed)
        }
        return result
    }

    // MARK: Titles

    /// The year in a provider year field or release date ("2019", "2019-05-01", "2008–2013").
    static func year(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        var digits = 0
        var value = 0
        for scalar in raw.unicodeScalars {
            if scalar.value >= 0x30, scalar.value <= 0x39 {
                digits += 1
                value = value * 10 + Int(scalar.value - 0x30)
                if digits == 4, (1900...2099).contains(value) {
                    return value
                }
            } else {
                digits = 0
                value = 0
            }
        }
        return nil
    }

    /// A title's duplicate key and the year found in its name: "EN - The Matrix (1999) [4K]" → ("the matrix", 1999),
    /// "Breaking Bad S02" (a show) → ("breaking bad", nil). Language prefixes, quality tags and, for shows, season
    /// markers are dropped; when nothing would be left, the plain normalised name is the key.
    static func titleKey(_ name: String, isSeries: Bool) -> (key: String, year: Int?) {
        let all = words(name)
        let tokens = words(String(stripPrefixTags(name)))

        var kept: [Substring] = []
        var year: Int?
        var skipNumber = false
        for (offset, token) in tokens.enumerated() {
            if qualityTags.contains(token) { continue }
            if isSeries {
                if seasonWords.contains(token) { skipNumber = true; continue }
                if isSeasonCode(token) { continue }
                if skipNumber, token.allSatisfy(\.isNumber) { skipNumber = false; continue }
            }
            skipNumber = false
            // A plausible release year after the first word is the year, not part of the title ("Oppenheimer 2023";
            // "1917" and "Blade Runner 2049" stay).
            if offset > 0, token.utf8.count == 4, let y = Int(token), (1920...2035).contains(y) {
                year = year ?? y
                continue
            }
            kept.append(token)
        }
        if kept.isEmpty { kept = Array(all) }
        return (kept.joined(separator: " "), year)
    }

    /// Drops language/platform/quality prefixes that are set off by a separator: "EN - …", "|AR| …", "[4K] …",
    /// "NF: …". Latin tags must be upper case, so "It: Chapter Two" keeps its title. At most four, and only while a
    /// title remains.
    static func stripPrefixTags(_ name: String) -> Substring {
        var rest = name[...]
        for _ in 0..<4 {
            let trimmed = rest.drop(while: \.isWhitespace)
            guard let first = trimmed.first else { break }
            var tag: Substring
            var after: Substring
            if "[(|".contains(first) {
                let close: Character = first == "[" ? "]" : (first == "(" ? ")" : "|")
                let inner = trimmed.dropFirst()
                guard let end = inner.firstIndex(of: close), inner.distance(from: inner.startIndex, to: end) <= 12 else { break }
                tag = inner[..<end]
                after = inner[inner.index(after: end)...].drop(while: { $0.isWhitespace || "-:|–—".contains($0) })
            } else {
                let end = trimmed.firstIndex(where: { !($0.isLetter || $0.isNumber || $0 == "+") }) ?? trimmed.endIndex
                tag = trimmed[..<end]
                let gap = trimmed[end...].drop(while: \.isWhitespace)
                guard let separator = gap.first, "-:|–—".contains(separator) else { break }
                after = gap.drop(while: { $0.isWhitespace || "-:|–—".contains($0) })
            }
            tag = tag.drop(while: \.isWhitespace)
            let isLatin = tag.unicodeScalars.allSatisfy { $0.value < 0x0600 }
            let words = words(String(tag))
            guard !words.isEmpty, words.count <= 2, !isLatin || tag == tag.uppercased(),
                  words.allSatisfy({ prefixTags.contains($0) || qualityTags.contains($0) }),
                  after.contains(where: \.isLetter) else { break }
            rest = after
        }
        return rest
    }

    /// "s01", "s1", "s01e02".
    static func isSeasonCode(_ token: Substring) -> Bool {
        let u = Array(token.utf8)
        guard u.count >= 2, u.count <= 7, u[0] == UInt8(ascii: "s") else { return false }
        return u.dropFirst().allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || $0 == UInt8(ascii: "e") } && u[1] >= 0x30 && u[1] <= 0x39
    }

    // MARK: Lists, separators

    /// Splits a provider list field ("Drama, Comedy", "Action / Adventure", "دراما، كوميدي").
    static func splitList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(whereSeparator: { ",/|;،&".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A person's name as one token, spaces removed so "كريم عبد العزيز" matches "كريم عبدالعزيز" ("Tom Hanks" → "tomhanks").
    static func personKey(_ name: String) -> String? {
        let key = normalize(name).replacingOccurrences(of: " ", with: "")
        return key.unicodeScalars.count >= 3 ? key : nil
    }

    // MARK: Canonical genres and languages

    /// Canonical genres for a genre string or category name, in English and Arabic ("Action & Adventure" →
    /// action, adventure; "افلام اكشن" → action). Empty when nothing is recognised.
    static func canonicalGenres(_ text: String) -> [String] {
        matches(normalize(text), in: genreKeywords)
    }

    /// Canonical languages/regions named in a category ("Arabic Movies", "مسلسلات تركيه" → turkish).
    static func canonicalLanguages(_ text: String) -> [String] {
        matches(normalize(text), in: languageKeywords)
    }

    private static func matches(_ normalized: String, in table: [(String, [String])]) -> [String] {
        let padded = " " + normalized + " "
        var found: [String] = []
        for (canonical, keywords) in table where keywords.contains(where: { padded.contains($0) }) {
            found.append(canonical)
        }
        return found
    }

    /// Normalises keyword lists once; a leading/trailing space in a keyword means "word boundary" there.
    private static func table(_ raw: [(String, [String])]) -> [(String, [String])] {
        raw.map { canonical, keywords in
            (canonical, keywords.map { keyword in
                let lead = keyword.hasPrefix(" ") ? " " : ""
                let trail = keyword.hasSuffix(" ") ? " " : ""
                return lead + normalize(keyword) + trail
            })
        }
    }

    static let genreKeywords: [(String, [String])] = table([
        ("action", ["action", "اكشن", "أكشن", "حركة"]),
        ("adventure", ["adventure", "مغامر"]),
        ("animation", ["animation", "animated", " anime", "cartoon", "انمي", "أنمي", "رسوم متحركة", "كرتون"]),
        ("comedy", ["comedy", "comedies", "comedie", "كوميد"]),
        ("crime", ["crime", "criminal", "جريمة", "جرائم", "اجرام"]),
        ("documentary", ["documentar", "docu", "وثائقي"]),
        ("drama", ["drama", "دراما", "درامي"]),
        ("family", ["family", "عائلي", "اسري"]),
        ("fantasy", ["fantasy", "فانتازيا", "خيالي"]),
        ("history", ["history", "historical", "تاريخي"]),
        ("horror", ["horror", "رعب"]),
        ("music", [" music", "musical", "موسيقي", "غنائي"]),
        ("mystery", ["mystery", "غموض"]),
        ("romance", ["romance", "romantic", "رومانس", "رومانسي"]),
        ("scifi", ["sci fi", "scifi", "science fiction", "خيال علمي"]),
        ("thriller", ["thriller", "suspense", "اثارة", "إثارة", "تشويق"]),
        ("war", [" war ", " wars ", "حرب", "حروب", "حربي"]),
        ("western", ["western"]),
        ("sport", ["sport", "رياض"]),
        ("kids", [" kids", "children", "اطفال", "أطفال"]),
        ("biography", ["biograph", "سيرة ذاتية"]),
        ("reality", ["reality", "واقع"]),
        ("religious", ["religious", "islamic", "ديني", "اسلامي", "إسلامي"]),
        ("standup", ["stand up", "standup", "ستاند اب"]),
        ("theatre", ["plays", "theater", "theatre", "مسرحي", "مسرحيات"]),
    ])

    static let languageKeywords: [(String, [String])] = table([
        ("arabic", ["arabic", "عربي", "عربية"]),
        ("english", ["english", "foreign", "اجنبي", "أجنبي", "اجنبية", "انجليزي"]),
        ("turkish", ["turkish", "turkey", "تركي", "تركية"]),
        ("indian", ["indian", "hindi", "bollywood", "هندي", "هندية"]),
        ("korean", ["korean", " kdrama", "كوري", "كورية"]),
        ("japanese", ["japanese", "ياباني"]),
        ("chinese", ["chinese", "صيني"]),
        ("asian", ["asian", "اسيوي", "آسيوي"]),
        ("egyptian", ["egypt", "مصري", "مصرية", " مصر"]),
        ("syrian", ["syria", "سوري"]),
        ("lebanese", ["leban", "لبناني"]),
        ("gulf", ["khaleeji", "gulf", "خليجي", "خليجية", "سعودي", "كويتي", "اماراتي"]),
        ("maghreb", ["moroc", "tunis", "algeri", "مغربي", "تونسي", "جزائري"]),
        ("french", ["french", "france", "فرنسي"]),
        ("spanish", ["spanish", "latino", "اسباني"]),
        ("persian", ["persian", "iran", "farsi", "ايراني", "فارسي"]),
        ("kurdish", ["kurd", "كردي"]),
    ])

    // MARK: Word lists (normalised on first use)

    private static func normalizedSet(_ words: [String]) -> Set<Substring> {
        Set(words.flatMap { normalize($0).split(separator: " ") })
    }

    static let stopWords: Set<Substring> = normalizedSet([
        // English
        "a", "an", "the", "and", "or", "but", "if", "then", "than", "so", "of", "in", "on", "at", "to", "for", "from",
        "by", "with", "without", "about", "into", "onto", "over", "under", "after", "before", "between", "through",
        "during", "against", "among", "around", "as", "up", "down", "out", "off", "again", "once", "is", "are", "was",
        "were", "be", "been", "being", "am", "has", "have", "had", "having", "do", "does", "did", "doing", "will",
        "would", "should", "can", "could", "may", "might", "must", "shall", "it", "its", "this", "that", "these",
        "those", "he", "she", "they", "them", "his", "her", "hers", "him", "their", "theirs", "we", "us", "our",
        "you", "your", "i", "me", "my", "who", "whom", "whose", "which", "what", "when", "where", "why", "how", "all",
        "any", "both", "each", "few", "more", "most", "other", "some", "such", "no", "nor", "not", "only", "own",
        "same", "too", "very", "just", "also", "now", "here", "there", "while", "until", "because", "though",
        "although", "yet", "still", "even", "ever", "every", "however", "himself", "herself", "themselves", "itself",
        "one", "two", "three", "first", "last", "new", "get", "gets", "got", "go", "goes", "going", "make", "makes",
        "take", "takes", "find", "finds", "become", "becomes", "begin", "begins", "try", "tries", "set", "sets",
        "way", "back", "soon", "much", "many", "well", "like", "upon", "within", "along", "across", "behind",
        "film", "films", "movie", "movies", "series", "season", "seasons", "episode", "episodes", "story", "stories",
        "follows", "follow", "tells", "tale", "based", "full", "hd",
        // Arabic (written naturally; normalised like the text)
        "في", "من", "على", "إلى", "الى", "عن", "مع", "هذا", "هذه", "ذلك", "تلك", "هؤلاء", "التي", "الذي", "الذين",
        "اللذين", "اللتين", "كان", "كانت", "كانوا", "يكون", "تكون", "ليس", "ليست", "هو", "هي", "هم", "هن", "انا",
        "نحن", "انت", "انتم", "و", "او", "أو", "ثم", "لا", "لم", "لن", "ما", "ماذا", "متى", "اين", "كيف", "كل", "بعض",
        "بعد", "قبل", "عند", "عندما", "حتى", "بين", "ان", "إن", "أن", "قد", "لقد", "كما", "ايضا", "أيضا", "حيث",
        "لكن", "ولكن", "غير", "فيه", "فيها", "منه", "منها", "له", "لها", "لهم", "به", "بها", "بهم", "عليه", "عليها",
        "ذات", "احد", "إحدى", "يتم", "خلال", "حول", "ضد", "دون", "مثل", "اي", "أي", "هناك", "هنا", "نحو", "جدا",
        "التى", "الا", "إلا", "اذا", "إذا", "لو", "منذ", "عام", "يوم", "وهو", "وهي", "وفي", "ومن", "التي", "بين",
        "فيلم", "افلام", "أفلام", "مسلسل", "مسلسلات", "الفيلم", "المسلسل", "حلقة", "حلقات", "الحلقة", "موسم", "الموسم",
        "قصة", "القصة", "تدور", "احداث", "أحداث", "يدور", "حول", "كامل", "كاملة", "مترجم", "مترجمة", "مدبلج", "مدبلجة",
    ])

    /// Tags dropped anywhere in a title (quality, packaging, dubbing).
    static let qualityTags: Set<Substring> = normalizedSet([
        "4k", "8k", "uhd", "fhd", "hd", "sd", "hdr", "hdr10", "3d", "vip", "multi", "sub", "subs", "subbed", "dub",
        "dubbed", "1080p", "720p", "2160p", "480p", "hevc", "x264", "x265", "h264", "h265", "webdl", "webrip",
        "bluray", "brrip", "bdrip", "hdtc", "hdcam", "hdrip", "dvdrip", "cam", "imax", "remastered", "uncut",
        "مترجم", "مترجمة", "مدبلج", "مدبلجة", "حصريا", "كامل", "كاملة", "فيلم", "مسلسل",
    ])

    /// Tags dropped only at the start of a title ("EN - It" keeps "it").
    static let prefixTags: Set<Substring> = normalizedSet([
        "en", "ar", "eng", "ara", "arb", "fr", "fre", "de", "ger", "es", "spa", "it", "ita", "tr", "tur", "uk", "us",
        "in", "hin", "kr", "kor", "jp", "jap", "ir", "per", "ku", "kur", "nf", "nfx", "netflix", "amz", "amzn",
        "amazon", "prime", "dsnp", "disney", "hbo", "hmax", "osn", "shahid", "starz", "apple", "atvp", "stc", "top",
        "new", "vod", "multi", "4k", "8k", "fhd", "uhd", "hd", "vip", "عربي", "اجنبي",
    ])

    /// Season words in show names ("Season 2", "الموسم 3", "Part 2").
    static let seasonWords: Set<Substring> = normalizedSet([
        "season", "saison", "temporada", "staffel", "sezon", "part", "موسم", "الموسم", "جزء", "الجزء",
    ])
}
