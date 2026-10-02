import Foundation
import GRDB

/// A series' cached IMDb episode ratings and when its datasets were scanned for them.
struct IMDbRatingsCacheEntry: Sendable, Hashable {
    var scannedAt: Date
    /// [] when the series was scanned and has no rated episodes.
    var ratings: [EpisodeRating]
}

/// IMDb episode ratings cache (`imdbEpisodeRating`, `imdbRatingScan`), keyed by the series' IMDb id ("tt…").
/// A scan row without rating rows means "scanned, no rated episodes".
extension AppDatabase {
    /// Cached ratings by season and episode; [] when the series wasn't scanned or has nothing rated.
    public func imdbEpisodeRatings(seriesId: String) async throws -> [EpisodeRating] {
        try await writer.read { db in try Self.fetchIMDbRatings(db, seriesId: seriesId) }
    }

    /// nil when the series was never scanned.
    func imdbRatingsCacheEntry(seriesId: String) async throws -> IMDbRatingsCacheEntry? {
        try await writer.read { db in
            guard let scannedAt = try Date.fetchOne(db, sql: "SELECT scannedAt FROM imdbRatingScan WHERE seriesId = ?",
                                                    arguments: [seriesId])
            else { return nil }
            return IMDbRatingsCacheEntry(scannedAt: scannedAt, ratings: try Self.fetchIMDbRatings(db, seriesId: seriesId))
        }
    }

    /// Replaces each series' ratings and stamps its scan, in one transaction.
    func saveIMDbRatings(_ ratings: [String: [EpisodeRating]], scannedAt: Date) async throws {
        try await writer.write { db in
            let insert = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO imdbEpisodeRating (seriesId, season, episode, rating, votes) VALUES (?, ?, ?, ?, ?)
                """)
            for (seriesId, episodes) in ratings {
                try db.execute(sql: "DELETE FROM imdbEpisodeRating WHERE seriesId = ?", arguments: [seriesId])
                for e in episodes {
                    try insert.execute(arguments: [seriesId, e.season, e.episode, e.rating, e.votes])
                }
                try db.execute(sql: "INSERT OR REPLACE INTO imdbRatingScan (seriesId, scannedAt) VALUES (?, ?)",
                               arguments: [seriesId, scannedAt])
            }
        }
    }

    public func clearIMDbRatingsCache() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM imdbEpisodeRating")
            try db.execute(sql: "DELETE FROM imdbRatingScan")
        }
    }

    static func fetchIMDbRatings(_ db: Database, seriesId: String) throws -> [EpisodeRating] {
        try Row.fetchAll(db, sql: """
            SELECT season, episode, rating, votes FROM imdbEpisodeRating WHERE seriesId = ? ORDER BY season, episode
            """, arguments: [seriesId])
            .map { EpisodeRating(season: $0["season"], episode: $0["episode"], rating: $0["rating"], votes: $0["votes"]) }
    }
}
