import Foundation

/// A movie or show as the recommender sees it: provider fields plus whatever cached online metadata adds.
public struct RecommendationItem: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case movie
        case series
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var year: Int?
    /// 0–10; nil or 0 = unknown.
    public var rating: Double?
    public var categoryId: String?
    /// The provider's category name ("Arabic Movies - عربي 2024"): language, genre and platform hints.
    public var categoryName: String?
    public var genres: [String]
    public var cast: [String]
    public var directors: [String]
    public var plot: String?

    public init(id: String, kind: Kind, title: String, year: Int? = nil, rating: Double? = nil, categoryId: String? = nil,
                categoryName: String? = nil, genres: [String] = [], cast: [String] = [], directors: [String] = [], plot: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.year = year
        self.rating = rating
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.genres = genres
        self.cast = cast
        self.directors = directors
        self.plot = plot
    }

    public init(movie: Movie, categoryName: String?, metadata: MediaMetadata?) {
        self.init(movie: movie, categoryName: categoryName, extra: metadata.map(RecommendationMetadata.init))
    }

    public init(series: Series, categoryName: String?, metadata: MediaMetadata?) {
        self.init(series: series, categoryName: categoryName, extra: metadata.map(RecommendationMetadata.init))
    }

    init(movie m: Movie, categoryName: String?, extra: RecommendationMetadata?) {
        self.init(id: m.id, kind: .movie, title: m.name, providerYear: m.year, releaseDate: m.releaseDate, rating: m.rating,
                  categoryId: m.categoryId, categoryName: categoryName, genre: m.genre, cast: m.cast, director: m.director,
                  plot: m.plot, extra: extra)
    }

    init(series s: Series, categoryName: String?, extra: RecommendationMetadata?) {
        self.init(id: s.id, kind: .series, title: s.name, providerYear: s.year, releaseDate: s.releaseDate, rating: s.rating,
                  categoryId: s.categoryId, categoryName: categoryName, genre: s.genre, cast: s.cast, director: s.director,
                  plot: s.plot, extra: extra)
    }

    /// From provider columns (list fields as the provider writes them) plus cached online metadata, which fills in
    /// what the provider lacks and adds its genres.
    init(id: String, kind: Kind, title: String, providerYear: String?, releaseDate: String?, rating: Double?, categoryId: String?,
         categoryName: String?, genre: String?, cast: String?, director: String?, plot: String?, extra: RecommendationMetadata?) {
        let year = RecommendationText.year(providerYear) ?? RecommendationText.year(releaseDate)
            ?? RecommendationText.titleKey(title, isSeries: kind == .series).year ?? extra?.year
        var cast = RecommendationText.splitList(cast)
        if cast.isEmpty { cast = extra?.cast ?? [] }
        var directors = RecommendationText.splitList(director)
        if directors.isEmpty { directors = extra?.directors ?? [] }
        self.init(id: id, kind: kind, title: title, year: year, rating: rating.flatMap { $0 > 0 ? $0 : nil } ?? extra?.rating,
                  categoryId: categoryId, categoryName: categoryName,
                  genres: RecommendationText.splitList(genre) + (extra?.genres ?? []), cast: cast, directors: directors,
                  plot: plot?.nilIfEmpty ?? extra?.overview)
    }
}

/// The fields of cached online metadata the recommender reads (decoded straight from `mediaMetadata.json`, which is
/// much cheaper than decoding the whole `MediaMetadata` with its episode lists).
struct RecommendationMetadata: Decodable, Sendable {
    var genres: [String]
    var cast: [String]
    var directors: [String]
    var overview: String?
    var year: Int?
    var rating: Double?

