import Foundation

/// Groups a provider's categories (often 50–200 of them, named like "Arabic Movies - عربي 2024" or
/// "Bein Sport [ FHD ] | [ … ]") into a handful of browsable groups, and cleans their names.
///
/// Matching is keyword based on the whole name, in English and Arabic, so bilingual, English-only and
/// Arabic-only names all classify. First matching rule wins, in `CategoryGroup` priority order.
public enum CategoryGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case featured
    case byYear
    case sports
    case kids
    case platforms
    case quality
    case genres
    case languages
    case more

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .featured: "Featured"
        case .byYear: "By Year"
        case .sports: "Sports"
        case .kids: "Kids"
        case .platforms: "Platforms"
        case .quality: "Quality & Subtitles"
        case .genres: "Genres"
        case .languages: "Languages & Countries"
        case .more: "More"
        }
    }

    /// For chips, where space is tight.
    public var shortTitle: String {
        switch self {
        case .quality: "Quality"
        case .languages: "Languages"
        default: title
        }
    }

    public var symbol: String {
        switch self {
        case .featured: "star"
        case .byYear: "calendar"
        case .sports: "sportscourt"
        case .kids: "figure.and.child.holdinghands"
        case .platforms: "play.tv"
        case .quality: "4k.tv"
        case .genres: "theatermasks"
        case .languages: "globe"
        case .more: "ellipsis.circle"
        }
    }

    /// Order of the group chips in the UI (most useful first).
    public static let displayOrder: [CategoryGroup] = [.featured, .languages, .platforms, .genres, .byYear, .sports, .kids, .quality, .more]
}

/// How category names are shown: the provider's full name, or just one language's part of a bilingual name.
public enum CategoryNameStyle: String, CaseIterable, Codable, Sendable {
    /// The English part when there is one, otherwise the Arabic part.
    case automatic
    /// The Arabic part when there is one, otherwise the English part.
    case arabic
    /// Exactly as the provider names it.
    case original

    public var title: String {
        switch self {
        case .automatic: "English When Available"
        case .arabic: "Arabic When Available"
        case .original: "As the Provider Names Them"
        }
    }
}

/// A category's group and its name split by script.
public struct CategoryFacet: Equatable, Sendable {
    public var group: CategoryGroup
    /// Latin-script parts of the name, joined with " · " ("Bein Sport · FHD"); nil if there are none.
    public var latinName: String?
    /// Arabic-script parts of the name; nil if there are none.
    public var arabicName: String?
    /// Year or year range mentioned in the name ("2024", "2010–2016").
    public var yearLabel: String?
    /// Latest year mentioned, for sorting By Year newest first.
    public var latestYear: Int?
    public var original: String

    public func displayName(_ style: CategoryNameStyle) -> String {
        let base: String?
        switch style {
        case .original: return original
        case .automatic: base = latinName ?? arabicName
        case .arabic: base = arabicName ?? latinName
        }
        guard var name = base?.nilIfBlank else { return original }
        if let yearLabel, !name.contains(yearLabel), !(latestYear.map { name.contains(String($0)) } ?? false) {
            name += " \(yearLabel)"
        }
        return name
    }
}

public enum CategoryClassifier {
    public static func facet(for name: String) -> CategoryFacet {
        let parts = split(name)
        let years = yearsMentioned(in: name)
        var facet = CategoryFacet(
            group: .more,
            latinName: parts.latin.isEmpty ? nil : parts.latin.joined(separator: " · "),
            arabicName: parts.arabic.isEmpty ? nil : parts.arabic.joined(separator: " · "),
            yearLabel: yearLabel(years),
            latestYear: years.max(),
            original: name
        )
        facet.group = group(for: name, hasYear: !years.isEmpty)
        return facet
    }

    // MARK: Grouping

