import Foundation

/// Rule-based understanding of natural searches in English and Arabic: "90s comedy series", "top rated korean
/// dramas", "Arabic movies from 2015", "مسلسلات تركية رومانسية", "أفلام رعب التسعينات".
///
/// Kinds, genres, languages/regions, years and decades, 4K and "top rated" become `SearchFilter`s; every other word
/// stays as title text. Connecting words ("from the", "in", "من", "في") are dropped only next to something that was
/// understood, so "The Office" or "Breaking Bad" stay exactly as typed. Whether the whole query is the name of a
/// title in the library (which wins over any parse, e.g. "Family Guy", "That '90s Show") is checked by
/// `AppDatabase.understandSearch`.
public enum QueryUnderstanding {
    public static func parse(_ query: String, currentYear: Int = QueryUnderstanding.currentYear) -> ParsedSearch {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var tokens = tokenize(trimmed)
        guard !tokens.isEmpty else { return .plain(trimmed) }

        var found: [(index: Int, filter: SearchFilter)] = []

        // 1. Years and decades (the first one wins; later ones stay as text).
        if let (span, range) = findYears(tokens, currentYear: currentYear) {
            found.append((range.lowerBound, .years(span)))
            for i in range { tokens[i].role = .filter }
        }

        // 2. Words and phrases from the lexicon, longest first.
        var i = 0
        while i < tokens.count {
            guard tokens[i].role == nil else { i += 1; continue }
            var matched = false
            for length in stride(from: min(3, tokens.count - i), through: 1, by: -1) {
                let span = tokens[i..<(i + length)]
                guard span.allSatisfy({ $0.role == nil }) else { continue }
                if let entry = lookup(Array(span.map(\.key))) {
                    for j in i..<(i + length) { tokens[j].role = entry.isFiller ? .fillerCandidate : .filter }
                    for filter in entry.filters { found.append((i, filter)) }
                    i += length
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }

        // "Movies and series" asks for both: no kind filter.
        let kinds = Set(found.compactMap { if case .kind(let k) = $0.filter { k } else { nil } })
        if kinds.count > 1 { found.removeAll { if case .kind = $0.filter { true } else { false } } }

        var filters: [SearchFilter] = []
        for (_, filter) in found.sorted(by: { $0.index < $1.index }) where !filters.contains(filter) {
            filters.append(filter)
        }
        guard !filters.isEmpty else { return .plain(trimmed) }

        // 3. Connecting words next to an understood word (or next to another dropped connector) go too.
        var changed = true
        while changed {
            changed = false
            for k in tokens.indices where tokens[k].role != .filter && tokens[k].role != .filler {
                let isFiller = tokens[k].role == .fillerCandidate || variants(tokens[k].key).contains { fillers.contains($0) }
                guard isFiller else { continue }
                let neighbours = [k - 1, k + 1].filter { tokens.indices.contains($0) }
                if neighbours.contains(where: { tokens[$0].role == .filter || tokens[$0].role == .filler }) {
                    tokens[k].role = .filler
                    changed = true
                }
            }
        }

        let text = tokens.filter { $0.role != .filter && $0.role != .filler }.map(\.original).joined(separator: " ")
        return ParsedSearch(query: trimmed, text: text, filters: filters)
    }

    public static var currentYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }

    // MARK: Tokens

    struct Token {
        enum Role { case filter, filler, fillerCandidate }
        /// As typed, without surrounding punctuation.
        var original: String
        /// Folded for matching.
        var key: String
        var role: Role?
    }

    static func tokenize(_ query: String) -> [Token] {
        let edge = CharacterSet(charactersIn: ".,!?;:\"()[]{}«»،؛؟…“”")
        return query.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let original = String(raw).trimmingCharacters(in: edge)
            let key = fold(original)
            return key.isEmpty ? nil : Token(original: original, key: key)
        }
    }

