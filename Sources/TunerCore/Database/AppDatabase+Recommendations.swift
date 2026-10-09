import Foundation
import GRDB

/// Cheap fingerprint of what the recommendation index is built from; a rebuild is only needed when it changes.
struct RecommendationSignature: Hashable, Sendable {
    var values: [String]
}

/// Reads for the recommender (`Recommender`): the library as recommendation items, a change fingerprint, and the
/// user's signals. No tables of its own: everything comes from the library, `mediaMetadata` and user state.
extension AppDatabase {
    /// Counts and sizes of the movie/series/category tables, enabled VOD sources, and the number of cached online
    /// matches in steps of 50 (so opening titles one by one doesn't rebuild the index each time).
    func recommendationSignature() async throws -> RecommendationSignature {
        try await writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM movie) AS movies, (SELECT TOTAL(LENGTH(name)) FROM movie) AS movieNames,
                    (SELECT MAX(addedAt) FROM movie) AS movieAdded,
                    (SELECT COUNT(*) FROM series) AS series, (SELECT TOTAL(LENGTH(name)) FROM series) AS seriesNames,
                    (SELECT MAX(addedAt) FROM series) AS seriesAdded,
                    (SELECT COUNT(*) FROM category WHERE kind <> 'live') AS categories,
                    (SELECT GROUP_CONCAT(id, ',') FROM (SELECT id FROM source WHERE enabled = 1 AND includeVOD = 1 ORDER BY id)) AS sources,
                    (SELECT COUNT(*) FROM mediaMetadata WHERE notFound = 0) / 50 AS metadata
                """)
            guard let row else { return RecommendationSignature(values: []) }
            return RecommendationSignature(values: row.columnNames.map { name in
                (row[name] as DatabaseValue).description
            })
        }
    }

    /// Every movie and show of enabled VOD sources, with category names and cached online metadata.
    func recommendationCorpus() async throws -> [RecommendationItem] {
        try await writer.read { db in
            var extras: [String: RecommendationMetadata] = [:]
            let decoder = JSONDecoder()
            let metadataRows = try Row.fetchCursor(db, sql: "SELECT mediaId, json FROM mediaMetadata WHERE notFound = 0 AND json IS NOT NULL")
            while let row = try metadataRows.next() {
                let json: String = row["json"]
                if let extra = try? decoder.decode(RecommendationMetadata.self, from: Data(json.utf8)) { extras[row["mediaId"]] = extra }
            }

            var items: [RecommendationItem] = []
            for (table, kind) in [("movie", RecommendationItem.Kind.movie), ("series", .series)] {
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT m.id, m.categoryId, m.name, m.year, m.releaseDate, m.rating, m.genre, m.cast, m.director, m.plot,
                        cat.name AS categoryName
                    FROM \(table) m
                    JOIN source s ON s.id = m.sourceId AND s.enabled = 1 AND s.includeVOD = 1
                    LEFT JOIN category cat ON cat.id = m.categoryId
                    """)
                while let row = try rows.next() {
                    let id: String = row["id"]
                    items.append(RecommendationItem(
                        id: id, kind: kind, title: row["name"], providerYear: row["year"], releaseDate: row["releaseDate"],
                        rating: row["rating"], categoryId: row["categoryId"], categoryName: row["categoryName"], genre: row["genre"],
                        cast: row["cast"], director: row["director"], plot: row["plot"], extra: extras[id]
                    ))
                }
            }
            return items
        }
    }

    /// Movie/show ids the user has started or finished (episodes count for their show) and their VOD favourites.
    func recommendationSignals() async throws -> RecommendationSignals {
        try await writer.read { db in
            let progress = try WatchProgress.fetchAll(db, sql: """
                SELECT * FROM watchProgress WHERE kind IN ('movie', 'episode') AND (completed = 1 OR position > 10)
                ORDER BY updatedAt DESC LIMIT 500
                """)
            let favorites = try String.fetchAll(db, sql: "SELECT mediaId FROM vodFavorite ORDER BY addedAt DESC")
            return RecommendationSignals(progress: progress, favoriteIds: favorites)
        }
    }

    /// Ids of categories the user has hidden.
    public func hiddenCategoryIds() async throws -> Set<String> {
        try await writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT categoryId FROM categoryPref WHERE isHidden = 1"))
        }
    }

    /// Ids of favourite movies and shows.
    public func vodFavoriteIds() async throws -> Set<String> {
        try await writer.read { db in Set(try String.fetchAll(db, sql: "SELECT mediaId FROM vodFavorite")) }
    }

    /// Movies by id, in the given order (unknown ids are skipped).
    public func movies(ids: [String]) async throws -> [Movie] {
        guard !ids.isEmpty else { return [] }
        let found = try await writer.read { db in
            try ids.chunked(500).flatMap { chunk in
                try Movie.fetchAll(db, sql: "SELECT * FROM movie WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))",
                                   arguments: StatementArguments(chunk))
            }
        }
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    /// Shows by id, in the given order (unknown ids are skipped).
    public func series(ids: [String]) async throws -> [Series] {
        guard !ids.isEmpty else { return [] }
        let found = try await writer.read { db in
            try ids.chunked(500).flatMap { chunk in
                try Series.fetchAll(db, sql: "SELECT * FROM series WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))",
                                    arguments: StatementArguments(chunk))
            }
        }
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }
}