    private struct Person: Decodable { var name: String }
    private enum CodingKeys: String, CodingKey { case genres, cast, directors, overview, year, rating }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? []
        cast = ((try? c.decodeIfPresent([Person].self, forKey: .cast)) ?? []).map(\.name)
        directors = (try? c.decodeIfPresent([String].self, forKey: .directors)) ?? []
        overview = (try? c.decodeIfPresent(String.self, forKey: .overview))?.nilIfEmpty
        year = RecommendationText.year(try? c.decodeIfPresent(String.self, forKey: .year))
        rating = (try? c.decodeIfPresent(Double.self, forKey: .rating)).flatMap { $0 > 0 ? $0 : nil }
    }

    init(_ m: MediaMetadata) {
        genres = m.genres
        cast = m.cast.map(\.name)
        directors = m.directors
        overview = m.overview?.nilIfEmpty
        year = RecommendationText.year(m.year)
        rating = m.rating.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// What to leave out of a result and how varied it should be.
public struct RecommendationOptions: Sendable {
    public var limit: Int
    /// Ids the user has already seen (watched, in progress, favourites…). Other copies of the same title (same
    /// normalised name and year, e.g. in another playlist or category) are left out too.
    public var excludedIds: Set<String>
    public var hiddenCategoryIds: Set<String>
    /// Leave out titles from categories whose name marks them as adult.
    public var hideAdult: Bool
    /// 0 = pure similarity, 1 = only variety (maximal marginal relevance).
    public var diversity: Double
    /// At most this many results from one category, while other candidates remain (nil = limit / 3, at least 3).
    public var maxPerCategory: Int?

    public init(limit: Int = 20, excludedIds: Set<String> = [], hiddenCategoryIds: Set<String> = [], hideAdult: Bool = false,
                diversity: Double = 0.3, maxPerCategory: Int? = nil) {
        self.limit = limit
        self.excludedIds = excludedIds
        self.hiddenCategoryIds = hiddenCategoryIds
        self.hideAdult = hideAdult
        self.diversity = diversity
        self.maxPerCategory = maxPerCategory
    }
}

public struct Recommendation: Sendable, Hashable {
    public var id: String
    public var kind: RecommendationItem.Kind
    public var score: Double
}

/// Content-based similarity over a whole library, built on this device without any model: every movie and show is a
/// sparse TF-IDF vector over weighted feature tokens (genres, cast, directors, category, the category's language and
/// genre words, title words, plot keywords) and similar titles are found by cosine similarity through an inverted
/// index, then adjusted for year proximity and rating and diversified with MMR and a per-category cap.
///
/// Built once per library (`init` is plain synchronous work: call it off the main actor), immutable afterwards, so
/// it can be shared between tasks. Terms that occur in only one title can't make two titles similar and are
/// dropped, which keeps the vectors small (≈ 30 terms per title for 56 k titles).
public struct RecommendationIndex: Sendable {
    struct Entry: Sendable {
        var id: String
        var kind: RecommendationItem.Kind
        /// 0 = unknown.
        var year: Int16
        /// 0…1 prior from the rating (0 when unknown or ≤ 5).
        var ratingPrior: Float
        /// Dense category number (`categoryPositions`), -1 = none.
        var category: Int32
        var titleKey: String
        var isAdult: Bool
    }

    /// Feature fields and their weights before IDF.
    enum Field: UInt8 {
        case genre, language, category, categoryWord, director, cast, title, plot

        var prefix: String {
            switch self {
            case .genre: "g:"
            case .language: "l:"
            case .category: "k:"
            case .categoryWord: "c:"
            case .director: "d:"
            case .cast: "p:"
            case .title: "t:"
            case .plot: "w:"
            }
        }

        var weight: Float {
            switch self {
            case .genre: 2.0
            case .language: 1.5
            case .category: 1.2
            case .categoryWord: 0.6
            case .director: 2.0
            case .cast: 1.5
            case .title: 1.2
            case .plot: 0.5
            }
        }

        /// Free-text fields lose terms shared by too many titles (they'd only add noise and long posting lists).
        var capsDocumentFrequency: Bool { self == .title || self == .plot || self == .categoryWord }
    }

    let entries: [Entry]
    let positions: [String: Int32]
    let categoryPositions: [String: Int32]
    let categoryIds: [String]
    let vocabulary: [String: Int32]
    let idf: [Float]
    /// Item vectors (CSR, term ids ascending, L2-normalised).
    let rowStart: [Int32]
    let rowTerms: [Int32]
    let rowWeights: [Float]
    /// Inverted index: for each term, the items containing it and their weights.
    let postingStart: [Int32]
    let postingItems: [Int32]
    let postingWeights: [Float]

    public var count: Int { entries.count }
    /// Stored non-zero weights (each is kept twice: per item and per term).
    public var nonZeroCount: Int { rowTerms.count }
    public var termCount: Int { idf.count }
    /// Rough memory used by the vectors and postings, in bytes (excludes strings).
    public var approximateVectorBytes: Int { (rowTerms.count + postingItems.count) * 8 + (rowStart.count + postingStart.count + idf.count) * 4 }

    public init(items: [RecommendationItem]) {
        let n = items.count
        var vocabulary: [String: Int32] = [:]
        var fields: [Field] = []
        var documentFrequency: [Int32] = []
        var rawVectors: [[(term: Int32, weight: Float)]] = []
        rawVectors.reserveCapacity(n)
        var entries: [Entry] = []
        entries.reserveCapacity(n)
        var positions: [String: Int32] = [:]
        positions.reserveCapacity(n)
        var categoryIds: [String] = []
        var categoryPositions: [String: Int32] = [:]
        var adultByCategory: [String: Bool] = [:]

        var unique: [RecommendationItem] = []
        unique.reserveCapacity(n)
        for item in items where positions[item.id] == nil {
            positions[item.id] = Int32(unique.count)
            unique.append(item)
        }
        // Tokenising is most of the work: spread it over the cores.
        let extracted = Self.extractInParallel(unique)

        for (position, item) in unique.enumerated() {
            var category: Int32 = -1
            if let id = item.categoryId {
                if let existing = categoryPositions[id] {
                    category = existing
                } else {
                    category = Int32(categoryIds.count)
                    categoryPositions[id] = category
                    categoryIds.append(id)
                }
            }
            let isAdult: Bool
            if let name = item.categoryName {
                if let known = adultByCategory[name] { isAdult = known } else {
                    isAdult = Self.isAdultCategory(name)
                    adultByCategory[name] = isAdult
                }
            } else {
                isAdult = false
            }
            entries.append(Entry(
                id: item.id, kind: item.kind, year: Int16(item.year ?? 0), ratingPrior: Self.ratingPrior(item.rating), category: category,
                titleKey: extracted[position].titleKey, isAdult: isAdult
            ))

            var vector: [(term: Int32, weight: Float)] = []
            vector.reserveCapacity(extracted[position].features.count)
            for (token, weight) in extracted[position].features {
                let term: Int32
                if let existing = vocabulary[token.text] {
                    term = existing
                    documentFrequency[Int(term)] += 1
                } else {
                    term = Int32(fields.count)
                    vocabulary[token.text] = term
                    fields.append(token.field)
                    documentFrequency.append(1)
                }
                vector.append((term, weight))
            }
            rawVectors.append(vector)
        }

        // Keep terms shared by at least two titles; drop over-common free-text terms.
        let count = entries.count
        let maxFreeTextDF = count >= 200 ? Int32(Double(count) * 0.08) : Int32.max
        var remap = [Int32](repeating: -1, count: fields.count)
        var idf: [Float] = []
        for term in 0..<fields.count {
            let df = documentFrequency[term]
            guard df >= 2, !(fields[term].capsDocumentFrequency && df > maxFreeTextDF) else { continue }
            remap[term] = Int32(idf.count)
            idf.append(log(Float(count + 1) / Float(df + 1)) + 1)
        }
        var keptVocabulary: [String: Int32] = [:]
        keptVocabulary.reserveCapacity(idf.count)
        for (text, term) in vocabulary where remap[Int(term)] >= 0 { keptVocabulary[text] = remap[Int(term)] }

        // Weighted, normalised item vectors (CSR).
        var rowStart: [Int32] = [0]
        rowStart.reserveCapacity(count + 1)
        var rowTerms: [Int32] = []
        var rowWeights: [Float] = []
        var termCounts = [Int32](repeating: 0, count: idf.count)
        for vector in rawVectors {
            var kept: [(term: Int32, weight: Float)] = []
            kept.reserveCapacity(vector.count)
            for (term, weight) in vector {
                let t = remap[Int(term)]
                guard t >= 0 else { continue }
                kept.append((t, weight * idf[Int(t)]))
            }
            kept.sort { $0.term < $1.term }
            let norm = sqrt(kept.reduce(Float(0)) { $0 + $1.weight * $1.weight })
            if norm > 0 {
                for (term, weight) in kept {
                    rowTerms.append(term)
                    rowWeights.append(weight / norm)
                    termCounts[Int(term)] += 1
                }
            }
            rowStart.append(Int32(rowTerms.count))
        }
        rawVectors = []

        // Postings (counting sort by term).
        var postingStart = [Int32](repeating: 0, count: idf.count + 1)
        for t in 0..<idf.count { postingStart[t + 1] = postingStart[t] + termCounts[t] }
        var cursor = postingStart
        var postingItems = [Int32](repeating: 0, count: rowTerms.count)
        var postingWeights = [Float](repeating: 0, count: rowTerms.count)
        for item in 0..<count {
            for k in Int(rowStart[item])..<Int(rowStart[item + 1]) {
                let t = Int(rowTerms[k])
                let slot = Int(cursor[t])
                postingItems[slot] = Int32(item)
                postingWeights[slot] = rowWeights[k]
                cursor[t] += 1
            }
        }

        self.entries = entries
        self.positions = positions
        self.categoryPositions = categoryPositions
        self.categoryIds = categoryIds
        self.vocabulary = keptVocabulary
        self.idf = idf
        self.rowStart = rowStart
        self.rowTerms = rowTerms
        self.rowWeights = rowWeights
        self.postingStart = postingStart
        self.postingItems = postingItems
        self.postingWeights = postingWeights
    }

    // MARK: Features

    struct Token: Hashable {
        var text: String
        var field: Field
    }

    /// Turns titles into feature tokens. Genre strings and category names repeat across thousands of titles, so
    /// their tokens are worked out once per distinct string (keyword matching is the slow part).
    struct FeatureExtractor {
        typealias Weighted = (token: Token, weight: Float)
        private var genreCache: [String: [Weighted]] = [:]
        private var categoryCache: [String: [Weighted]] = [:]

        private static func token(_ field: Field, _ text: some StringProtocol) -> Token {
            Token(text: field.prefix + text, field: field)
        }

        private mutating func genreTokens(_ genre: String) -> [Weighted] {
            if let cached = genreCache[genre] { return cached }
            var tokens = RecommendationText.canonicalGenres(genre).map { (Self.token(.genre, $0), Field.genre.weight) }
            if tokens.isEmpty {
                let key = RecommendationText.normalize(genre)
                if !key.isEmpty { tokens.append((Self.token(.genre, key), Field.genre.weight)) }
            }
            genreCache[genre] = tokens
            return tokens
        }

        private mutating func categoryTokens(_ name: String) -> [Weighted] {
            if let cached = categoryCache[name] { return cached }
            var tokens: [Weighted] = []
            // A category's genre ("Action - افلام اكشن") counts as a weaker genre signal.
            for g in RecommendationText.canonicalGenres(name) { tokens.append((Self.token(.genre, g), Field.genre.weight * 0.6)) }
            for l in RecommendationText.canonicalLanguages(name) { tokens.append((Self.token(.language, l), Field.language.weight)) }
            for word in RecommendationText.contentWords(name) where !RecommendationText.qualityTags.contains(word) {
                tokens.append((Self.token(.categoryWord, word), Field.categoryWord.weight))
            }
            categoryCache[name] = tokens
            return tokens
        }

        /// Feature tokens and their weights for one title. A token found in several places keeps the larger weight.
        mutating func features(of item: RecommendationItem) -> [Token: Float] {
            var out: [Token: Float] = [:]
            out.reserveCapacity(64)
            func add(_ token: Token, _ weight: Float) {
                if let existing = out[token] {
                    if weight > existing { out[token] = weight }
                } else {
                    out[token] = weight
                }
            }

            for genre in item.genres {
                for (token, weight) in genreTokens(genre) { add(token, weight) }
            }
            if let categoryId = item.categoryId { add(Self.token(.category, categoryId), Field.category.weight) }
            if let name = item.categoryName {
                for (token, weight) in categoryTokens(name) { add(token, weight) }
            }
            for (i, name) in item.directors.prefix(3).enumerated() {
                if let key = RecommendationText.personKey(name) { add(Self.token(.director, key), i == 0 ? Field.director.weight : 1.4) }
            }
            for (i, name) in item.cast.prefix(6).enumerated() {
                // Leads count more than the rest of the billing.
                if let key = RecommendationText.personKey(name) { add(Self.token(.cast, key), Field.cast.weight * (i < 3 ? 1 : 0.7)) }
            }
            let titleWords = RecommendationText.contentWords(String(RecommendationText.stripPrefixTags(item.title)))
            for word in titleWords where !RecommendationText.qualityTags.contains(word) && !RecommendationText.seasonWords.contains(word) {
                add(Self.token(.title, word), Field.title.weight)
            }
            if let plot = item.plot {
                var seen = 0
                for word in RecommendationText.contentWords(plot) where word.unicodeScalars.count >= 3 {
                    let before = out.count
                    add(Self.token(.plot, word), Field.plot.weight)
                    if out.count > before { seen += 1 }
                    if seen >= 40 { break }
                }
            }
            return out
        }
    }

    /// Features and duplicate keys of `items`, in order, worked out in chunks on all cores (one extractor per chunk).
    static func extractInParallel(_ items: [RecommendationItem]) -> [(features: [Token: Float], titleKey: String)] {
        let chunkSize = 2_000
        let chunks = (items.count + chunkSize - 1) / chunkSize
        var results = [[(features: [Token: Float], titleKey: String)]](repeating: [], count: chunks)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                var extractor = FeatureExtractor()
                let range = (chunk * chunkSize)..<min(items.count, (chunk + 1) * chunkSize)
                buffer[chunk] = items[range].map { item in
                    (extractor.features(of: item), RecommendationText.titleKey(item.title, isSeries: item.kind == .series).key)
                }
            }
        }
        return results.flatMap { $0 }
    }

    static func features(of item: RecommendationItem) -> [Token: Float] {
        var extractor = FeatureExtractor()
        return extractor.features(of: item)
    }

    static func ratingPrior(_ rating: Double?) -> Float {
        guard let rating, rating > 5 else { return 0 }
        return Float(min(1, (rating - 5) / 4))
    }

    /// Category names that mark adult content (as `M3UParser` does for channels, plus Arabic and "18+").
    static func isAdultCategory(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("adult") || lower.contains("xxx") || lower.contains("18+") || lower.contains("+18")
            || lower.contains("porn") || lower.contains("erotic") || lower.contains("للكبار")
    }

    // MARK: Queries

    /// Whether the index has this title.
    public func contains(_ id: String) -> Bool { positions[id] != nil }

    func entry(_ id: String) -> Entry? { positions[id].map { entries[Int($0)] } }

    func categoryId(of id: String) -> String? {
        guard let e = entry(id), e.category >= 0 else { return nil }
        return categoryIds[Int(e.category)]
    }

    /// Two copies of one title (same normalised name, same or unknown year).
    func isSameTitle(_ a: String, _ b: String) -> Bool {
        guard let x = entry(a), let y = entry(b) else { return false }
        return isDuplicate(x, y)
    }

    /// Titles like an indexed one, using its indexed vector.
    public func similar(toId id: String, options: RecommendationOptions = RecommendationOptions()) -> [Recommendation] {
        guard let position = positions[id] else { return [] }
        let p = Int(position)
        let terms = (Int(rowStart[p])..<Int(rowStart[p + 1])).map { (rowTerms[$0], rowWeights[$0]) }
        let entry = entries[p]
        return rank(query: terms, kind: entry.kind, year: Int(entry.year), seedId: id, seedKey: entry.titleKey, options: options)
    }

    /// Titles like `item`, using the given (possibly fresher or richer) details rather than the indexed ones.
    public func similar(to item: RecommendationItem, options: RecommendationOptions = RecommendationOptions()) -> [Recommendation] {
        let query = vector(for: item)
        let key = RecommendationText.titleKey(item.title, isSeries: item.kind == .series).key
        return rank(query: query, kind: item.kind, year: item.year ?? 0, seedId: item.id, seedKey: key, options: options)
    }

    /// Cosine similarity of two indexed titles (0 when either is unknown).
    public func similarity(_ a: String, _ b: String) -> Double {
        guard let i = positions[a], let j = positions[b] else { return 0 }
        return Double(dot(Int(i), Int(j)))
    }

    /// A title's vector in this index's term space (terms the index doesn't know are left out).
    func vector(for item: RecommendationItem) -> [(Int32, Float)] {
        var terms: [(Int32, Float)] = []
        for (token, weight) in Self.features(of: item) {
            guard let t = vocabulary[token.text] else { continue }
            terms.append((t, weight * idf[Int(t)]))
        }
        let norm = sqrt(terms.reduce(Float(0)) { $0 + $1.1 * $1.1 })
        guard norm > 0 else { return [] }
        return terms.map { ($0.0, $0.1 / norm) }
    }

    private func rank(query: [(Int32, Float)], kind: RecommendationItem.Kind, year: Int, seedId: String, seedKey: String,
                      options: RecommendationOptions) -> [Recommendation] {
        guard !query.isEmpty, options.limit > 0 else { return [] }

        // Cosine similarity through the postings (vectors are normalised, so the dot product is the cosine).
        var scores = [Float](repeating: 0, count: entries.count)
        var touched: [Int32] = []
        for (term, qw) in query {
            let t = Int(term)
            for k in Int(postingStart[t])..<Int(postingStart[t + 1]) {
                let item = Int(postingItems[k])
                if scores[item] == 0 { touched.append(Int32(item)) }
                scores[item] += qw * postingWeights[k]
            }
        }

        // Titles the user has seen (and other copies of them) and the seed's own copies are left out.
        var excludedKeys: [String: [Int]] = [:]
        if !seedKey.isEmpty { excludedKeys[seedKey] = [year] }
        for id in options.excludedIds {
            guard let p = positions[id] else { continue }
            let e = entries[Int(p)]
            if !e.titleKey.isEmpty { excludedKeys[e.titleKey, default: []].append(Int(e.year)) }
        }
        let hiddenCategories = Set(options.hiddenCategoryIds.compactMap { categoryPositions[$0] })

        struct Candidate {
            var item: Int
            var score: Float
        }
        var candidates: [Candidate] = []
        for t in touched {
            let i = Int(t)
            let cosine = scores[i]
            guard cosine > 0.02 else { continue }
            let e = entries[i]
            guard e.kind == kind, e.id != seedId, !options.excludedIds.contains(e.id),
                  !(options.hideAdult && e.isAdult), !(e.category >= 0 && hiddenCategories.contains(e.category)) else { continue }
            if let years = excludedKeys[e.titleKey], years.contains(where: { Self.sameYear($0, Int(e.year)) }) { continue }
            // Year proximity (half-life ~7 years) and a small rating prior, both relative to the similarity.
            var factor: Float = 1
            if year > 0, e.year > 0 { factor += 0.2 * exp(-Float(abs(year - Int(e.year))) / 10) }
            factor += 0.1 * e.ratingPrior
            candidates.append(Candidate(item: i, score: cosine * factor))
        }
        guard !candidates.isEmpty else { return [] }
        candidates.sort { $0.score > $1.score }
        let pool = Array(candidates.prefix(max(options.limit * 8, 120)))

        // Maximal marginal relevance with a per-category cap, never two copies of one title.
        let lambda = Float(1 - min(max(options.diversity, 0), 1))
        let top = pool[0].score
        let perCategory = options.maxPerCategory ?? max(3, options.limit / 3)
        var maxSimilarity = [Float](repeating: 0, count: pool.count)
        var used = [Bool](repeating: false, count: pool.count)
        var categoryCounts: [Int32: Int] = [:]
        var chosen: [Int] = []
        var result: [Recommendation] = []

        while result.count < options.limit {
            var best = -1
            var bestValue = -Float.infinity
            var bestCapped = -1
            var bestCappedValue = -Float.infinity
            for (c, candidate) in pool.enumerated() where !used[c] {
                let value = lambda * candidate.score / top - (1 - lambda) * maxSimilarity[c]
                let category = entries[candidate.item].category
                if category >= 0, categoryCounts[category, default: 0] >= perCategory {
                    if value > bestCappedValue { bestCappedValue = value; bestCapped = c }
                } else if value > bestValue {
                    bestValue = value
                    best = c
                }
            }
            if best < 0 { best = bestCapped } // only capped categories left: relax the cap
            guard best >= 0 else { break }
            used[best] = true
            let item = pool[best].item
            let entry = entries[item]
            if chosen.contains(where: { isDuplicate(entries[$0], entry) }) { continue }
            chosen.append(item)
            if entry.category >= 0 { categoryCounts[entry.category, default: 0] += 1 }
            result.append(Recommendation(id: entry.id, kind: entry.kind, score: Double(pool[best].score)))
            for (c, candidate) in pool.enumerated() where !used[c] {
                maxSimilarity[c] = max(maxSimilarity[c], dot(candidate.item, item))
            }
        }
        return result
    }

    private func isDuplicate(_ a: Entry, _ b: Entry) -> Bool {
        !a.titleKey.isEmpty && a.titleKey == b.titleKey && Self.sameYear(Int(a.year), Int(b.year))
    }

    /// Same release year, allowing for unknown years (0) and off-by-one listings.
    static func sameYear(_ a: Int, _ b: Int) -> Bool {
        a == 0 || b == 0 || abs(a - b) <= 1
    }

    /// Dot product of two item vectors (sorted sparse merge).
    private func dot(_ a: Int, _ b: Int) -> Float {
        var i = Int(rowStart[a]), j = Int(rowStart[b])
        let iEnd = Int(rowStart[a + 1]), jEnd = Int(rowStart[b + 1])
        var sum: Float = 0
        while i < iEnd, j < jEnd {
            let ti = rowTerms[i], tj = rowTerms[j]
            if ti == tj {
                sum += rowWeights[i] * rowWeights[j]
                i += 1
                j += 1
            } else if ti < tj {
                i += 1
            } else {
                j += 1
            }
        }
        return sum
    }
}
