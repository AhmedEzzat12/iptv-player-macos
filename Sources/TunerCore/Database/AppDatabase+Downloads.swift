import Foundation
import GRDB

extension DownloadItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "download"
}

extension DownloadItem.Kind: DatabaseValueConvertible {}
extension DownloadItem.State: DatabaseValueConvertible {}

extension DownloadItem {
    /// Failed because its saved file was moved or deleted.
    var isMissingFile: Bool { state == .failed && error == AppDatabase.missingDownloadMessage }

    /// A download marked "File was moved or deleted" whose file is back (e.g. a drive was reconnected) is completed
    /// again. Returns true when it was restored.
    mutating func restoreIfFileReturned(now: Date = Date()) -> Bool {
        guard isMissingFile, let path = filePath, FileManager.default.fileExists(atPath: path) else { return false }
        state = .completed
        error = nil
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value {
            receivedBytes = size
            totalBytes = size
        }
        updatedAt = now
        return true
    }
}

/// Downloads for offline viewing (`download`, one row per movie/episode id; see `DownloadService`). Only the service
/// writes here, except `completedDownloadFile(mediaId:)`, which also marks a download whose file has gone as failed.
extension AppDatabase {
    static let missingDownloadMessage = "File was moved or deleted"

    /// Every download, newest first.
    func downloads() async throws -> [DownloadItem] {
        try await writer.read { db in
            try DownloadItem.fetchAll(db, sql: "SELECT * FROM download ORDER BY createdAt DESC, rowid DESC")
        }
    }

    func download(id: String) async throws -> DownloadItem? {
        try await writer.read { db in try DownloadItem.fetchOne(db, key: id) }
    }

    /// Queued downloads in the order they run: first in, first out.
    func queuedDownloads() async throws -> [DownloadItem] {
        try await writer.read { db in
            try DownloadItem.fetchAll(db, sql: "SELECT * FROM download WHERE state = ? ORDER BY createdAt, rowid",
                                      arguments: [DownloadItem.State.queued])
        }
    }

    /// Appends `items` to the queue in the given order and returns the ids that were queued. Ids that are already
    /// queued, running, paused or downloaded are skipped; a failed download, or a completed one whose file has gone,
    /// is queued again (at the back, keeping partial data). `createdAt` strictly increases so FIFO order survives
    /// SQLite's millisecond date precision.
    func enqueueDownloads(_ items: [DownloadItem], now: Date = Date()) async throws -> [String] {
        try await writer.write { db in
            let latest = try Date.fetchOne(db, sql: "SELECT MAX(createdAt) FROM download")
            var stamp = max(now, (latest ?? .distantPast).addingTimeInterval(0.001))
            var queued: [String] = []
            for item in items {
                var row: DownloadItem
                if var existing = try DownloadItem.fetchOne(db, key: item.id) {
                    if existing.restoreIfFileReturned(now: now) {
                        try existing.update(db)
                        continue
                    }
                    let fileGone = existing.isMissingFile
                        || (existing.state == .completed && !(existing.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false))
                    guard existing.state == .failed || fileGone else { continue }
                    row = existing
                    if fileGone {
                        row.filePath = nil
                        row.receivedBytes = 0
                        row.totalBytes = nil
                    }
                    row.title = item.title
                    row.subtitle = item.subtitle
                    row.artworkURL = item.artworkURL ?? existing.artworkURL
                } else {
                    row = item
                    row.receivedBytes = 0
                    row.totalBytes = nil
                    row.filePath = nil
                }
                row.state = .queued
                row.error = nil
                row.pausedByUser = false
                row.createdAt = stamp
                row.updatedAt = now
                try row.save(db)
                queued.append(row.id)
                stamp = stamp.addingTimeInterval(0.001)
            }
            return queued
        }
    }

    /// Marks a queued download as running (error cleared). nil when it isn't queued anymore (paused or removed).
    func claimDownload(id: String, now: Date = Date()) async throws -> DownloadItem? {
        try await writer.write { db in
            guard var item = try DownloadItem.fetchOne(db, key: id), item.state == .queued else { return nil }
            item.state = .downloading
            item.error = nil
            item.updatedAt = now
            try item.update(db)
            return item
        }
    }

