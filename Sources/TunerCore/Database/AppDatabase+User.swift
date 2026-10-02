import Foundation
import GRDB

/// User state: favourites, hidden items, renames, history, resume points, groups, reminders, recordings.
extension AppDatabase {
    // MARK: Channel preferences

    public func setFavorite(channelId: String, _ value: Bool) async throws {
        try await writer.write { db in
            let nextOrder = (try Int.fetchOne(db, sql: "SELECT MAX(favoriteOrder) FROM channelPref") ?? 0) + 1
            try db.execute(sql: """
                INSERT INTO channelPref (channelId, isFavorite, favoriteOrder) VALUES (?, ?, ?)
                ON CONFLICT(channelId) DO UPDATE SET isFavorite = excluded.isFavorite,
                    favoriteOrder = CASE WHEN excluded.isFavorite THEN COALESCE(favoriteOrder, excluded.favoriteOrder) ELSE NULL END
                """, arguments: [channelId, value, value ? nextOrder : nil])
        }
    }

    public func reorderFavorites(_ channelIds: [String]) async throws {
        try await writer.write { db in
            for (i, id) in channelIds.enumerated() {
                try db.execute(sql: "UPDATE channelPref SET favoriteOrder = ? WHERE channelId = ?", arguments: [i, id])
            }
        }
    }