    /// Lowercased; Arabic letter variants unified (أ/إ/آ→ا, ة→ه, ى→ي), harakat and tatweel removed, Arabic-Indic
    /// digits made ASCII, typographic apostrophes and dashes made plain.
    public static func fold(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x0623, 0x0625, 0x0622, 0x0671: out.append("ا")
            case 0x0629: out.append("ه")
            case 0x0649: out.append("ي")
            case 0x064B...0x0652, 0x0640, 0x0670: continue
            case 0x0660...0x0669: out.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: out.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            case 0x2018, 0x2019, 0x0060: out.append("'")
            case 0x2013, 0x2014: out.append("-")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Arabic words also match without a leading article/conjunction ("الرعب", "والمسلسلات", "للاطفال") and in their
    /// masculine/singular form ("تركيه" → "تركي", "وثائقيات" → "وثائقي").
    static func variants(_ key: String) -> [String] {
        guard key.unicodeScalars.contains(where: CategoryClassifier.isArabic) else { return [key] }
        var stems = [key]
        for prefix in ["وال", "بال", "فال", "كال", "لل", "ال", "و", "ب", "ل"] where key.hasPrefix(prefix) && key.count - prefix.count >= 3 {
            stems.append(String(key.dropFirst(prefix.count)))
        }
        var out: [String] = []
        for stem in stems {
            out.append(stem)
            if stem.hasSuffix("يه") { out.append(String(stem.dropLast())) }
            if stem.hasSuffix("يات"), stem.count > 5 { out.append(String(stem.dropLast(2))) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: Lexicon

    struct Entry {
        var filters: [SearchFilter]
        var isFiller: Bool { filters.isEmpty }
    }

    static func lookup(_ keys: [String]) -> Entry? {
        // Every combination of the words' variants ("الخيال العلمي" → "خيال علمي").
        var candidates = [""]
        for key in keys {
            candidates = candidates.flatMap { prefix in variants(key).map { prefix.isEmpty ? $0 : prefix + " " + $0 } }
        }
        for candidate in candidates {
            if let filters = lexicon[candidate] { return Entry(filters: filters) }
            if keys.count > 1, fillerPhrases.contains(candidate) { return Entry(filters: []) }
        }
        return nil
    }

    static let lexicon: [String: [SearchFilter]] = {
        var d: [String: [SearchFilter]] = [:]
        func add(_ words: [String], _ filters: SearchFilter...) {
            for word in words { d[word] = filters }
        }
        // Kinds
        add(["movie", "movies", "film", "films", "flick", "flicks", "فيلم", "فلم", "افلام", "الافلام", "سينما"], .kind(.movie))
        add(["series", "show", "shows", "tv show", "tv shows", "tv series", "tv-series", "miniseries", "mini series",
             "مسلسل", "مسلسلات"], .kind(.series))
        add(["sitcom", "sitcoms"], .kind(.series), .genre(.comedy))
        add(["docuseries", "docu-series"], .kind(.series), .genre(.documentary))
        add(["kdrama", "kdramas", "k-drama", "k-dramas", "k drama"], .language(.korean), .genre(.drama))
        // Genres
        add(["action", "اكشن", "حركه"], .genre(.action))
        add(["adventure", "adventures", "مغامره", "مغامرات"], .genre(.adventure))
        add(["animation", "animated", "cartoon", "cartoons", "anime", "كرتون", "انمي", "انيميشن", "رسوم متحركه"], .genre(.animation))
        add(["comedy", "comedies", "comedic", "funny", "كوميدي", "كوميديا", "مضحك", "مضحكه", "فكاهي"], .genre(.comedy))
        add(["romcom", "romcoms", "rom-com", "rom-coms"], .genre(.romance), .genre(.comedy))
        add(["crime", "gangster", "gangsters", "heist", "جريمه", "جرائم", "اجرام", "بوليسي"], .genre(.crime))
        add(["documentary", "documentaries", "وثائقي"], .genre(.documentary))
        add(["drama", "dramas", "dramatic", "دراما", "درامي"], .genre(.drama))
        add(["family", "عائلي"], .genre(.family))
        add(["fantasy", "فانتازيا", "خيال"], .genre(.fantasy))
        add(["history", "historical", "تاريخي"], .genre(.history))
        add(["horror", "slasher", "رعب", "مرعب"], .genre(.horror))
        add(["kids", "children", "childrens", "children's", "kids'", "اطفال"], .genre(.kids))
        add(["mystery", "mysteries", "غموض"], .genre(.mystery))
        add(["romance", "romantic", "romances", "رومانسي", "رومانس"], .genre(.romance))
        add(["sci-fi", "scifi", "sci fi", "science fiction", "science-fiction", "خيال علمي"], .genre(.sciFi))
        add(["thriller", "thrillers", "suspense", "اثاره", "تشويق"], .genre(.thriller))
        add(["war", "حرب", "حروب", "حربي"], .genre(.war))
        // Languages and regions
        add(["arabic", "arab", "عربي"], .language(.arabic))
        add(["egyptian", "مصري"], .language(.egyptian))
        add(["syrian", "سوري"], .language(.syrian))
        add(["lebanese", "لبناني"], .language(.lebanese))
        add(["khaleeji", "gulf", "saudi", "emirati", "kuwaiti", "خليجي", "سعودي", "كويتي", "اماراتي"], .language(.gulf))
        add(["moroccan", "مغربي"], .language(.moroccan))
        add(["turkish", "تركي"], .language(.turkish))
        add(["korean", "كوري"], .language(.korean))
        add(["indian", "hindi", "bollywood", "هندي", "بوليوود"], .language(.indian))
        add(["english", "foreign", "american", "hollywood", "british", "اجنبي", "انجليزي", "امريكي"], .language(.english))
        add(["french", "فرنسي"], .language(.french))
        add(["spanish", "اسباني"], .language(.spanish))
        add(["german", "الماني"], .language(.german))
        add(["japanese", "ياباني"], .language(.japanese))
        add(["chinese", "صيني"], .language(.chinese))
        // Quality and rating
        add(["4k", "uhd", "ultra hd", "2160p", "فور كي"], .quality4K)
        add(["top rated", "top-rated", "toprated", "highly rated", "high rated", "highest rated", "best rated",
             "well rated", "best", "top", "greatest", "acclaimed", "critically acclaimed",
             "الاعلي تقييما", "الاعلي تقييم", "اعلي تقييم", "اعلي تقييما", "تقييم عالي", "افضل", "احسن"], .topRated)
        // Decades written as words
        for (words, start) in [
            (["fifties", "خمسينات", "خمسينيات"], 1950), (["sixties", "ستينات", "ستينيات"], 1960),
            (["seventies", "سبعينات", "سبعينيات"], 1970), (["eighties", "ثمانينات", "ثمانينيات"], 1980),
            (["nineties", "تسعينات", "تسعينيات"], 1990), (["noughties", "two thousands", "الفينات", "الفينيات"], 2000),
        ] {
            for word in words { d[word] = [.years(.decade(start))] }
        }
        return d
    }()

    /// Words that only connect: dropped when next to an understood word, kept otherwise ("the office").
    static let fillers: Set<String> = [
        "the", "a", "an", "from", "in", "of", "with", "and", "or", "for", "about", "to", "some", "any", "all", "good",
        "great", "nice", "new", "old", "early", "late", "mid", "era", "made", "released", "set", "me", "find", "watch",
        "something", "anything", "please", "year", "years", "language", "spoken", "dubbed", "subbed", "rated",
        "من", "في", "عن", "مع", "و", "او", "ذات", "بعض", "اي", "سنه", "عام", "زمن", "فتره", "جميل", "جميله", "حلو",
        "حلوه", "جيد", "جيده", "عايز", "اريد", "ابي", "ابغي", "بدي", "شي", "حاجه", "اعرض", "لغه", "مدبلج", "مترجم",
        "تقييم",
    ]

    static let fillerPhrases: Set<String> = [
        "show me", "find me", "give me", "i want", "i want to", "want to", "looking for", "to watch", "from the",
        "in the", "of the", "something like",
    ]

    // MARK: Years

    /// Finds the first year expression: "1990s", "'90s", "2010-2015", "from 2010 to 2015", "between 2010 and 2015",
    /// "since 2015", "after 2015", "before 2000", "until 2000", a bare year, or a decade word; also "من 2015 الى 2020",
    /// "بعد 2015", "قبل 2000", "التسعينات". Returns the span and the tokens it covers.
    static func findYears(_ tokens: [Token], currentYear: Int) -> (YearSpan, ClosedRange<Int>)? {
        let latest = currentYear + 1
        func year(_ i: Int) -> Int? {
            guard tokens.indices.contains(i), tokens[i].key.count == 4, tokens[i].key.allSatisfy(\.isASCII),
                  let y = Int(tokens[i].key), (1900...latest).contains(y) else { return nil }
            return y
        }
        func key(_ i: Int) -> String? { tokens.indices.contains(i) ? tokens[i].key : nil }
        let rangeWords: Set<String> = ["-", "to", "till", "until", "through", "thru", "and", "الي", "حتي", "لغايه", "و"]
        let fromWords: Set<String> = ["from", "since", "من", "منذ"]

        for i in tokens.indices {
            let k = tokens[i].key
            if let decade = decade(k, latest: latest) {
                return (.decade(decade), i...i)
            }
            // "2010-2015", "2010–15"
            if let m = k.wholeMatch(of: /(\d{4})-(\d{2}|\d{4})/), let a = Int(m.1), var b = Int(m.2) {
                if m.2.count == 2 { b += a / 100 * 100 }
                if (1900...latest).contains(a), (a...latest).contains(b) {
                    let start = i > 0 && fromWords.contains(tokens[i - 1].key) ? i - 1 : i
                    return (YearSpan(from: a, to: b), start...i)
                }
            }
            guard let y = year(i) else { continue }
            let previous = key(i - 1)
            // "Y1 to Y2", "between Y1 and Y2", "from Y1 to Y2"
            if let connector = key(i + 1), rangeWords.contains(connector), let y2 = year(i + 2), y2 >= y {
                let opener = previous.map { fromWords.contains($0) || $0 == "between" || $0 == "بين" } ?? false
                // "and" / "و" only form a range after "between" ("comedy 2010 and 2015" stays two years).
                if connector != "and" && connector != "و" || previous == "between" || previous == "بين" {
                    return (YearSpan(from: y, to: y2), (opener ? i - 1 : i)...(i + 2))
                }
            }
            switch previous ?? "" {
            case "since", "from", "منذ", "من": return (YearSpan(from: y, to: nil), (i - 1)...i)
            case "after", "بعد": return (YearSpan(from: y + 1, to: nil), (i - 1)...i)
            case "before", "قبل": return (YearSpan(from: nil, to: y - 1), (i - 1)...i)
            case "until", "till", "حتي": return (YearSpan(from: nil, to: y), (i - 1)...i)
            default: return (.year(y), i...i)
            }
        }
        return nil
    }

    /// "90s", "'90s", "90's", "1990s", "2000s" → the decade's first year.
    static func decade(_ key: String, latest: Int) -> Int? {
        if let m = key.wholeMatch(of: /'?(\d)0'?s/), let d = Int(m.1) {
            return d >= 3 ? 1900 + d * 10 : 2000 + d * 10
        }
        if let m = key.wholeMatch(of: /(\d{3})0'?s/), let d = Int(m.1) {
            let start = d * 10
            return (1900...latest).contains(start) ? start : nil
        }
        return nil
    }

    // MARK: Model suggestions

    /// Whether Apple's on-device model may be asked to read this search (when the user presses Return): only
    /// English (the model doesn't support Arabic), only when the rules left words they couldn't place, and only
    /// for phrases of three words or more.
    public static func shouldAskModel(_ parsed: ParsedSearch) -> Bool {
        guard !parsed.text.isEmpty, !parsed.query.unicodeScalars.contains(where: CategoryClassifier.isArabic) else { return false }
        let words = parsed.query.split(whereSeparator: \.isWhitespace)
        return words.count >= 3 && parsed.query.contains(where: \.isLetter)
    }

    /// Adds what the model understood to the rule-based result, keeping only what can be checked: kinds, genres and
    /// languages from the fixed lists, "top rated" only when the query says something like "good" or "classic",
    /// never years (the rules read years reliably; the model invents them), and title words only from the words the
    /// rules left over.
    public static func refine(_ rules: ParsedSearch, with suggestion: ModelSearchSuggestion) -> ParsedSearch {
        var result = rules
        func add(_ filter: SearchFilter) { if !result.filters.contains(filter) { result.filters.append(filter) } }

        if rules.kind == nil, let raw = suggestion.kind?.lowercased() {
            if ["movie", "movies", "film"].contains(raw) { add(.kind(.movie)) }
            if ["series", "show", "tv show", "tv"].contains(raw) { add(.kind(.series)) }
        }
        for raw in suggestion.genres.prefix(2) {
            let key = raw.lowercased().replacingOccurrences(of: "-", with: "")
            if let genre = SearchGenre.allCases.first(where: { $0.rawValue.lowercased() == key || $0.title.lowercased().replacingOccurrences(of: "-", with: "") == key }) {
                add(.genre(genre))
            }
        }
        if rules.languages.isEmpty, let raw = suggestion.languages.first?.lowercased(),
           let language = SearchLanguage.allCases.first(where: { $0.rawValue == raw }) {
            add(.language(language))
        }
        let leftover = rules.text.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        let qualityWords: Set<String> = ["good", "great", "classic", "classics", "masterpiece", "masterpieces", "award", "award-winning", "popular", "excellent", "must-see"]
        if suggestion.topRated, leftover.contains(where: { qualityWords.contains($0) }) { add(.topRated) }

        // Title words: only words the rules couldn't place, in their original form.
        let suggested = Set(suggestion.titleWords.split(whereSeparator: \.isWhitespace).map { fold(String($0)) })
        let kept = rules.text.split(whereSeparator: \.isWhitespace).filter { suggested.contains(fold(String($0))) }
        result.text = kept.joined(separator: " ")
        return result
    }

    // MARK: Titles

    /// Folded words for title comparison: punctuation and separators become spaces.
    public static func titleKey(_ s: String) -> String {
        let folded = fold(s)
        let mapped = folded.unicodeScalars.map { $0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) ? String($0) : " " }.joined()
        return mapped.split(separator: " ").joined(separator: " ")
    }

    /// Whether a library title "is" the query: a one-word query must be the whole title (a leading two-letter
    /// language tag like "EN -" aside); a longer query must appear in the title as whole words, the last of which
    /// may still be being typed ("family g" → "Family Guy").
    public static func title(_ title: String, matches query: String) -> Bool {
        let q = titleKey(query)
        guard !q.isEmpty else { return false }
        let t = titleKey(title)
        if !q.contains(" ") {
            if t == q { return true }
            let words = t.split(separator: " ")
            return words.count == 2 && words[0].count == 2 && words[1] == q
        }
        return (" " + t).contains(" " + q)
    }

    /// LIKE patterns for a folded Arabic word in unfolded text: the word plus the usual spellings of its first alef
    /// and last letter ("افلام" → "أفلام", "تركيه" → "تركية").
    static func spellings(_ folded: String) -> [String] {
        guard folded.unicodeScalars.contains(where: CategoryClassifier.isArabic) else { return [folded] }
        var starts = [folded]
        if folded.hasPrefix("ال") && folded.dropFirst(2).hasPrefix("ا") {
            starts += ["الأ", "الإ"].map { $0 + folded.dropFirst(3) }
        } else if folded.hasPrefix("ا") {
            starts += ["أ", "إ"].map { $0 + folded.dropFirst() }
        }
        var out: [String] = []
        for s in starts {
            out.append(s)
            if s.hasSuffix("ه") { out.append(String(s.dropLast()) + "ة") }
            if s.hasSuffix("ي") { out.append(String(s.dropLast()) + "ى") }
        }
        return out
    }
}

/// What the on-device language model filled in for a search (raw strings; `QueryUnderstanding.refine` validates
/// them).
public struct ModelSearchSuggestion: Sendable, Hashable {
    public var kind: String?
    public var genres: [String]
    public var languages: [String]
    public var topRated: Bool
    public var titleWords: String

    public init(kind: String? = nil, genres: [String] = [], languages: [String] = [], topRated: Bool = false, titleWords: String = "") {
        self.kind = kind
        self.genres = genres
        self.languages = languages
        self.topRated = topRated
        self.titleWords = titleWords
    }
}