    /// Applies `change` to a download in one transaction; `change` returns false to leave the row as it is.
    /// Returns the updated row, or nil when there's no such row or nothing changed. Never re-creates a deleted row.
    @discardableResult
    func updateDownload(id: String, now: Date = Date(), _ change: @escaping @Sendable (inout DownloadItem) -> Bool) async throws -> DownloadItem? {
        try await writer.write { db in
            guard var item = try DownloadItem.fetchOne(db, key: id), change(&item) else { return nil }
            item.updatedAt = now
            try item.update(db)
            return item
        }
    }

    /// Progress of a running transfer (hot path: a single UPDATE).
    func updateDownloadProgress(id: String, receivedBytes: Int64, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE download SET receivedBytes = ?, updatedAt = ? WHERE id = ?",
                           arguments: [receivedBytes, now, id])
        }
    }

    /// Deletes a download's row and returns what it was.
    func takeDownload(id: String) async throws -> DownloadItem? {
        try await writer.write { db in
            let item = try DownloadItem.fetchOne(db, key: id)
            if item != nil { _ = try DownloadItem.deleteOne(db, key: id) }
            return item
        }
    }

    /// At launch: downloads that were running, or paused automatically (while streaming), when the app quit go back
    /// to the queue. `running` (already restarted this launch) is left alone. Returns how many were queued.
    func requeueInterruptedDownloads(except running: String?, now: Date = Date()) async throws -> Int {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE download SET state = 'queued', updatedAt = ?
                WHERE (state = 'downloading' OR (state = 'paused' AND pausedByUser = 0)) AND id IS NOT ?
                """, arguments: [now, running])
            return db.changesCount
        }
    }

    /// Downloads paused automatically (not by the user) go back to the queue.
    func requeueAutoPausedDownloads(now: Date = Date()) async throws -> Int {
        try await writer.write { db in
            try db.execute(sql: "UPDATE download SET state = 'queued', updatedAt = ? WHERE state = 'paused' AND pausedByUser = 0",
                           arguments: [now])
            return db.changesCount
        }
    }

    /// At launch: completed downloads whose file has gone (moved or deleted in Finder) are marked failed, so the
    /// Downloads list shows them as such instead of offering to play a file that isn't there. Returns how many.
    func flagMissingDownloadFiles(now: Date = Date()) async throws -> Int {
        let completed = try await writer.read { db in
            try DownloadItem.fetchAll(db, sql: "SELECT * FROM download WHERE state = ?", arguments: [DownloadItem.State.completed])
        }
        let missing = Self.missingDownloadMessage
        var flagged = 0
        for item in completed {
            guard let path = item.filePath, !FileManager.default.fileExists(atPath: path) else { continue }
            let updated = try await updateDownload(id: item.id, now: now) { row in
                guard row.state == .completed, row.filePath == path else { return false }
                row.state = .failed
                row.error = missing
                return true
            }
            if updated != nil { flagged += 1 }
        }
        return flagged
    }

    /// True when a download other than `id` already uses `path` as its file.
    func downloadPathInUse(_ path: String, except id: String) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM download WHERE filePath = ? AND id != ? LIMIT 1", arguments: [path, id]) ?? false
        }
    }

    /// The saved file of a completed download that is still on disk. A completed download whose file has gone is
    /// marked failed ("File was moved or deleted"), so it shows up as such and can be downloaded again; if the file
    /// comes back (e.g. the downloads folder is on a drive that wasn't connected), it's completed again.
    func completedDownloadFile(mediaId: String) async -> URL? {
        guard let item = try? await download(id: mediaId), let path = item.filePath else { return nil }
        let missing = Self.missingDownloadMessage
        let exists = FileManager.default.fileExists(atPath: path)
        switch item.state {
        case .completed where exists:
            return URL(fileURLWithPath: path)
        case .completed:
            _ = try? await updateDownload(id: mediaId) { item in
                guard item.state == .completed, item.filePath == path else { return false }
                item.state = .failed
                item.error = missing
                return true
            }
            return nil
        case .failed where exists && item.error == missing:
            let restored = try? await updateDownload(id: mediaId) { item in
                item.filePath == path && item.restoreIfFileReturned()
            }
            return restored == nil ? nil : URL(fileURLWithPath: path)
        default:
            return nil
        }
    }
}
