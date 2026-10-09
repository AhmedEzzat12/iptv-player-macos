import Foundation

/// Smart guide matching (Settings › AI): picks the guide channel whose name is closest to a playlist channel's,
/// for channels that neither the user's override, the tvg-id nor the exact normalised name ties to a guide.
///
/// Names are cleaned harder than `ChannelNameNormalizer` does: quality/VIP/backup tags, country and language
/// prefixes ("UK:", "|AR|", "VIP DE:") and suffixes, a trailing "Channel"; number words become digits and Arabic
/// is transliterated to Latin. A wrong guide is worse than none, so a candidate has to pass hard guards — the same
/// numbers ("beIN Sports 1" never gets "beIN Sports 2"), the same timeshift ("+1" only matches "+1"), the same
/// east/west feed, no conflicting country — then agree on every word (plurals and long-word typos aside) and score
/// at least `threshold` on word agreement plus character similarity. Arabic and Latin names are compared by
/// consonant skeleton only ("الجزيرة" ~ "Al Jazeera"). Near-ties between different names are refused, not guessed;
/// the same name in several feeds goes to the feed with programmes, then the channel's own playlist's feed.
/// Results never depend on input order.
public struct GuideMatcher: Sendable {
    /// A guide channel that can be matched.
    public struct Candidate: Sendable, Hashable {
        /// Guide key (`feedId|xmltvId`), or any id the caller wants back.
        public var key: String
        /// Names to compare against (see `names(displayName:xmltvId:)`).
        public var names: [String]
        /// Playlist whose guide feed this is; nil for a global feed.
        public var sourceId: String?
        /// Feed priority within its playlist (lower first).
        public var priority: Int
        public var hasPrograms: Bool

        public init(key: String, names: [String], sourceId: String? = nil, priority: Int = 0, hasPrograms: Bool = true) {
            self.key = key
            self.names = names
            self.sourceId = sourceId
            self.priority = priority
            self.hasPrograms = hasPrograms
        }
    }

    public struct Match: Sendable, Hashable {
        public var key: String
        public var score: Double
    }

    /// Minimum score for a match (an identical cleaned name scores 1).
    public static let threshold = 0.8
    /// Score of an Arabic ↔ Latin match by consonant skeleton.
    static let crossScriptScore = 0.85
    /// Different names scoring within this of the best one make the match ambiguous.
    static let tieWindow = 0.03

    private struct Entry: Sendable {
        let candidate: Int
        let name: Name
    }

    private let candidates: [Candidate]
    private let entries: [Entry]
    private let byStem: [String: [Int]]
    private let byCompact: [String: [Int]]
    private let bySkeleton: [String: [Int]]

    public init(candidates: [Candidate]) {
        // Sorted so equal inputs in any order build the same index.
        let sorted = candidates.sorted { $0.key < $1.key }
        var entries: [Entry] = []
        var byStem: [String: [Int]] = [:]
        var byCompact: [String: [Int]] = [:]
        var bySkeleton: [String: [Int]] = [:]
        for (index, candidate) in sorted.enumerated() {
            var names = candidate.names.compactMap(Self.analyze)
            // A country known from one name (the XMLTV id's ".uk") applies to the candidate's other names too.
            if let country = names.lazy.compactMap(\.country).first {
                for i in names.indices where names[i].country == nil { names[i].country = country }
            }
            var seen = Set<Name>()
            for name in names where seen.insert(name).inserted {
                let e = entries.count
                entries.append(Entry(candidate: index, name: name))
                for stem in Self.stemKeys(name) { byStem[stem, default: []].append(e) }
                byCompact[name.compact, default: []].append(e)
                if name.skeletonLetters >= 3 { bySkeleton[name.skeleton, default: []].append(e) }
            }
        }
        self.candidates = sorted
        self.entries = entries
        self.byStem = byStem
        self.byCompact = byCompact
        self.bySkeleton = bySkeleton
    }

    /// Best guide channel for a playlist channel name, or nil when nothing is close enough or it's ambiguous.
    public func match(_ channelName: String, sourceId: String?) -> Match? {
        guard let name = Self.analyze(channelName) else { return nil }
        return match(name, sourceId: sourceId)
    }

