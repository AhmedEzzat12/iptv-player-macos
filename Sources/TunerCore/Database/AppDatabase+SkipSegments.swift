import Foundation
import GRDB

/// A cached online skip-timings lookup: what the databases had for a movie/episode (empty = not found).
public struct SkipSegmentCacheEntry: Sendable, Hashable {
    public var segments: [SkipSegment]
    public var fetchedAt: Date

    public var notFound: Bool { segments.isEmpty }

    public func isFresh(at now: Date, foundTTL: TimeInterval, notFoundTTL: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) < (notFound ? notFoundTTL : foundTTL)
    }
}

/// Skip Intro / Skip Credits data: `skipSegmentCache` (online timings per movie/episode id) and `skipLearnedSpan`
/// (spans the user skipped by hand, per show and episode; see `SkipLearner`).
extension AppDatabase {
    public func skipSegmentCache(mediaId: String) async throws -> SkipSegmentCacheEntry? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT json, fetchedAt FROM skipSegmentCache WHERE mediaId = ?",
                                             arguments: [mediaId]) else { return nil }
            let json: String = row["json"] ?? "[]"
            let segments = (try? JSONDecoder().decode([SkipSegment].self, from: Data(json.utf8))) ?? []
            return SkipSegmentCacheEntry(segments: segments, fetchedAt: row["fetchedAt"] ?? Date(timeIntervalSince1970: 0))
        }
    }

    public func saveSkipSegments(_ segments: [SkipSegment], mediaId: String, at date: Date = Date()) async throws {
        let json = try String(decoding: JSONEncoder().encode(segments), as: UTF8.self)
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO skipSegmentCache (mediaId, json, fetchedAt) VALUES (?, ?, ?)",
                           arguments: [mediaId, json, date])
        }
    }

    public func clearSkipSegmentCache() async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM skipSegmentCache") }
    }

    public func learnedSkipSpans(seriesId: String) async throws -> [LearnedSkipSpan] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT episodeId, start, "end", confirmed FROM skipLearnedSpan WHERE seriesId = ? ORDER BY recordedAt DESC
                """, arguments: [seriesId]).map {
                LearnedSkipSpan(episodeId: $0["episodeId"], start: $0["start"], end: $0["end"], confirmed: $0["confirmed"])
            }
        }
    }

    /// One span per episode and kind (hand-skipped or confirmed): a newer one replaces the older.
    public func saveLearnedSkipSpan(_ span: LearnedSkipSpan, seriesId: String, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO skipLearnedSpan (seriesId, episodeId, confirmed, start, "end", recordedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [seriesId, span.episodeId, span.confirmed, span.start, span.end, date])
        }
    }
}
