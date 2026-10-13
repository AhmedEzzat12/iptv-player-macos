import Foundation

/// Finds a chart's titles in the user's library, in chart order.
///
/// A wrong title in a "Top 10" row is worse than a shorter row, so matching is strict:
/// 1. An IMDb/TMDB id match (ids come from the provider or from cached online metadata) wins.
/// 2. Otherwise the cleaned names must be equal (`TitleMatcher`'s normalisation: tags, quality junk, "S01",
///    "(2024)", articles, Arabic letter variants), with years agreeing when both are known. Bilingual names
///    ("The Assassins | الحشاشين") are compared by their Latin and Arabic parts too.
/// 3. An item whose cached metadata names a different title id than the chart's is never a title match.
/// 4. A chart title without a year (Netflix) that matches library items from different years ("The Mummy" 1999 and
///    2026) is ambiguous and skipped.
///
/// When several library items match (the same film in several playlists or categories), the one from the source the
/// user watches most is shown.
public enum TopTenMatcher {
    /// Items per row.
    public static let rowLimit = 10
    /// A row with fewer matches isn't shown (and the next source is tried).
    public static let minimumMatches = 3

    /// A library movie or show that might be on a chart.
    public struct Candidate: Sendable, Hashable {
        public var mediaId: String
        public var name: String
        /// Provider year or release date.
        public var year: String?
        public var sourceId: String
        public var imdbId: String?
        public var tmdbId: String?
        public var hasArtwork: Bool

        public init(mediaId: String, name: String, year: String? = nil, sourceId: String, imdbId: String? = nil,
                    tmdbId: String? = nil, hasArtwork: Bool = true) {
            self.mediaId = mediaId
            self.name = name
            self.year = year
            self.sourceId = sourceId
            self.imdbId = imdbId
            self.tmdbId = tmdbId
            self.hasArtwork = hasArtwork
        }
    }

    /// Media ids of the matched items, in chart order, at most `limit`, each item once.
    public static func match(_ entries: [ChartEntry], kind: MediaMetadata.Kind, candidates: [Candidate],
                             sourceUsage: [String: Int] = [:], limit: Int = rowLimit) -> [String] {
        matchRanked(entries, kind: kind, candidates: candidates, sourceUsage: sourceUsage, limit: limit).map(\.id)
    }

    /// As `match`, with each item's chart rank: the source's own rank, else its position in the list (1-based). Ranks
    /// keep their gaps ("1, 3, 4" when the library lacks number 2).
    public static func matchRanked(_ entries: [ChartEntry], kind: MediaMetadata.Kind, candidates: [Candidate],
                                   sourceUsage: [String: Int] = [:], limit: Int = rowLimit) -> [(id: String, rank: Int)] {
        let prepared = candidates.map { Prepared($0, kind: kind) }
        var used = Set<String>()
        var out: [(id: String, rank: Int)] = []
        for (index, entry) in entries.enumerated() {
            guard out.count < limit else { break }
            guard let id = bestMatch(for: entry, kind: kind, in: prepared, sourceUsage: sourceUsage, excluding: used) else { continue }
            used.insert(id)
            out.append((id, entry.rank ?? index + 1))
        }
        return out
    }

    // MARK: - Internals

    /// A candidate's comparable names and year, computed once.
    struct Prepared {
        var candidate: Candidate
        var names: [String]
        var year: Int?

        init(_ candidate: Candidate, kind: MediaMetadata.Kind) {
            self.candidate = candidate
            let query = TitleMatcher.query(name: candidate.name, year: candidate.year, kind: kind)
            var names = [query?.title, query?.literalTitle].compactMap { $0 }
            for name in names { names += TopTenMatcher.scriptVariants(name) }
            self.names = names
            year = query?.year
        }
    }