    func match(_ query: Name, sourceId: String?) -> Match? {
        // Retrieval: a match agrees on every word and number, so the rarest two word stems (two, in case one has a
        // typo) with the same numbers find it; the compact form finds spacing differences ("Euro Sport"), the
        // skeleton finds the other script.
        let lists = Self.stemKeys(query).subtracting(Self.softTokens.map { Self.stemKey($0, query) })
            .map { ($0, byStem[$0] ?? []) }
            .sorted { ($0.1.count, $0.0) < ($1.1.count, $1.0) }
        var pool = lists.prefix(2).flatMap(\.1)
        pool += byCompact[query.compact] ?? []
        if query.skeletonLetters >= 3 { pool += bySkeleton[query.skeleton] ?? [] }
        pool.sort()

        var best: [Int: (score: Double, entry: Int)] = [:]   // candidate → its best-scoring name
        var previous = -1
        for e in pool where e != previous {
            previous = e
            let entry = entries[e]
            let s = Self.score(query, entry.name)
            if s >= Self.threshold, s > best[entry.candidate]?.score ?? 0 { best[entry.candidate] = (s, e) }
        }
        guard let top = best.values.map(\.score).max() else { return nil }

        // Like exact matches: guides with programmes first, then this playlist's own feed, then global feeds.
        func rank(_ c: Candidate) -> (Int, Int) {
            (c.hasPrograms ? 0 : 1, sourceId != nil && c.sourceId == sourceId ? 0 : (c.sourceId == nil ? 1 : 2))
        }
        let contenders = best.filter { $0.value.score >= top - Self.tieWindow }
        guard let firstRank = contenders.keys.map({ rank(candidates[$0]) }).min(by: { $0 < $1 }) else { return nil }
        let finalists = contenders.filter { rank(candidates[$0.key]) == firstRank }
        // Two different names that fit (almost) equally well: refuse rather than guess.
        guard Set(finalists.values.map { entries[$0.entry].name.compact }).count == 1 else { return nil }
        let pick = finalists.min { a, b in
            let x = candidates[a.key], y = candidates[b.key]
            return (x.priority, -a.value.score, x.key) < (y.priority, -b.value.score, y.key)
        }
        return pick.map { Match(key: candidates[$0.key].key, score: $0.value.score) }
    }

