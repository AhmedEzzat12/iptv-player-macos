import Foundation

/// Turns messy IPTV VOD names into catalogue search queries and scores search results against them.
///
/// IPTV names carry language/platform prefixes (`EN - `, `|AR|`, `NF:`, `4K-`), quality and packaging
/// tokens (`HDTC`, `WEB-DL`, `MULTI-SUB`), bracketed junk and season markers. A wrong match is worse than
/// none, so a candidate must reach `acceptScore`: an exact (normalised) title, or a close one backed by
/// the year.
public enum TitleMatcher {
    /// A cleaned search query.
    public struct Query: Sendable, Hashable {
        /// Cleaned title used for searching, e.g. "The Matrix".
        public var title: String
        /// Release year (from the provider's year field, else from the name).
        public var year: Int?
        /// Set when the name ended in a bare year-like number ("Blade Runner 2049", "Oppenheimer 2023"):
        /// `title`/`year` read it as a year, `literalTitle` keeps it as part of the title. Both readings
        /// are scored and the better one wins.
        public var literalTitle: String?
        /// Year that goes with `literalTitle` (only a year that came from elsewhere, e.g. the provider field).
        var literalYear: Int?

        public init(title: String, year: Int? = nil, literalTitle: String? = nil) {
            self.title = title
            self.year = year
            self.literalTitle = literalTitle
        }
    }

    /// A search result to score: its title(s) and year range (series run "2008–2013" → 2008...2013).
    struct Candidate: Sendable {
        var titles: [String]
        var year: Int?
        var endYear: Int?
    }

    /// Minimum score for a match. Exact title = 1.0; year agreement adds up to 0.15, a clear year
    /// disagreement subtracts 0.35.
    static let acceptScore = 0.85

    // MARK: - Cleaning

    /// Cleans an IPTV name (and optional provider year field) into a search query; nil when nothing
    /// meaningful remains.
    public static func query(name: String, year: String? = nil, kind: MediaMetadata.Kind) -> Query? {
        var s = name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Scene-style "The.Matrix.1999.1080p" (dots instead of spaces).
        if !s.contains(" "), s.filter({ $0 == "." }).count >= 2 {
            s = s.replacingOccurrences(of: ".", with: " ")
        }
        s = stripPrefixTags(s)
        s = stripSuffixTags(s)

        let split = TitleParser.splitYear(s)
        s = split.title
        let nameYear = split.year.flatMap(Int.init)
        let fieldYear = year.flatMap(parseYear)

        let debracketed = removeBrackets(s)
        s = collapse(debracketed).isEmpty ? s.replacingOccurrences(of: #"[\[\]\(\)\{\}]"#, with: " ", options: .regularExpression) : debracketed
        s = removeJunk(s)
        if kind == .series { s = removeSeasonMarker(s) }
        s = collapse(s)

        var resolvedYear = fieldYear ?? nameYear
        var literal: String?
        var literalYear: Int?
        // A bare trailing year-like number: "Oppenheimer 2023" vs "Blade Runner 2049".
        if let m = firstMatch(trailingNumber, in: s), let headR = Range(m.range(at: 1), in: s),
           let numR = Range(m.range(at: 2), in: s), let number = Int(s[numR]) {
            let head = collapse(String(s[headR]))
            if !head.isEmpty {
                if resolvedYear == nil {
                    resolvedYear = number
                    literal = s
                    s = head
                } else if resolvedYear == number {
                    literal = s
                    literalYear = resolvedYear
                    s = head
                }
                // A different known year: the number is part of the title ("Blade Runner 2049" (2017)).
            }
        }

        s = reorderArticle(s)
        guard !s.isEmpty, s.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        var query = Query(title: s, year: resolvedYear, literalTitle: literal.map(reorderArticle))
        query.literalYear = literalYear
        return query
    }

    /// Display-friendly cleaned title ("EN - The Matrix (1999) [4K]" → "The Matrix"), or the input.
    public static func cleanTitle(_ name: String, kind: MediaMetadata.Kind = .movie) -> String {
        guard let q = query(name: name, kind: kind) else { return name }
        return q.literalTitle ?? q.title
    }

    /// Tags that may prefix (or suffix) a title with a separator: languages, countries, platforms, quality.
    static let knownTags: Set<String> = {
        var tags: Set<String> = [
            "EN", "AR", "UK", "LAT", "LATAM", "LATINO", "ENG", "ARA", "ARB", "FRE", "FRA", "GER", "DEU", "SPA",
            "ESP", "ITA", "POR", "TUR", "RUS", "HIN", "PER", "FAR", "KUR", "URD", "SWE", "NOR", "DAN", "FIN",
            "POL", "GRE", "HEB", "CHI", "JAP", "JPN", "KOR", "NF", "NFX", "NETFLIX", "AMZ", "AMZN", "AMAZON",
            "PRIME", "DSNP", "DSNY", "DISNEY", "DISNEY+", "HBO", "HBOMAX", "HMAX", "MAX", "ATVP", "APPLE",
            "APPLETV", "HULU", "PCOK", "PEACOCK", "PMTP", "PARAMOUNT", "PARAMOUNT+", "STARZ", "SHO", "OSN",
            "OSN+", "SHAHID", "STC", "WATCHIT", "YANGO", "TOD", "BEIN", "CRAV", "CRAVE", "MUBI", "4K", "8K",
            "UHD", "FHD", "HD", "SD", "HDR", "3D", "VIP", "MULTI", "SUB", "DUB", "VOD", "VOSTFR", "VF", "VO",
            "4K+", "IMAX", "TOP", "NEW",
        ]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            tags.insert(region.identifier.uppercased())
        }
        for language in Locale.LanguageCode.isoLanguageCodes where language.identifier.count == 2 {
            tags.insert(language.identifier.uppercased())
        }
        return tags
    }()

