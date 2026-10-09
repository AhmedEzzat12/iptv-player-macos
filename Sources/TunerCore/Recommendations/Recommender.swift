import Foundation
import OSLog

/// What the user has watched and liked, as seeds for "Because You Watched" rows and as titles to leave out.
struct RecommendationSignals: Sendable {
    struct Seed: Sendable, Hashable {
        var id: String
        var reason: Recommender.Reason
    }

    /// Most recent first: finished or mostly watched (≥ 50 %) movies and shows (a show counts once, at its latest
    /// such episode), then VOD favourites that aren't seeds already.
    var seeds: [Seed]
    /// Movies and shows with any progress, and favourites: already known, so never recommended on Home.
    var seenIds: Set<String>

    init(progress: [WatchProgress], favoriteIds: [String]) {
        var seeds: [Seed] = []
        var seedIds = Set<String>()
        var seen = Set<String>()
        for p in progress {
            let id: String
            switch p.kind {
            case .movie: id = p.mediaId
            case .episode:
                guard let seriesId = p.seriesId else { continue }
                id = seriesId
            case .channel: continue
            }
            seen.insert(id)
            if p.completed || p.fraction >= 0.5, seedIds.insert(id).inserted {
                seeds.append(Seed(id: id, reason: .watched))
            }
        }
        for id in favoriteIds {
            seen.insert(id)
            if seedIds.insert(id).inserted { seeds.append(Seed(id: id, reason: .liked)) }
        }
        self.seeds = seeds
        seenIds = seen
    }
}