    static func bestMatch(for entry: ChartEntry, kind: MediaMetadata.Kind, in candidates: [Prepared],
                          sourceUsage: [String: Int], excluding used: Set<String>) -> String? {
        let available = candidates.filter { !used.contains($0.candidate.mediaId) }

        let byId = available.filter { idMatches(entry, $0.candidate) }
        if !byId.isEmpty { return pick(byId, year: entry.year, sourceUsage: sourceUsage) }

        let titles = [entry.title, entry.originalTitle].compactMap { $0 }
            .compactMap { TitleMatcher.query(name: $0, year: entry.year.map(String.init), kind: kind) }
        guard !titles.isEmpty else { return nil }
        let entryYear = entry.year ?? titles.lazy.compactMap(\.year).first
        let readings = titles.flatMap { [$0.title, $0.literalTitle].compactMap { $0 } }

        let byTitle = available.filter { c in
            guard !idConflicts(entry, c.candidate) else { return false }
            guard c.names.contains(where: { name in readings.contains { TitleMatcher.titleSimilarity(name, $0) >= 0.97 } }) else { return false }
            return yearsAgree(library: c.year, chart: entryYear, kind: kind)
        }
        guard !byTitle.isEmpty else { return nil }
        if entryYear == nil {
            let years = byTitle.compactMap(\.year)
            if let low = years.min(), let high = years.max(), high - low > 1 { return nil }
        }
        return pick(byTitle, year: entryYear, sourceUsage: sourceUsage)
    }

    static func idMatches(_ entry: ChartEntry, _ c: Candidate) -> Bool {
        if let a = entry.imdbId, let b = c.imdbId, a == b { return true }
        if let a = entry.tmdbId, let b = c.tmdbId, a == b { return true }
        return false
    }

    /// The candidate's metadata identifies a different title than the chart entry.
    static func idConflicts(_ entry: ChartEntry, _ c: Candidate) -> Bool {
        if let a = entry.imdbId, let b = c.imdbId, a != b { return true }
        if let a = entry.tmdbId, let b = c.tmdbId, a != b { return true }
        return false
    }

    /// Movies: within a year (release dates differ by country). Shows: the library item may be a later season,
    /// so any year from the show's start (less one) on.
    static func yearsAgree(library: Int?, chart: Int?, kind: MediaMetadata.Kind) -> Bool {
        guard let library, let chart else { return true }
        switch kind {
        case .movie: return abs(library - chart) <= 1
        case .series: return library >= chart - 1
        }
    }

    /// Exact year first, then the most-watched source, then items with artwork; ties by id (stable).
    static func pick(_ matches: [Prepared], year: Int?, sourceUsage: [String: Int]) -> String? {
        matches.min { a, b in
            let ay = year != nil && a.year == year, by = year != nil && b.year == year
            if ay != by { return ay }
            let au = sourceUsage[a.candidate.sourceId] ?? 0, bu = sourceUsage[b.candidate.sourceId] ?? 0
            if au != bu { return au > bu }
            if a.candidate.hasArtwork != b.candidate.hasArtwork { return a.candidate.hasArtwork }
            return a.candidate.mediaId < b.candidate.mediaId
        }?.candidate.mediaId
    }

    /// For a name mixing Latin and Arabic words ("The Assassins | الحشاشين", "الحشاشين The Assassins"), its Latin
    /// words and its Arabic words as two more names. Words without letters (numbers) stay with both.
    static func scriptVariants(_ name: String) -> [String] {
        var latin: [Substring] = [], arabic: [Substring] = []
        var hasLatin = false, hasArabic = false
        for word in name.split(whereSeparator: { $0.isWhitespace || "|/".contains($0) }) {
            let isArabic = word.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value) }
            let isLatin = word.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value < 0x0250 }
            if isArabic, !isLatin {
                arabic.append(word)
                hasArabic = true
            } else if isLatin, !isArabic {
                latin.append(word)
                hasLatin = true
            } else if !isArabic, !isLatin {
                latin.append(word)
                arabic.append(word)
            }
        }
        guard hasLatin, hasArabic else { return [] }
        return [latin, arabic].map { words in
            TitleMatcher.collapse(words.joined(separator: " "))
        }.filter { !$0.isEmpty }
    }
}