    /// "EN - ", "AR:", "NF: ", "4K-", "AR| " at the start (the tag itself is checked separately).
    static let prefixTag = try! NSRegularExpression(pattern: #"^\s*([A-Za-z0-9][A-Za-z0-9+]{1,8})\s*[:|\-–—]+\s*(?=\S)"#)
    /// "|AR|", "[US]", "(EN)", "[MULTI-SUB]" at the start.
    static let prefixBracket = try! NSRegularExpression(pattern: #"^\s*[\[\(\|]\s*([^\]\)\|]{1,24}?)\s*[\]\)\|]\s*[:|\-–—]*\s*"#)
    /// " - EN", " | AR" at the end.
    static let suffixTag = try! NSRegularExpression(pattern: #"\s*[:|\-–—]+\s*([A-Za-z0-9][A-Za-z0-9+]{1,8})\s*$"#)

    static func stripPrefixTags(_ input: String) -> String {
        var s = input
        for _ in 0..<6 {
            var changed = false
            if let m = firstMatch(prefixBracket, in: s), let tagR = Range(m.range(at: 1), in: s), let whole = Range(m.range, in: s) {
                let tag = String(s[tagR])
                let rest = String(s[whole.upperBound...])
                let digitsOnly = tag.allSatisfy(\.isNumber)
                if !digitsOnly, rest.contains(where: \.isLetter), tag == tag.uppercased() || isJunkPhrase(tag) {
                    s = rest
                    changed = true
                }
            }
            if !changed, let m = firstMatch(prefixTag, in: s), let tagR = Range(m.range(at: 1), in: s), let whole = Range(m.range, in: s) {
                let tag = String(s[tagR])
                if tag == tag.uppercased(), knownTags.contains(tag) {
                    s = String(s[whole.upperBound...])
                    changed = true
                }
            }
            if !changed { break }
        }
        return s
    }

    static func stripSuffixTags(_ input: String) -> String {
        var s = input
        for _ in 0..<3 {
            guard let m = firstMatch(suffixTag, in: s), let tagR = Range(m.range(at: 1), in: s), let whole = Range(m.range, in: s) else { break }
            let tag = String(s[tagR])
            let head = String(s[..<whole.lowerBound])
            guard tag == tag.uppercased(), knownTags.contains(tag), head.contains(where: \.isLetter) else { break }
            s = head
        }
        return s
    }

    static let squareOrCurly = try! NSRegularExpression(pattern: #"\[[^\]]*\]|\{[^\}]*\}"#)
    static let parenthesised = try! NSRegularExpression(pattern: #"\(([^\)]*)\)"#)

    /// Drops `[...]`/`{...}` groups and `(...)` groups unless they hold only digits ("(500) Days of Summer").
    static func removeBrackets(_ input: String) -> String {
        var s = replace(squareOrCurly, in: input, with: " ")
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in parenthesised.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, inner.allSatisfy(\.isNumber) { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + " "
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        s = out
        // Unbalanced leftovers: "Title (4K" / "Title 4K)".
        s = s.replacingOccurrences(of: #"[\[\]\{\}]"#, with: " ", options: .regularExpression)
        return s
    }

    private static let boundaryStart = #"(?<![\p{L}\p{N}])"#
    private static let boundaryEnd = #"(?![\p{L}\p{N}])"#

    /// Quality, packaging, language-track and edition tokens (case-insensitive: distinctive enough).
    static let junkInsensitive = try! NSRegularExpression(pattern: boundaryStart + #"(?:"#
        + #"4k\s*uhd|4k|8k|uhd|fhd|qhd|hdr10\+?|hdr|dolby[ .\-]?vision|hdtc|hdcam|hdts|hd[ .\-]?rip|hdtv|"#
        + #"web[ .\-]?dl|web[ .\-]?rip|blu[ .\-]?ray|brrip|bdrip|dvdrip|dvdscr|x26[45]|h\.?26[45]|hevc|10bit|"#
        + #"aac|ac3|ddp?5[ .]1|atmos|2160p|1080p|1080i|720p|576p|480p|"#
        + #"multi[ .\-]?subs?|multi[ .\-]?audio|dual[ .\-]?audio|dubbed|subbed|subtitled|vostfr|truefrench|"#
        + #"(?:arabic|english|eng|ar|en|fr|french|turkish|tr|hindi|spanish|persian|farsi|kurdish|urdu)[ .\-]?(?:subs?|subbed|subtitled|subtitles|dub|dubbed)|"#
        + #"remastered|unrated|extended(?:[ .](?:cut|edition))?|directors?['’]?s?[ .]cut|theatrical[ .]cut|imax(?:[ .]edition)?|"#
        + #"فيلم|مسلسل|مترجمة?|مدبلجة?|كاملة?|حصريا|اون لاين|بجودة عالية"#
        + #")"# + boundaryEnd, options: [.caseInsensitive])

    /// Short tokens that are only junk in upper case ("CAM" yes, the film "Cam" no; "WEB" yes, "Charlotte's Web" no).
    static let junkUppercase = try! NSRegularExpression(pattern: boundaryStart
        + #"(?:HD|SD|TS|TC|CAM|WEB|DUB|SUB|SUBS|MULTI|DV|HC|VIP)"# + boundaryEnd)

    static func isJunkPhrase(_ s: String) -> Bool {
        let stripped = collapse(replace(junkInsensitive, in: s, with: " "))
        return stripped.isEmpty
    }

    /// Removes junk tokens. A name that is nothing but junk ("4K", "MULTI-SUB") ends up empty → no query.
    static func removeJunk(_ input: String) -> String {
        replace(junkUppercase, in: replace(junkInsensitive, in: input, with: " "), with: " ")
    }

    static let seasonMarker = try! NSRegularExpression(pattern: boundaryStart + #"(?:"#
        + #"S\d{1,2}(?:[\s._\-]*E\d{1,3})?|"#
        + #"(?:season|saison|temporada|staffel|sezon|stagione|seizoen)[\s._\-]*(?:\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten)|"#
        + #"complete[\s._\-]+series|الموسم|الحلقة"#
        + #")"# + boundaryEnd + #".*$"#, options: [.caseInsensitive])

    /// "Wednesday S01", "Breaking Bad - Season 1", "Game of Thrones S08E06 The Iron Throne" → the show name.
    static func removeSeasonMarker(_ input: String) -> String {
        let s = replace(seasonMarker, in: input, with: "")
        return collapse(s).isEmpty ? input : s
    }

    static let trailingNumber = try! NSRegularExpression(pattern: #"^(.*\S)\s+((?:19|20)\d{2})$"#)
    static let articleSuffix = try! NSRegularExpression(pattern: #"^(.+),\s*(The|A|An)$"#, options: [.caseInsensitive])
    static let yearPattern = try! NSRegularExpression(pattern: #"(?<!\d)((?:19|20)\d{2})(?!\d)"#)

    /// "Matrix, The" → "The Matrix".
    static func reorderArticle(_ s: String) -> String {
        guard let m = firstMatch(articleSuffix, in: s), let head = Range(m.range(at: 1), in: s),
              let article = Range(m.range(at: 2), in: s) else { return s }
        return "\(s[article]) \(s[head])"
    }

    /// First plausible year in a string ("2024", "2024-03-01", "2008–2013").
    static func parseYear(_ s: String) -> Int? {
        firstMatch(yearPattern, in: s).flatMap { Range($0.range(at: 1), in: s) }.flatMap { Int(s[$0]) }
    }

    /// Start and end year of a range such as "2008–2013" or "2025-" (end nil when open/missing).
    static func parseYearRange(_ s: String?) -> (start: Int?, end: Int?) {
        guard let s else { return (nil, nil) }
        let years = yearPattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
            .compactMap { Range($0.range(at: 1), in: s).flatMap { Int(s[$0]) } }
        return (years.first, years.count > 1 ? years[1] : nil)
    }

    /// Collapses whitespace and trims separators.
    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—_.:|,;/+"))
    }

    // MARK: - Scoring

    static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8",
        "ix": "9", "x": "10",
    ]

    /// Comparison tokens: case/diacritic/width-folded, "&" → "and", apostrophes dropped, Roman numerals and
    /// number words as digits, common Arabic letter variants unified.
    static func tokens(_ s: String) -> [String] {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t.removeAll { "'’`´ʼ".contains($0) }
        var out: [String] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            out.append(numberWords[current] ?? current)
            current = ""
        }
        for ch in t {
            if ch.isLetter || ch.isNumber {
                switch ch {
                case "أ", "إ", "آ": current.append("ا")
                case "ة": current.append("ه")
                case "ى": current.append("ي")
                default: current.append(ch)
                }
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static let articles: Set<String> = ["the", "a", "an"]

    /// Title similarity in 0...1: exact > prefix/suffix containment > token overlap.
    static func titleSimilarity(_ query: String, _ candidate: String) -> Double {
        let q = tokens(query), c = tokens(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        if q == c || q.joined() == c.joined() { return 1 }
        let qa = q.first.map(articles.contains) == true && q.count > 1 ? Array(q.dropFirst()) : q
        let ca = c.first.map(articles.contains) == true && c.count > 1 ? Array(c.dropFirst()) : c
        if qa == ca || qa.joined() == ca.joined() { return 0.97 }

        var best = 0.0
        if c.count > q.count, Array(c.prefix(q.count)) == q || Array(c.suffix(q.count)) == q {
            best = max(best, 0.6 + 0.3 * Double(q.count) / Double(c.count))
        }
        if q.count > c.count, Array(q.prefix(c.count)) == c {
            best = max(best, 0.55 + 0.3 * Double(c.count) / Double(q.count))
        }
        // Dice coefficient over token multisets.
        var pool = c
        var common = 0
        for token in q {
            if let i = pool.firstIndex(of: token) {
                pool.remove(at: i)
                common += 1
            }
        }
        best = max(best, 0.75 * 2 * Double(common) / Double(q.count + c.count))
        return best
    }

    /// Year agreement bonus/penalty. Series accept any year inside their run. A candidate without a year
    /// can't confirm the query's year, so an exact title alone isn't enough then (Cinemeta lists unreleased
    /// and placeholder entries without one).
    static func yearAdjustment(query year: Int?, candidate: Candidate, kind: MediaMetadata.Kind) -> Double {
        guard let year else { return 0 }
        guard let start = candidate.year else { return -0.2 }
        switch kind {
        case .movie:
            switch abs(year - start) {
            case 0: return 0.15
            case 1: return 0.08
            case 2: return -0.1
            default: return -0.35
            }
        case .series:
            if abs(year - start) <= 1 { return 0.15 }
            // Still-running shows have no end year: any later year is inside the run (and Int.max + 1 would trap).
            if year > start, candidate.endYear.map({ year <= $0 + 1 }) ?? true { return 0.05 }
            return -0.35
        }
    }

    /// Best score of a candidate over the query's readings and the candidate's titles.
    static func score(_ query: Query, _ candidate: Candidate, kind: MediaMetadata.Kind) -> Double {
        var readings = [(query.title, query.year)]
        if let literal = query.literalTitle { readings.append((literal, query.literalYear)) }
        var best = -Double.infinity
        for (title, year) in readings {
            let similarity = candidate.titles.map { titleSimilarity(title, $0) }.max() ?? 0
            guard similarity > 0 else { continue }
            best = max(best, similarity + yearAdjustment(query: year, candidate: candidate, kind: kind))
        }
        return best.isFinite ? best : 0
    }

    /// Index and score of the best acceptable candidate (ties go to the earlier, i.e. more popular, result).
    static func bestMatch(_ query: Query, _ candidates: [Candidate], kind: MediaMetadata.Kind) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (i, candidate) in candidates.enumerated() {
            let s = score(query, candidate, kind: kind)
            if s >= acceptScore, s > (best?.score ?? -1) + 0.0001 { best = (i, s) }
        }
        return best
    }

    // MARK: - Regex helpers

    static func firstMatch(_ regex: NSRegularExpression, in s: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