    public func setHidden(channelId: String, _ value: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO channelPref (channelId, isHidden) VALUES (?, ?)
                ON CONFLICT(channelId) DO UPDATE SET isHidden = excluded.isHidden
                """, arguments: [channelId, value])
        }
    }

    public func setAlias(channelId: String, _ alias: String?) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO channelPref (channelId, alias) VALUES (?, ?)
                ON CONFLICT(channelId) DO UPDATE SET alias = excluded.alias
                """, arguments: [channelId, alias?.nilIfEmpty])
        }
    }

    /// Pins a channel to a specific XMLTV id (or `nil` to return to automatic matching).
    public func setEPGOverride(channelId: String, xmltvId: String?) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO channelPref (channelId, epgIdOverride) VALUES (?, ?)
                ON CONFLICT(channelId) DO UPDATE SET epgIdOverride = excluded.epgIdOverride
                """, arguments: [channelId, xmltvId?.nilIfEmpty])
        }
    }

    public func setCategoryHidden(categoryId: String, _ value: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO categoryPref (categoryId, isHidden) VALUES (?, ?)
                ON CONFLICT(categoryId) DO UPDATE SET isHidden = excluded.isHidden
                """, arguments: [categoryId, value])
        }
    }

    public func setCategoryAlias(categoryId: String, _ alias: String?) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO categoryPref (categoryId, alias) VALUES (?, ?)
                ON CONFLICT(categoryId) DO UPDATE SET alias = excluded.alias
                """, arguments: [categoryId, alias?.nilIfEmpty])
        }
    }

    // MARK: History

    public func recordWatched(channelId: String, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO history (channelId, watchedAt) VALUES (?, ?)", arguments: [channelId, date])
            // keep the 50 most recent
            try db.execute(sql: "DELETE FROM history WHERE channelId NOT IN (SELECT channelId FROM history ORDER BY watchedAt DESC LIMIT 50)")
        }
    }

    public func clearHistory() async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM history") }
    }

    // MARK: Watch progress

    public func progress(mediaId: String) async throws -> WatchProgress? {
        try await writer.read { db in try WatchProgress.fetchOne(db, key: mediaId) }
    }

    public func progress(seriesId: String) async throws -> [String: WatchProgress] {
        try await writer.read { db in
            let list = try WatchProgress.filter(Column("seriesId") == seriesId).fetchAll(db)
            return Dictionary(list.map { ($0.mediaId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Saves a resume point; ignores zero-length media so a failed load can't wipe progress.
    public func saveProgress(_ progress: WatchProgress) async throws {
        guard progress.duration > 0 else { return }
        try await writer.write { db in
            var p = progress
            p.completed = WatchProgress.isComplete(position: p.position, duration: p.duration)
            try p.save(db)
        }
    }

    public func markWatched(_ progress: WatchProgress, watched: Bool) async throws {
        try await writer.write { db in
            var p = progress
            p.completed = watched
            p.position = watched ? max(p.duration, 1) : 0
            p.duration = max(p.duration, 1)
            p.updatedAt = Date()
            try p.save(db)
        }
    }

    /// Marks many items watched (played to the end) or unwatched (back to the start) in one transaction.
    public func markWatched(_ items: [WatchProgress], watched: Bool) async throws {
        guard !items.isEmpty else { return }
        try await writer.write { db in
            let now = Date()
            for item in items {
                var p = item
                p.duration = max(p.duration, 1)
                p.completed = watched
                p.position = watched ? p.duration : 0
                p.updatedAt = now
                try p.save(db)
            }
        }
    }

    public func deleteProgress(mediaId: String) async throws {
        try await writer.write { db in _ = try WatchProgress.deleteOne(db, key: mediaId) }
    }

    /// Unfinished movies/episodes, most recent first (one entry per series).
    public func continueWatching(limit: Int = 20) async throws -> [WatchProgress] {
        try await writer.read { db in
            let rows = try WatchProgress.fetchAll(db, sql: """
                SELECT * FROM watchProgress WHERE completed = 0 AND position > 10 AND kind IN ('movie', 'episode')
                ORDER BY updatedAt DESC LIMIT 100
                """)
            var seenSeries = Set<String>()
            var result: [WatchProgress] = []
            for p in rows {
                if let s = p.seriesId {
                    guard seenSeries.insert(s).inserted else { continue }
                }
                result.append(p)
                if result.count == limit { break }
            }
            return result
        }
    }

    // MARK: VOD favourites

    public func isVODFavorite(mediaId: String) async throws -> Bool {
        try await writer.read { db in try Bool.fetchOne(db, sql: "SELECT 1 FROM vodFavorite WHERE mediaId = ?", arguments: [mediaId]) ?? false }
    }

    public func setVODFavorite(mediaId: String, kind: MediaKind, _ value: Bool) async throws {
        try await writer.write { db in
            if value {
                try db.execute(sql: "INSERT OR REPLACE INTO vodFavorite (mediaId, kind, addedAt) VALUES (?, ?, ?)", arguments: [mediaId, kind, Date()])
            } else {
                try db.execute(sql: "DELETE FROM vodFavorite WHERE mediaId = ?", arguments: [mediaId])
            }
        }
    }

    public func favoriteMovies() async throws -> [Movie] {
        try await writer.read { db in
            try Movie.fetchAll(db, sql: "SELECT m.* FROM movie m JOIN vodFavorite f ON f.mediaId = m.id ORDER BY f.addedAt DESC")
        }
    }

    public func favoriteSeries() async throws -> [Series] {
        try await writer.read { db in
            try Series.fetchAll(db, sql: "SELECT m.* FROM series m JOIN vodFavorite f ON f.mediaId = m.id ORDER BY f.addedAt DESC")
        }
    }

    // MARK: Custom groups

    public func customGroups() async throws -> [CustomGroup] {
        try await writer.read { db in try CustomGroup.order(Column("sortIndex")).fetchAll(db) }
    }

    @discardableResult
    public func createGroup(name: String) async throws -> CustomGroup {
        try await writer.write { db in
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM customGroup") ?? -1) + 1
            let group = CustomGroup(name: name, sortIndex: next)
            try group.insert(db)
            return group
        }
    }

    public func renameGroup(id: String, name: String) async throws {
        try await writer.write { db in try db.execute(sql: "UPDATE customGroup SET name = ? WHERE id = ?", arguments: [name, id]) }
    }

    public func deleteGroup(id: String) async throws {
        try await writer.write { db in _ = try CustomGroup.deleteOne(db, key: id) }
    }

    public func addToGroup(groupId: String, channelId: String) async throws {
        try await writer.write { db in
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM customGroupMember WHERE groupId = ?", arguments: [groupId]) ?? -1) + 1
            try db.execute(sql: "INSERT OR IGNORE INTO customGroupMember (groupId, channelId, sortIndex) VALUES (?, ?, ?)", arguments: [groupId, channelId, next])
        }
    }

    public func removeFromGroup(groupId: String, channelId: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM customGroupMember WHERE groupId = ? AND channelId = ?", arguments: [groupId, channelId])
        }
    }

    public func groupCounts() async throws -> [String: Int] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT groupId, COUNT(*) AS n FROM customGroupMember GROUP BY groupId")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["groupId"] as String, $0["n"] as Int) })
        }
    }

    // MARK: Reminders

    public func reminders() async throws -> [Reminder] {
        try await writer.read { db in try Reminder.order(Column("start")).fetchAll(db) }
    }

    public func save(_ reminder: Reminder) async throws {
        try await writer.write { db in try reminder.save(db) }
    }

    public func deleteReminder(id: String) async throws {
        try await writer.write { db in _ = try Reminder.deleteOne(db, key: id) }
    }

    public func deleteReminder(programKey: String) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM reminder WHERE programKey = ?", arguments: [programKey]) }
    }

    public func deleteExpiredReminders(before date: Date = Date()) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM reminder WHERE end < ?", arguments: [date]) }
    }

    // MARK: Recordings

    public func recordings() async throws -> [Recording] {
        try await writer.read { db in try Recording.order(Column("start").desc).fetchAll(db) }
    }

    public func save(_ recording: Recording) async throws {
        try await writer.write { db in try recording.save(db) }
    }

    public func deleteRecording(id: String) async throws {
        try await writer.write { db in _ = try Recording.deleteOne(db, key: id) }
    }
}
