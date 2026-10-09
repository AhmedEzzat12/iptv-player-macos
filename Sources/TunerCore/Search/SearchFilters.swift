import Foundation

/// What a natural search ("90s comedy series", "أفلام رعب كورية") was understood as: structured filters for movies and
/// shows plus the words that are left over and still searched in titles. Built by `QueryUnderstanding`.
public struct ParsedSearch: Hashable, Sendable {
    /// The query as typed (trimmed).
    public var query: String
    /// Words that aren't filters, searched in titles like a plain search. Equals `query` when nothing was understood.
    public var text: String
    /// Filters in the order they appear in the query (the order of the chips under the search field).
    public var filters: [SearchFilter]

    public init(query: String, text: String, filters: [SearchFilter]) {
        self.query = query
        self.text = text
        self.filters = filters
    }

    /// A plain search: no filters, the whole query is title text.
    public static func plain(_ query: String) -> ParsedSearch {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedSearch(query: q, text: q, filters: [])
    }

    public var hasFilters: Bool { !filters.isEmpty }

    /// The same search without the filters the user removed (by tapping a chip's ×).
    public func removing(_ removed: Set<SearchFilter>) -> ParsedSearch {
        guard !removed.isEmpty else { return self }
        var copy = self
        copy.filters.removeAll { removed.contains($0) }
        return copy
    }

    public var kind: SearchKind? {
        filters.lazy.compactMap { if case .kind(let k) = $0 { k } else { nil } }.first
    }

    public var years: YearSpan? {
        filters.lazy.compactMap { if case .years(let y) = $0 { y } else { nil } }.first
    }

    public var genres: [SearchGenre] {
        filters.compactMap { if case .genre(let g) = $0 { g } else { nil } }
    }

    public var languages: [SearchLanguage] {
        filters.compactMap { if case .language(let l) = $0 { l } else { nil } }
    }

    public var wants4K: Bool { filters.contains(.quality4K) }
    public var topRated: Bool { filters.contains(.topRated) }

    /// Titles rated below this are left out of "top rated" / "best" searches (provider ratings are out of 10).
    public static let topRatedMinimum = 7.0
}

/// One understood part of a search; shown as a removable chip.
public enum SearchFilter: Hashable, Sendable {
    case kind(SearchKind)
    case years(YearSpan)
    case genre(SearchGenre)
    case language(SearchLanguage)
    case quality4K
    case topRated

    public var title: String {
        switch self {
        case .kind(let kind): kind.title
        case .years(let span): span.title
        case .genre(let genre): genre.title
        case .language(let language): language.title
        case .quality4K: "4K"
        case .topRated: "Top Rated"
        }
    }

    /// SF Symbol for the chip.
    public var symbol: String {
        switch self {
        case .kind(.movie): "film"
        case .kind(.series): "tv"
        case .years: "calendar"
        case .genre: "theatermasks"
        case .language: "globe"
        case .quality4K: "4k.tv"
        case .topRated: "star"
        }
    }
}

public enum SearchKind: String, Hashable, Sendable, CaseIterable {
    case movie
    case series

    public var title: String {
        switch self {
        case .movie: "Movies"
        case .series: "TV Shows"
        }
    }
}

/// Release years: one year, a decade, a range, or open on one side ("since 2015", "before 2000").
public struct YearSpan: Hashable, Sendable {
    public var from: Int?
    public var to: Int?
    public var isDecade: Bool

    public init(from: Int?, to: Int?, isDecade: Bool = false) {
        self.from = from
        self.to = to
        self.isDecade = isDecade
    }

    public static func decade(_ start: Int) -> YearSpan { YearSpan(from: start, to: start + 9, isDecade: true) }
    public static func year(_ year: Int) -> YearSpan { YearSpan(from: year, to: year) }

    public var title: String {
        switch (from, to) {
        case let (from?, _) where isDecade: "\(from)s"
        case let (from?, to?) where from == to: "\(from)"
        case let (from?, to?): "\(from)–\(to)"
        case let (from?, nil): "Since \(from)"
        case let (nil, to?): "Until \(to)"
        case (nil, nil): "Any Year"
        }
    }

    public func contains(_ year: Int) -> Bool {
        (from.map { year >= $0 } ?? true) && (to.map { year <= $0 } ?? true)
    }
}