    /// Names to match a guide channel by: its display name and, when it reads like one, its XMLTV id
    /// ("BBCOne.uk@SD" → "BBCOne uk", which also tells the country).
    public static func names(displayName: String, xmltvId: String) -> [String] {
        var id = xmltvId
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        id = id.replacingOccurrences(of: #"[._\-]+"#, with: " ", options: .regularExpression)
        let letters = id.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 2 else { return [displayName] }
        return [displayName, id]
    }

    // MARK: - Names

    /// A cleaned, comparable channel name.
    struct Name: Sendable, Hashable {
        /// Words, lowercased Latin (Arabic transliterated), tags removed, number words as digits.
        var tokens: [String]
        /// Words that must find a partner (all but filler words like "the").
        var hardCount: Int
        var compact: String
        var scalars: [Unicode.Scalar]
        /// Number tokens, sorted: must agree exactly.
        var numbers: [String]
        /// "+1" → 1; 0 for none.
        var timeshift: Int
        /// east/west/pacific feed words, sorted.
        var region: [String]
        /// Canonical country from a prefix/suffix tag ("UK:", "… US"), when there was one.
        var country: String?
        /// Written (at least partly) in Arabic script.
        var arabic: Bool
        /// Consonant skeleton used between Arabic and Latin names.
        var skeleton: String
        var skeletonLetters: Int
    }

    /// Cleans a name; nil when nothing comparable is left.
    static func analyze(_ raw: String) -> Name? {
        var s = raw.precomposedStringWithCompatibilityMapping
        let arabic = s.unicodeScalars.contains(where: isArabic)
        if arabic {
            s = s.applyingTransform(.toLatin, reverse: false) ?? s
            s = s.replacingOccurrences(of: "ẗ", with: "a")   // ta marbuta reads as "a" (الجزيرة → aljzyra)
        }
        s = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        s.removeAll { "ʿʾʹ'’`".contains($0) }

        var timeshift = 0
        if let m = timeshiftPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r = Range(m.range(at: 1), in: s), let full = Range(m.range, in: s) {
            timeshift = Int(s[r]) ?? 0
            s.replaceSubrange(full, with: " ")
        }
        let debracketed = bracketPattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        if debracketed.contains(where: \.isLetter) { s = debracketed }

        var parts = tokenize(s)
        var country: String?

        // Leading tags and country/language prefixes ("VIP DE: ZDF", "|AR| MBC 2", "AR - الجزيرة", "UK BBC One").
        while parts.count > 1 {
            let t = parts[0]
            if tagTokens.contains(t.text) {
                parts.removeFirst()
            } else if isPrefixCode(t) {
                country = country ?? countryCodes[t.text]
                parts.removeFirst()
            } else {
                break
            }
        }

        // Tags anywhere; "Backup 2" goes as a whole.
        var words: [String] = []
        var i = 0
        while i < parts.count {
            let t = parts[i].text
            if backupTokens.contains(t) {
                if i + 1 < parts.count, isNumber(parts[i + 1].text) { i += 1 }
            } else if !tagTokens.contains(t) {
                words.append(t)
            }
            i += 1
        }
        if words.isEmpty { words = parts.map(\.text) }

        // "mbc2" → mbc 2; "01" → 1; "one" → 1.
        var tokens: [String] = []
        for w in words {
            for part in splitDigits(w) {
                if isNumber(part) {
                    tokens.append(String(Int(part.prefix(9)) ?? 0))
                } else {
                    tokens.append(numberWords[part] ?? part)
                }
            }
        }

        // Trailing country codes and "Channel"; a leading Arabic "قناة" (channel). Not trailing language codes:
        // "Al Jazeera EN" is another channel than "Al Jazeera".
        while tokens.count > 1 {
            let last = tokens[tokens.count - 1]
            if let code = countryCodes[last], !ambiguousCodes.contains(last) {
                country = country ?? code
                tokens.removeLast()
            } else if last == "channel" {
                tokens.removeLast()
            } else {
                break
            }
        }
        if tokens.count > 1, tokens[0] == "qnaa" { tokens.removeFirst() }

        let region = tokens.filter { regionTokens.contains($0) }
        if region.count < tokens.count { tokens.removeAll { regionTokens.contains($0) } }
        guard !tokens.isEmpty else { return nil }

        let compact = tokens.joined()
        guard compact.count >= 2 else { return nil }
        let skeleton = skeleton(of: tokens)
        return Name(tokens: tokens, hardCount: tokens.filter { !softTokens.contains($0) }.count, compact: compact,
                    scalars: Array(compact.unicodeScalars), numbers: tokens.filter(isNumber).sorted(), timeshift: timeshift,
                    region: region.sorted(), country: country, arabic: arabic, skeleton: skeleton,
                    skeletonLetters: skeleton.filter(\.isLetter).count)
    }

    // MARK: - Scoring

    /// 0 when a guard fails; 1 for the same cleaned name.
    static func score(_ a: Name, _ b: Name) -> Double {
        guard a.numbers == b.numbers, a.timeshift == b.timeshift, a.region == b.region else { return 0 }
        if let x = a.country, let y = b.country, x != y { return 0 }
        if a.compact == b.compact { return 1 }
        if a.arabic != b.arabic {
            // A transliteration is too rough for character similarity; only the same consonants count.
            return a.skeletonLetters >= 3 && a.skeleton == b.skeleton ? crossScriptScore : 0
        }
        // Every word needs a partner, so the word counts agree (cheap check first).
        guard a.hardCount == b.hardCount else { return 0 }
        let shorter = min(a.scalars.count, b.scalars.count)
        let longer = max(a.scalars.count, b.scalars.count)
        // Short names ("CBS" ~ "CBC") are too easy to confuse: only identical ones count (above).
        guard shorter >= 4 else { return 0 }
        guard 0.6 * Double(shorter) / Double(longer) + 0.4 >= threshold else { return 0 }
        guard let words = wordAgreement(a.tokens, b.tokens) else { return 0 }
        let chars = 1 - Double(editDistance(a.scalars, b.scalars)) / Double(longer)
        return 0.6 * chars + 0.4 * words
    }

    /// Every word of each name must have a partner in the other (exactly 1, a plural/typo variant 0.9); filler words
    /// may be missing. nil when a meaningful word is left over ("Sky Sports" vs "Sky Sports News").
    static func wordAgreement(_ a: [String], _ b: [String]) -> Double? {
        var used = [Bool](repeating: false, count: b.count)
        var total = 0.0
        for word in a {
            if let j = b.indices.first(where: { !used[$0] && b[$0] == word }) {
                used[j] = true
                total += 1
            } else if let j = b.indices.first(where: { !used[$0] && isVariant(word, b[$0]) }) {
                used[j] = true
                total += 0.9
            } else if !softTokens.contains(word) {
                return nil
            }
        }
        for j in b.indices where !used[j] && !softTokens.contains(b[j]) { return nil }
        let counted = max(a.filter { !softTokens.contains($0) }.count, b.filter { !softTokens.contains($0) }.count, 1)
        return min(1, total / Double(counted))
    }

    /// "sport"/"sports", or one typo in a long word ("documentary"/"documentry"). Never between numbers.
    static func isVariant(_ a: String, _ b: String) -> Bool {
        guard !isNumber(a), !isNumber(b) else { return false }
        if min(a.count, b.count) >= 4, b == a + "s" || a == b + "s" { return true }
        guard a.count >= 7, b.count >= 7, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(Array(a.unicodeScalars), Array(b.unicodeScalars)) <= 1
    }

    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Consonants only, with the article dropped and letters Arabic doesn't distinguish merged:
    /// "Al Jazeera" and "aljzyra" (الجزيرة) both give "jzr".
    static func skeleton(of tokens: [String]) -> String {
        var out = ""
        for token in tokens where token != "al" && token != "el" {
            var t = token
            if t.count >= 5, t.hasPrefix("al") || t.hasPrefix("el"), t.allSatisfy(\.isLetter) { t.removeFirst(2) }
            let chars = Array(t)
            var mapped = ""
            for (i, c) in chars.enumerated() {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                switch c {
                case "a", "e", "i", "o", "u", "y", "w": continue
                case "c": mapped.append(next == "e" || next == "i" || next == "y" ? "s" : "k")
                case "q": mapped.append("k")
                case "z": mapped.append("s")
                case "x": mapped.append("ks")
                case "g": mapped.append("j")
                case "p": mapped.append(next == "h" ? "f" : "b")
                case "v": mapped.append("f")
                case "h" where i > 0 && chars[i - 1] == "p": continue
                default: mapped.append(c)
                }
            }
            for c in mapped where out.last != c { out.append(c) }
        }
        return out
    }

    // MARK: - Tokens

    struct RawToken {
        var text: String
        /// What follows the word: ":", "|", "]" or ")" (strong), a dash, or just space.
        var separator: Separator = .none
        enum Separator { case none, dash, strong }
    }

    static func tokenize(_ s: String) -> [RawToken] {
        var tokens: [RawToken] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(RawToken(text: current)) }
            current = ""
        }
        for ch in s {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
                continue
            }
            flush()
            switch ch {
            case ":", "|", "]", ")", "»":
                if !tokens.isEmpty { tokens[tokens.count - 1].separator = .strong }
            case "-", "–", "—":
                if !tokens.isEmpty, tokens[tokens.count - 1].separator == .none { tokens[tokens.count - 1].separator = .dash }
            case "+":
                tokens.append(RawToken(text: "plus"))
            case "&":
                tokens.append(RawToken(text: "and"))
            default:
                break
            }
        }
        flush()
        return tokens
    }

    static func isPrefixCode(_ t: RawToken) -> Bool {
        guard t.text.allSatisfy(\.isLetter) else { return false }
        let known = countryCodes[t.text] != nil || languageCodes.contains(t.text)
        switch t.separator {
        case .strong: return known || (2...3).contains(t.text.count)
        case .dash: return known
        case .none: return known && !ambiguousCodes.contains(t.text)
        }
    }

    static func splitDigits(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var digits = false
        for ch in word {
            let isDigit = ch.isNumber
            if !current.isEmpty, isDigit != digits {
                parts.append(current)
                current = ""
            }
            digits = isDigit
            current.append(isDigit ? Character(String(ch.wholeNumberValue ?? 0)) : ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func isNumber(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isNumber) }

    static func stem(_ s: String) -> String { s.count >= 5 && s.hasSuffix("s") ? String(s.dropLast()) : s }

    /// Index keys of a name: each word's stem with the name's numbers ("sport#1").
    static func stemKeys(_ name: Name) -> Set<String> {
        Set(name.tokens.filter { !isNumber($0) }.map { stemKey($0, name) })
    }

    static func stemKey(_ word: String, _ name: Name) -> String {
        stem(word) + "#" + name.numbers.joined(separator: ",")
    }

    static func isArabic(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: true
        default: false
        }
    }

    /// "+1", "+2h", "(+1)", "Canal+1"; not "Canal+ 1" or "+1080p".
    static let timeshiftPattern = try! NSRegularExpression(pattern: #"(?:\+|(?<![\p{L}\p{N}])\+\s)(\d{1,2})(?:h|hr)?(?![\p{L}\p{N}])"#)
    static let bracketPattern = try! NSRegularExpression(pattern: #"[\[\(\{][^\]\)\}]*[\]\)\}]"#)

    /// Quality, packaging and access tags that never tell two channels apart.
    static let tagTokens: Set<String> = [
        "hd", "fhd", "uhd", "qhd", "sd", "lq", "hq", "4k", "8k", "hevc", "h265", "h264", "x265", "x264", "1080p", "1080i",
        "1080", "720p", "720", "576p", "2160p", "50fps", "60fps", "fps", "hdr", "raw", "vip", "tv", "multi", "multiaudio",
        "audio", "sub", "subs", "dual", "ᴴᴰ", "ᵁᴴᴰ", "ʰᵈ",
    ]
    static let backupTokens: Set<String> = ["backup", "bkp", "alt", "backup1", "backup2", "backup3"]
    /// Words that may be present on one side only.
    static let softTokens: Set<String> = ["the", "and", "channel", "television"]
    static let regionTokens: Set<String> = ["east", "west", "pacific"]
    static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10",
    ]
    /// Country tags → canonical code.
    static let countryCodes: [String: String] = [
        "uk": "uk", "gb": "uk", "us": "us", "usa": "us", "ca": "ca", "de": "de", "ger": "de", "fr": "fr", "fra": "fr",
        "es": "es", "esp": "es", "it": "it", "ita": "it", "nl": "nl", "pt": "pt", "br": "br", "tr": "tr", "pl": "pl",
        "ru": "ru", "gr": "gr", "ro": "ro", "au": "au", "ie": "ie", "mx": "mx", "se": "se", "dk": "dk", "fi": "fi",
        "hu": "hu", "cz": "cz", "ae": "ae", "uae": "ae", "sa": "sa", "ksa": "sa", "eg": "eg", "qa": "qa", "kw": "kw",
        "lb": "lb", "ma": "ma", "dz": "dz", "tn": "tn", "jo": "jo", "iq": "iq", "in": "in", "pk": "pk", "be": "be",
        "ch": "ch", "at": "at", "no": "no", "al": "al",
    ]
    /// Language tags: dropped, but they don't name a country ("AR" in IPTV lists means Arabic).
    static let languageCodes: Set<String> = ["ar", "arab", "en", "eng", "latino", "lat", "int"]
    /// Codes that are also words ("Al Jazeera", "Watch It"): only dropped when followed by ":" "|" "-" etc.
    static let ambiguousCodes: Set<String> = ["in", "be", "it", "no", "at", "al", "ma", "ch", "sa", "lat", "int"]
}