/// On-device recommendations ("More Like This", "Because You Watched") over a `RecommendationIndex` of the library.
///
/// The index is built lazily on first use, off the main actor, and cached. Callers pass the app's library revision:
/// when it moves on, the next query checks a cheap fingerprint of the library (`recommendationSignature`) and, if it
/// changed, rebuilds in the background while queries keep using the previous index. Hidden categories and the adult
/// filter are applied per query, so changing them needs no rebuild. `clear()` frees the index (feature switched off).
public actor Recommender {
    public enum Reason: String, Sendable, Hashable {
        /// Finished or mostly watched.
        case watched
        /// A VOD favourite.
        case liked
    }

    public enum Title: Sendable, Hashable, Identifiable {
        case movie(Movie)
        case series(Series)

        public var id: String {
            switch self {
            case .movie(let m): m.id
            case .series(let s): s.id
            }
        }

        public var name: String {
            switch self {
            case .movie(let m): m.name
            case .series(let s): s.name
            }
        }
    }

    /// A "Because You Watched <seed>" row.
    public struct Row: Sendable, Hashable, Identifiable {
        public var seed: Title
        public var reason: Reason
        public var titles: [Title]
        public var id: String { seed.id }
    }

    static let log = Logger(subsystem: "app.tuner.macos", category: "Recommendations")

    private enum BuildOutcome: Sendable {
        case built(RecommendationIndex, RecommendationSignature)
        case unchanged
        case failed
    }

    let db: AppDatabase
    private var index: RecommendationIndex?
    private var signature: RecommendationSignature?
    /// Library revision the index was last checked against.
    private var checkedRevision: Int?
    private var building: Task<BuildOutcome, Never>?

    public init(db: AppDatabase) {
        self.db = db
    }

    // MARK: Queries

    /// Movies like `movie` (its page's details and online metadata make the query; the library is searched).
    public func moreLike(movie: Movie, metadata: MediaMetadata?, libraryRevision: Int, hideAdult: Bool, limit: Int = 20) async -> [Movie] {
        let category = await categoryName(movie.categoryId)
        let item = RecommendationItem(movie: movie, categoryName: category, metadata: metadata)
        let ids = await similar(to: item, libraryRevision: libraryRevision, hideAdult: hideAdult, limit: limit)
        return (try? await db.movies(ids: ids)) ?? []
    }

    /// Shows like `series`.
    public func moreLike(series: Series, metadata: MediaMetadata?, libraryRevision: Int, hideAdult: Bool, limit: Int = 20) async -> [Series] {
        let category = await categoryName(series.categoryId)
        let item = RecommendationItem(series: series, categoryName: category, metadata: metadata)
        let ids = await similar(to: item, libraryRevision: libraryRevision, hideAdult: hideAdult, limit: limit)
        return (try? await db.series(ids: ids)) ?? []
    }

    /// Up to `rows` rows for Home, each seeded by a recently finished or mostly watched title (else a favourite),
    /// leaving out everything the user has started, finished or favourited, and titles already in an earlier row.
    /// Seeds that are hidden, adult (when hidden) or nearly the same as an earlier seed are skipped.
    public func becauseYouWatched(libraryRevision: Int, hideAdult: Bool, rows maxRows: Int = 2, limit: Int = 20) async -> [Row] {
        guard maxRows > 0, let index = await currentIndex(libraryRevision: libraryRevision),
              let signals = try? await db.recommendationSignals(), !signals.seeds.isEmpty else { return [] }
        let hidden = (try? await db.hiddenCategoryIds()) ?? []
        let planned = Self.plan(index: index, signals: signals, hiddenCategoryIds: hidden, hideAdult: hideAdult, rows: maxRows, limit: limit)
        guard !planned.isEmpty else { return [] }

        let movieIds = planned.flatMap { [$0.seed] + $0.titles }.filter { $0.kind == .movie }.map(\.id)
        let seriesIds = planned.flatMap { [$0.seed] + $0.titles }.filter { $0.kind == .series }.map(\.id)
        let movies = Dictionary(((try? await db.movies(ids: movieIds)) ?? []).map { ($0.id, Title.movie($0)) }, uniquingKeysWith: { a, _ in a })
        let series = Dictionary(((try? await db.series(ids: seriesIds)) ?? []).map { ($0.id, Title.series($0)) }, uniquingKeysWith: { a, _ in a })
        func title(_ r: Recommendation) -> Title? { r.kind == .movie ? movies[r.id] : series[r.id] }

        return planned.compactMap { row in
            guard let seed = title(row.seed) else { return nil }
            let titles = row.titles.compactMap(title)
            return titles.isEmpty ? nil : Row(seed: seed, reason: row.reason, titles: titles)
        }
    }

    struct PlannedRow: Sendable {
        var seed: Recommendation
        var reason: Reason
        var titles: [Recommendation]
    }

    /// Picks seeds and their recommendations (pure; see `becauseYouWatched`).
    static func plan(index: RecommendationIndex, signals: RecommendationSignals, hiddenCategoryIds: Set<String>, hideAdult: Bool,
                     rows maxRows: Int, limit: Int, minTitles: Int = 3) -> [PlannedRow] {
        var planned: [PlannedRow] = []
        var shown = Set<String>()
        for seed in signals.seeds.prefix(30) {
            guard planned.count < maxRows, let entry = index.entry(seed.id) else { continue }
            if hideAdult, entry.isAdult { continue }
            if let category = index.categoryId(of: seed.id), hiddenCategoryIds.contains(category) { continue }
            // Two rows about the same thing (another copy, or a near-identical title) aren't worth it.
            if planned.contains(where: { index.similarity($0.seed.id, seed.id) > 0.8 || index.isSameTitle($0.seed.id, seed.id) }) { continue }
            let options = RecommendationOptions(limit: limit, excludedIds: signals.seenIds.union(shown),
                                                hiddenCategoryIds: hiddenCategoryIds, hideAdult: hideAdult)
            let titles = index.similar(toId: seed.id, options: options)
            guard titles.count >= minTitles else { continue }
            shown.formUnion(titles.map(\.id))
            planned.append(PlannedRow(seed: Recommendation(id: seed.id, kind: entry.kind, score: 1), reason: seed.reason, titles: titles))
        }
        return planned
    }

    /// Frees the index (the feature was switched off); the next query builds it again.
    public func clear() {
        building?.cancel()
        building = nil
        index = nil
        signature = nil
        checkedRevision = nil
    }

    // MARK: Index

    private func similar(to item: RecommendationItem, libraryRevision: Int, hideAdult: Bool, limit: Int) async -> [String] {
        guard let index = await currentIndex(libraryRevision: libraryRevision) else { return [] }
        let hidden = (try? await db.hiddenCategoryIds()) ?? []
        let options = RecommendationOptions(limit: limit, hiddenCategoryIds: hidden, hideAdult: hideAdult)
        return index.similar(to: item, options: options).map(\.id)
    }

    private func categoryName(_ id: String?) async -> String? {
        guard let id else { return nil }
        return try? await db.category(id: id)?.name
    }

    /// The index for this library revision: built on first use (callers wait), afterwards refreshed in the background
    /// when the library's fingerprint changed (callers get the previous index meanwhile).
    func currentIndex(libraryRevision: Int) async -> RecommendationIndex? {
        if checkedRevision != libraryRevision, building == nil {
            checkedRevision = libraryRevision
            let known = signature
            let task = Task.detached(priority: .utility) { [db] in await Self.build(db: db, unless: known) }
            building = task
            if index == nil {
                await finish(task)
            } else {
                Task { await self.finish(task) }
            }
        } else if index == nil, let building {
            await finish(building)
        }
        return index
    }

    private func finish(_ task: Task<BuildOutcome, Never>) async {
        let outcome = await task.value
        guard building == task else { return }
        building = nil
        switch outcome {
        case .built(let newIndex, let newSignature):
            index = newIndex
            signature = newSignature
        case .unchanged:
            break
        case .failed:
            checkedRevision = nil // try again on the next query
        }
    }

    private static func milliseconds(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func build(db: AppDatabase, unless known: RecommendationSignature?) async -> BuildOutcome {
        do {
            let signature = try await db.recommendationSignature()
            if signature == known { return .unchanged }
            let clock = ContinuousClock()
            let start = clock.now
            let items = try await db.recommendationCorpus()
            let loaded = clock.now
            guard !Task.isCancelled else { return .failed }
            let index = RecommendationIndex(items: items)
            let done = clock.now
            log.info("Index: \(index.count) titles, \(index.termCount) terms, \(index.nonZeroCount) weights; load \(milliseconds(loaded - start)) ms, build \(milliseconds(done - loaded)) ms")
            return .built(index, signature)
        } catch {
            log.error("Index build failed: \(error.localizedDescription)")
            return .failed
        }
    }
}