    static func group(for name: String, hasYear: Bool) -> CategoryGroup {
        let text = " " + normalized(name) + " "
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        // Seasonal and award shelves stay featured even with a year ("RAMADAN 2026 مصر", "Oscar 2023").
        if has(Keywords.seasonal) { return .featured }
        // A year (or range) with a language/region reads as a release-year shelf: "Arabic Movies 2024".
        if hasYear, has(Keywords.languages) || has(Keywords.yearShelves) { return .byYear }
        if has(Keywords.sports) { return .sports }
        if has(Keywords.kids) { return .kids }
        if has(Keywords.platforms) { return .platforms }
        if has(Keywords.featured) || hasYear { return .featured }
        if has(Keywords.genres) { return .genres }
        if has(Keywords.quality) { return .quality }
        if has(Keywords.languages) || has(Keywords.countries) { return .languages }
        return .more
    }

    /// Lowercased, with Arabic letter variants folded (أ/إ/آ→ا, ة→ه, ى→ي) and punctuation turned into spaces,
    /// so " drama " matches "Drama- افلام" and "افلام" matches "أفلام".
    static func normalized(_ name: String) -> String {
        var s = name.lowercased()
        for (from, to) in [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ة", "ه"), ("ى", "ي"), ("ـ", ""), ("ٍ", ""), ("ً", ""), ("َ", ""), ("ُ", ""), ("ِ", ""), ("ّ", "")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        let separators = CharacterSet(charactersIn: "-|[](){}_/:,.+")
        s = s.unicodeScalars.map { separators.contains($0) ? " " : String($0) }.joined()
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Names

    /// Splits "Arabic Movies -  [  2010 - 2016 ] عربي" into Latin ("Arabic Movies") and Arabic ("عربي") parts;
    /// bare numbers (years) are left out of both.
    static func split(_ name: String) -> (latin: [String], arabic: [String]) {
        var segments: [String] = []
        var current = ""
        let scalars = Array(name.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            let c = Character(scalar)
            let isBracket = "[](){}|".contains(c)
            // A dash separates only when spaced on at least one side ("Drama- افلام", "Arabic - عربي"), not "Sci-Fi".
            let isDash = (c == "-" || c == "–") && (
                (i > 0 && scalars[i - 1].properties.isWhitespace) || (i + 1 < scalars.count && scalars[i + 1].properties.isWhitespace)
            )
            if isBracket || isDash {
                segments.append(current)
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        segments.append(current)

        var latin: [String] = []
        var arabic: [String] = []
        for raw in segments {
            let segment = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard segment.contains(where: \.isLetter) else { continue } // years, "4", stray punctuation
            if segment.unicodeScalars.contains(where: isArabic) {
                // "2026 اجنبي": keep the words, drop the year (it's shown separately).
                let words = segment.split(separator: " ").filter { !$0.allSatisfy(\.isNumber) }.joined(separator: " ")
                if !words.isEmpty { arabic.append(words) }
            } else {
                latin.append(segment)
            }
        }
        return (latin, arabic)
    }

    static func isArabic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0600...0x06FF).contains(scalar.value) || (0x0750...0x077F).contains(scalar.value)
            || (0xFB50...0xFDFF).contains(scalar.value) || (0xFE70...0xFEFF).contains(scalar.value)
    }

    static func yearsMentioned(in name: String) -> [Int] {
        let digits = name.unicodeScalars.map { CharacterSet.decimalDigits.contains($0) ? Character($0) : " " }
        return String(digits).split(separator: " ").compactMap { token in
            guard token.count == 4, let year = Int(token), (1950...2100).contains(year) else { return nil }
            return year
        }
    }

    static func yearLabel(_ years: [Int]) -> String? {
        guard let low = years.min(), let high = years.max() else { return nil }
        return low == high ? String(low) : "\(low)–\(high)"
    }
}

/// Keyword lists (normalized: lowercase, Arabic variants folded). English keywords are padded with spaces where
/// they could be part of longer words.
enum Keywords {
    static let sports = [
        "sport", " nba ", "tennis", "cricket", " wwe ", " ufc ", "match", " league", "football", "nfl", "boxing",
        "رياض", "مباريات", "مباراه", "مصارع", "دوري", "كاس العالم", "الكره",
    ]
    static let kids = [
        " kids", "cartoon", "spacetoon", "children", "اطفال", "كرتون", "سبيستون", "سبيس تون",
    ]
    static let platforms = [
        "netflix", "shahid", "disney", "watch it", "watchit", "starz", "amazon", "prime video", " osn", " hbo",
        "apple tv", "masspero", "maspero", " mbc", "rotana", "alwan", "shoof", "flix tv", " stc", " art ",
        // Short Arabic names must start a word: "شاهد" also occurs inside "المشاهده" (viewing).
        "نتفليكس", "نت فليكس", " شاهد", "ديزني", " واتش", "ستارز", "امازون", "ماسبيرو", "روتانا", "اللوان", " شوف",
    ]
    static let featured = [
        "box office", " top ", " imdb", "imdp", "oscar", "trending", " best ", "marvel", " dc ", "weekend", "on demand",
        " new ", "classic", "collection", "salasil", "actors", "now showing",
        "بوكس اوفيس", "افضل", "الاعلي", "مميز", "تعرض حاليا", "انتهت", "طلبات", "جديد", "سلاسل",
        "الزمن الجميل", "كلاسيك", "الممثلين", "عطله", "ايرادات",
    ]
    static let quality = [
        " 4k", " uhd", " fhd", " hd ", " sd ", "h 265", "hevc", "pure", "multi sub", "multi audio", " sub ", "no sub",
        " 3d ", "فائقه الجوده", "متعدده التراجم", "مترجمه للانجليزيه", "ثلاثيه الابعاد",
    ]
    static let genres = [
        "action", "drama", "comedy", "horror", "sci fi", "scifi", "science fiction", " war ", "romantic", "romance",
        "crime", "thriller", "mystery", "family", "historical", "history", "documentar", "anime", "animation",
        "musical", " music", "religious", "islamic", "quran", "christian", "chrisitan", "medical", "education",
        "learn", " news", "motivational", "comedies", "masrahiyat", "msarhyat", "plays", "song", "radio",
        "talk show", "concert", "حفلات", "برامج",
        "اكشن", "دراما", "كوميد", "رعب", "خيال علمي", "حروب", "رومانس", "رومانسي", "جريمه", "عائلي", "تاريخي",
        "وثائقي", "انمي", "ديني", "اسلامي", "قران", "القران", "المسيحيه", "طبيه", "تعليم", "اخبار", "مسرحيات",
        "اغاني", "موسيقي", "راديو", "تحفيز", "تحفيذيه",
    ]
    static let seasonal = ["ramadan", "رمضان", "oscar", "اوسكار"]
    /// Languages and dubbing/subtitle variants of a language.
    static let languages = [
        "arabic", "english", "foreign", "turkish", "indian", "hindi", "korean", "asian", "japanese", "chinese",
        "spanish", "french", "german", "italian", "latin", "syrian", "lebanese", "egyptian", "saudi", "kuwait",
        "tunisian", "moroccan", "khaleeji", "gulf", "dubbed", "persian", "kurdish", "urdu",
        "عربي", "عربيه", "اجنبي", "اجنبيه", "تركي", "تركيه", "هندي", "هنديه", "كوري", "كوريه", "اسيوي", "اسيويه",
        "ياباني", "صيني", "اسباني", "فرنسي", "الماني", "ايطالي", "لاتيني", "سوري", "سوريه", "لبناني", "لبنانيه",
        "مصري", "مصريه", "سعودي", "سعوديه", "كويتي", "كويتيه", "تونسي", "تونسيه", "مغربي", "مغربيه", "خليجي",
        "مدبلج", "مترجم", "اماراتي", "اماراتيه",
    ]
    /// "English Movies 2026"-style shelves whose language word isn't in `languages`.
    static let yearShelves = ["movies", "series", "افلام", "مسلسلات"]
    static let countries = [
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
    ]
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
