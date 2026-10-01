import Foundation
import GRDB

/// A cached online-metadata lookup: a match, or a remembered "not found".
public struct MetadataCacheEntry: Sendable, Hashable {
    public var mediaId: String
    public var kind: MediaMetadata.Kind
    /// nil for "not found" (or a row that no longer decodes).
    public var metadata: MediaMetadata?
    public var notFound: Bool
    public var fetchedAt: Date

    /// Matches are refreshed after 30 days, "not found" after 7.
    public static let matchTTL: TimeInterval = 30 * 86_400
    public static let notFoundTTL: TimeInterval = 7 * 86_400

    public init(mediaId: String, kind: MediaMetadata.Kind, metadata: MediaMetadata?, notFound: Bool, fetchedAt: Date) {
        self.mediaId = mediaId
        self.kind = kind
        self.metadata = metadata
        self.notFound = notFound
        self.fetchedAt = fetchedAt
    }

    public func isFresh(at now: Date = Date()) -> Bool {
        if notFound { return now.timeIntervalSince(fetchedAt) < Self.notFoundTTL }
        return metadata != nil && now.timeIntervalSince(fetchedAt) < Self.matchTTL
    }
}

/// Online metadata cache (`mediaMetadata`). Rows are keyed by the provider's movie/series id; `json` holds the
/// encoded `MediaMetadata` (NULL for "not found").
extension AppDatabase {
    public func metadataCacheEntry(mediaId: String) async throws -> MetadataCacheEntry? {
        try await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM mediaMetadata WHERE mediaId = ?", arguments: [mediaId])
                .map(Self.metadataEntry)
        }
    }

    /// Cached matches for many ids at once (grids, shelves); "not found" rows are omitted. Never stale-checked.
    public func cachedMetadata(mediaIds: [String]) async throws -> [String: MediaMetadata] {
        guard !mediaIds.isEmpty else { return [:] }
        return try await writer.read { db in
            var out: [String: MediaMetadata] = [:]
            for chunk in mediaIds.chunked(500) {
                let marks = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(db, sql: "SELECT mediaId, json FROM mediaMetadata WHERE notFound = 0 AND mediaId IN (\(marks))",
                                            arguments: StatementArguments(chunk))
                for row in rows {
                    if let md = Self.decodeMetadata(row["json"]) { out[row["mediaId"]] = md }
                }
            }
            return out
        }
    }

    public func saveMetadata(_ metadata: MediaMetadata, mediaId: String) async throws {
        let json = try String(decoding: JSONEncoder().encode(metadata), as: UTF8.self)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO mediaMetadata (mediaId, kind, json, notFound, fetchedAt) VALUES (?, ?, ?, 0, ?)
                """, arguments: [mediaId, metadata.kind.rawValue, json, metadata.fetchedAt])
        }
    }

    public func saveMetadataNotFound(mediaId: String, kind: MediaMetadata.Kind, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO mediaMetadata (mediaId, kind, json, notFound, fetchedAt) VALUES (?, ?, NULL, 1, ?)
                """, arguments: [mediaId, kind.rawValue, date])
        }
    }

    /// Re-dates a row (a refresh that confirmed the cached value).
    func touchMetadata(mediaId: String, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE mediaMetadata SET fetchedAt = ? WHERE mediaId = ?", arguments: [date, mediaId])
        }
    }

    /// Makes every row stale (refetched on next lookup) while keeping cached values visible meanwhile.
    public func markMetadataStale() async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE mediaMetadata SET fetchedAt = ?", arguments: [Date(timeIntervalSince1970: 0)])
        }
    }

    public func clearMetadataCache() async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM mediaMetadata") }
    }

    static func metadataEntry(_ row: Row) -> MetadataCacheEntry {
        let notFound: Bool = row["notFound"] ?? false
        let kind = MediaMetadata.Kind(rawValue: row["kind"] ?? "") ?? .movie
        return MetadataCacheEntry(
            mediaId: row["mediaId"],
            kind: kind,
            metadata: notFound ? nil : decodeMetadata(row["json"]),
            notFound: notFound,
            fetchedAt: row["fetchedAt"] ?? Date(timeIntervalSince1970: 0)
        )
    }

    static func decodeMetadata(_ json: String?) -> MediaMetadata? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MediaMetadata.self, from: data)
    }
}