/// Genres a search can ask for. Matched against the provider's genre text and category names, in English and Arabic.
public enum SearchGenre: String, Hashable, Sendable, CaseIterable {
    case action, adventure, animation, comedy, crime, documentary, drama, family, fantasy, history, horror, kids
    case mystery, romance, sciFi, thriller, war

    public var title: String {
        switch self {
        case .sciFi: "Sci-Fi"
        case .kids: "Kids"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Word starts that mean this genre in provider genre fields and category names (folded: lowercase, Arabic
    /// letter variants unified). A trailing space means a whole word ("war " doesn't match "warner").
    var stems: [String] {
        switch self {
        case .action: ["action", "اكشن"]
        case .adventure: ["adventur", "مغامر"]
        case .animation: ["animat", "anime", "cartoon", "انمي", "انيميشن", "كرتون", "رسوم متحركه"]
        case .comedy: ["comed", "كوميد"]
        case .crime: ["crime", "criminal", "جريمه", "جرائم", "بوليسي"]
        case .documentary: ["documentar", "docu", "وثائقي"]
        case .drama: ["drama", "دراما", "درامي"]
        case .family: ["family", "عائلي"]
        case .fantasy: ["fantas", "فانتازيا"]
        case .history: ["histor", "تاريخي"]
        case .horror: ["horror", "رعب"]
        case .kids: ["kids", "children", "اطفال"]
        case .mystery: ["myster", "غموض"]
        case .romance: ["romanc", "romantic", "رومانس", "رومانسي"]
        case .sciFi: ["sci fi", "scifi", "science fiction", "خيال علمي"]
        case .thriller: ["thriller", "suspense", "اثاره", "تشويق"]
        case .war: ["war ", "حرب", "حروب"]
        }
    }
}

/// Languages and regions, matched against category names ("Arabic Movies", "مسلسلات تركية") and titles.
public enum SearchLanguage: String, Hashable, Sendable, CaseIterable {
    case arabic, egyptian, syrian, lebanese, gulf, moroccan, turkish, korean, indian, english, french, spanish
    case german, japanese, chinese

    public var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Word starts in category names (folded). A trailing space means a whole word.
    var stems: [String] {
        switch self {
        case .arabic: ["arabic", "arab ", "ar ", "عربي"]
        case .egyptian: ["egypt", "مصر"]
        case .syrian: ["syria", "سوري"]
        case .lebanese: ["leban", "لبنان"]
        case .gulf: ["khaleej", "gulf", "saudi", "kuwait", "emirat", "uae ", "qatar", "خليج", "سعودي", "كويت", "امارات", "قطر"]
        case .moroccan: ["morocc", "maghreb", "مغرب"]
        case .turkish: ["turk", "tr ", "ترك"]
        case .korean: ["korea", "kr ", "كوري"]
        case .indian: ["india", "hindi", "bollywood", "هند", "بوليوود"]
        case .english: ["english", "foreign", "en ", "hollywood", "american", "usa ", "uk ", "اجنبي", "انجليز", "امريك"]
        case .french: ["french", "france", "fr ", "فرنس"]
        case .spanish: ["spanish", "spain", "latino", "اسبان"]
        case .german: ["german", "almani", "الماني", "المانيا"]
        case .japanese: ["japan", "يابان"]
        case .chinese: ["chinese", "china", "صين"]
        }
    }

    /// Words that mark the language in a title ("Arabic", "مدبلج" isn't one), plus the two-letter tag some
    /// playlists put in front of names ("AR - …", "[TR] …").
    var titleWords: [String] {
        switch self {
        case .arabic: ["arabic", "عربي"]
        case .egyptian: ["egyptian", "مصري"]
        case .syrian: ["syrian", "سوري"]
        case .lebanese: ["lebanese", "لبناني"]
        case .gulf: ["khaleeji", "خليجي"]
        case .moroccan: ["moroccan", "مغربي"]
        case .turkish: ["turkish", "تركي"]
        case .korean: ["korean", "كوري"]
        case .indian: ["hindi", "bollywood", "هندي"]
        case .english: ["english"]
        case .french: ["french", "فرنسي"]
        case .spanish: ["spanish", "اسباني"]
        case .german: ["german", "الماني"]
        case .japanese: ["japanese", "ياباني"]
        case .chinese: ["chinese", "صيني"]
        }
    }

    var tag: String? {
        switch self {
        case .arabic: "ar"
        case .turkish: "tr"
        case .korean: "kr"
        case .english: "en"
        case .french: "fr"
        default: nil
        }
    }
}
