import Foundation
import GRDB

/// A cached chart and when it was last confirmed current.
struct CachedChart: Sendable, Hashable {
    var chart: PopularityChart
    /// The server's Last-Modified, sent back as If-Modified-Since.
    var lastModified: String?
    var checkedAt: Date
}

/// Home's "Top 10" rows: cached charts (`popularityChart`) and the library items a chart could match.
extension AppDatabase {
    func cachedChart(_ source: ChartSource) async throws -> CachedChart? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM popularityChart WHERE id = ?", arguments: [source.cacheKey]),
                  let json: String = row["json"],
                  let chart = try? JSONDecoder().decode(PopularityChart.self, from: Data(json.utf8)) else { return nil }
            return CachedChart(chart: chart, lastModified: row["lastModified"], checkedAt: row["checkedAt"])
        }
    }

    func saveChart(_ cached: CachedChart) async throws {
        let json = String(decoding: try JSONEncoder().encode(cached.chart), as: UTF8.self)
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO popularityChart (id, json, lastModified, checkedAt) VALUES (?, ?, ?, ?)",
                           arguments: [cached.chart.source.cacheKey, json, cached.lastModified, cached.checkedAt])
        }
    }

    func touchChart(_ source: ChartSource, at date: Date) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE popularityChart SET checkedAt = ? WHERE id = ?", arguments: [date, source.cacheKey])
        }
    }

    /// Visible library items (enabled playlists with movies & shows, categories not hidden, adult categories left out
    /// when asked) whose name contains one of `words`, or whose provider/cached-metadata ids are among the given ones.
    func topTenCandidates(kind: MediaMetadata.Kind, words: [String], imdbIds: [String], tmdbIds: [String],
                          hideAdult: Bool) async throws -> [TopTenMatcher.Candidate] {
        let table = kind == .movie ? "movie" : "series"
        let artwork = kind == .movie ? "m.posterURL" : "m.coverURL"
        let providerTMDB = kind == .movie ? "m.tmdbId" : "NULL"
        var visible = """
            SELECT m.id, m.name, COALESCE(m.year, m.releaseDate) AS year, m.sourceId, \(providerTMDB) AS tmdbId,
                COALESCE(\(artwork), '') <> '' AS hasArtwork
            FROM \(table) m
            JOIN source s ON s.id = m.sourceId AND s.enabled = 1 AND s.includeVOD = 1
            LEFT JOIN categoryPref cp ON cp.categoryId = m.categoryId
            LEFT JOIN category c ON c.id = m.categoryId
            WHERE COALESCE(cp.isHidden, 0) = 0
            """
        if hideAdult {
            visible += """
                 AND NOT (COALESCE(c.name, '') LIKE '%adult%' OR COALESCE(c.name, '') LIKE '%xxx%'
                    OR COALESCE(c.name, '') LIKE '%18+%' OR COALESCE(c.name, '') LIKE '%+18%')
                """
        }
        let words = Array(Set(words.filter { !$0.isEmpty })).sorted()
        let imdbIds = Array(Set(imdbIds)).sorted(), tmdbIds = Array(Set(tmdbIds)).sorted()
        let base = visible

        return try await writer.read { db in
            var byId: [String: TopTenMatcher.Candidate] = [:]
            func collect(_ sql: String, _ args: [any DatabaseValueConvertible]) throws {
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                    let id: String = row["id"]
                    guard byId[id] == nil else { continue }
                    byId[id] = TopTenMatcher.Candidate(mediaId: id, name: row["name"], year: row["year"], sourceId: row["sourceId"],
                                                       tmdbId: (row["tmdbId"] as String?)?.nilIfEmpty, hasArtwork: row["hasArtwork"])
                }
            }
            if !words.isEmpty {
                let likes = words.map { _ in "m.name LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
                try collect(base + " AND (\(likes)) LIMIT 3000", words.map { "%\(Self.escapeLike($0))%" })
            }
            if kind == .movie, !tmdbIds.isEmpty {
                try collect(base + " AND m.tmdbId IN (\(databaseQuestionMarks(count: tmdbIds.count)))", tmdbIds)
            }
            if !imdbIds.isEmpty || !tmdbIds.isEmpty {
                var conditions: [String] = []
                var args: [any DatabaseValueConvertible] = [kind.rawValue]
                if !imdbIds.isEmpty {
                    conditions.append("json_extract(json, '$.imdbId') IN (\(databaseQuestionMarks(count: imdbIds.count)))")
                    args += imdbIds
                }
                if !tmdbIds.isEmpty {
                    conditions.append("json_extract(json, '$.tmdbId') IN (\(databaseQuestionMarks(count: tmdbIds.count)))")
                    args += tmdbIds
                }
                try collect(base + """
                     AND m.id IN (SELECT mediaId FROM mediaMetadata WHERE notFound = 0 AND kind = ? AND (\(conditions.joined(separator: " OR "))))
                    """, args)
            }

            // Ids from cached online metadata, for id matches and to rule out same-name titles.
            for chunk in Array(byId.keys).chunked(500) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT mediaId, json_extract(json, '$.imdbId') AS imdbId, json_extract(json, '$.tmdbId') AS tmdbId
                    FROM mediaMetadata WHERE notFound = 0 AND mediaId IN (\(databaseQuestionMarks(count: chunk.count)))
                    """, arguments: StatementArguments(chunk))
                for row in rows {
                    let id: String = row["mediaId"]
                    byId[id]?.imdbId = (row["imdbId"] as String?)?.nilIfEmpty
                    if byId[id]?.tmdbId == nil { byId[id]?.tmdbId = (row["tmdbId"] as String?)?.nilIfEmpty }
                }
            }
            return byId.values.sorted { $0.mediaId < $1.mediaId }
        }
    }

    /// Movies and episodes watched per playlist (to prefer the user's usual playlist among duplicates).
    func watchCountsBySource() async throws -> [String: Int] {
        try await writer.read { db in
            var out: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT sourceId, COUNT(*) AS n FROM watchProgress WHERE kind <> 'channel' GROUP BY sourceId") {
                out[row["sourceId"]] = row["n"]
            }
            return out
        }
    }
}
