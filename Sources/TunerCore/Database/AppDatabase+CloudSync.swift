import Foundation
import GRDB

/// What one sync pass changed and what this device publishes afterwards.
public struct CloudSyncPassResult: Sendable {
    /// Every record this device publishes, sorted by key.
    public var records: [CloudSyncRecord] = []
    /// Preferences other devices changed (local ids), for the app to apply.
    public var preferences: [String: SyncJSON] = [:]
    /// Database rows written or deleted by the import (playlists included).
    public var appliedCount = 0
    /// Playlists added or changed by the import that should be refreshed from their provider.
    public var refreshSourceIds: [String] = []
    /// Playlists added by the import that wait for their password.
    public var createdNeedingPassword = 0
}

/// iCloud sync: building this device's state, applying other devices' records, and the ledger (see `CloudSyncMerge`).
extension AppDatabase {
    /// One sync pass in a single write transaction: notice local changes, apply newer remote records (playlists
    /// first, so records of a playlist that just arrived apply in the same pass), update the ledger.
    /// `preferences` are this device's whitelisted preferences with local ids.
    public func cloudSyncPass(
        remote: [String: CloudSyncRemoteRecord],
        preferences: [String: SyncJSON],
        deviceId: String,
        now: Date = Date()
    ) async throws -> CloudSyncPassResult {
        try await writer.write { db in
            try Self.cloudSyncPass(db, remote: remote, preferences: preferences, deviceId: deviceId, now: now.syncMillis)
        }
    }

    /// The ledger (what this device publishes), by key.
    public func cloudSyncLedger() async throws -> [String: CloudSyncLedgerEntry] {
        try await writer.read { db in try Self.fetchLedger(db) }
    }

    /// Forgets what was published (sync turned off and on with another folder, or tests). Local data is untouched;
    /// the next pass treats it like a first sync.
    public func resetCloudSyncLedger() async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM syncLedger") }
    }

    static func cloudSyncPass(
        _ db: Database,
        remote: [String: CloudSyncRemoteRecord],
        preferences: [String: SyncJSON],
        deviceId: String,
        now: Int64
    ) throws -> CloudSyncPassResult {
        var result = CloudSyncPassResult()
        let original = try fetchLedger(db)
        var ledger = original
        let firstSync = original.isEmpty

        // 1. Playlists.
        var sources = try Source.fetchAll(db)
        var map = CloudSyncSourceMap(sources: sources)
        let sourceSnapshot = Self.sourceSnapshot(sources, map: map)
        let sourceState = CloudSyncMerge.diff(
            snapshot: sourceSnapshot.entries, ledger: ledger.filter { CloudSyncKey.kind(of: $0.key) == .source },
            frozen: sourceSnapshot.frozen, firstSync: firstSync, now: now)
        let sourceDecisions = CloudSyncMerge.decide(
            local: sourceState, remote: remote.filter { CloudSyncKey.kind(of: $0.key) == .source }, localDeviceId: deviceId)
        if !sourceDecisions.isEmpty {
            for (key, r) in sourceDecisions.sorted(by: { $0.key < $1.key }) {
                let fp = CloudSyncKey.rest(of: key)
                let existing = map.sourceIdByFingerprint[fp].flatMap { id in sources.first { $0.id == id } }
                guard let outcome = try applySource(db, record: r.record, fingerprint: fp, existing: existing, now: now) else { continue }
                result.appliedCount += 1
                if outcome.refresh { result.refreshSourceIds.append(outcome.id) }
                if outcome.createdNeedingPassword { result.createdNeedingPassword += 1 }
            }
            sources = try Source.fetchAll(db)
            map = CloudSyncSourceMap(sources: sources)
            let after = Self.sourceSnapshot(sources, map: map)
            for (key, r) in sourceDecisions where after.entries[key] != nil || after.frozen.contains(key) {
                ledger[key] = CloudSyncLedgerEntry(key: key, value: r.record.value, localHash: after.entries[key]?.value.contentHash ?? "",
                                                   updatedAt: r.record.updatedAt, deleted: false)
            }
        }

        // 2. Everything else.
        let isLocal: (String) -> Bool = { key in CloudSyncKey.fingerprint(of: key).map(map.hasFingerprint) ?? true }
        let snapshot = try Self.snapshot(db, sources: sources, map: map, preferences: preferences, ledger: ledger)
        var state = CloudSyncMerge.diff(snapshot: snapshot.entries, ledger: ledger, frozen: snapshot.frozen,
                                        isLocal: isLocal, firstSync: firstSync, now: now)
        let usable = remote.filter { key, _ in
            guard let kind = CloudSyncKey.kind(of: key), kind != .source else { return false }
            if kind == .pref && !CloudSyncPreferences.keys.contains(CloudSyncKey.rest(of: key)) { return false }
            return isLocal(key)
        }
        let decisions = CloudSyncMerge.decide(local: state, remote: usable, localDeviceId: deviceId)
        if !decisions.isEmpty {
            let applied = try applyRecords(db, decisions, map: map)
            result.appliedCount += applied.count
            result.preferences = applied.preferences
            var prefsAfter = preferences
            prefsAfter.merge(applied.preferences) { _, new in new }
            var ledgerAfter = ledger
            for (key, r) in decisions where CloudSyncKey.kind(of: key) == .pref {
                ledgerAfter[key] = CloudSyncLedgerEntry(key: key, value: r.record.value, localHash: "", updatedAt: r.record.updatedAt, deleted: r.record.deleted)
            }
            let after = try Self.snapshot(db, sources: sources, map: map, preferences: prefsAfter, ledger: ledgerAfter)
            for (key, r) in decisions {
                if r.record.deleted {
                    if after.entries[key] == nil {
                        state[key] = CloudSyncLedgerEntry(key: key, value: nil, localHash: "", updatedAt: r.record.updatedAt, deleted: true)
                    }
                } else if let local = after.entries[key] {
                    state[key] = CloudSyncLedgerEntry(key: key, value: r.record.value, localHash: local.value.contentHash,
                                                      updatedAt: r.record.updatedAt, deleted: false)
                }
                // Otherwise it couldn't be applied (e.g. a group member whose group is gone): retried next time.
            }
        }

        // Values found on a first sync that nothing replaced are this device's own: timestamp them now.
        for (key, entry) in state where entry.updatedAt == CloudSyncMerge.provisionalStamp {
            state[key]?.updatedAt = now
        }

        try writeLedger(db, from: original, to: state)
        result.records = state.values.map(\.record).sorted { $0.key < $1.key }
        return result
    }

    // MARK: - Snapshot

    struct CloudSyncSnapshot {
        var entries: [String: CloudSyncLocalValue] = [:]
        /// Keys whose ledger entry is published unchanged (playlists waiting for their password).
        var frozen: Set<String> = []
    }

    static func sourceSnapshot(_ sources: [Source], map: CloudSyncSourceMap) -> CloudSyncSnapshot {
        var snap = CloudSyncSnapshot()
        for source in sources {
            guard let fp = map.fingerprintBySourceId[source.id] else { continue }
            let key = CloudSyncKey.make(.source, fp)
            if source.needsPassword {
                snap.frozen.insert(key)
            } else {
                snap.entries[key] = CloudSyncLocalValue(syncValue(of: source))
            }
        }
        return snap
    }

    /// This device's state as sync records (local ids translated; items of playlists that don't sync left out).
    static func snapshot(
        _ db: Database,
        sources: [Source],
        map: CloudSyncSourceMap,
        preferences: [String: SyncJSON],
        ledger: [String: CloudSyncLedgerEntry]
    ) throws -> CloudSyncSnapshot {
        var snap = sourceSnapshot(sources, map: map)
        func put(_ kind: CloudSyncKind, _ rest: String, _ value: SyncJSON, ownStamp: Int64? = nil) {
            snap.entries[CloudSyncKey.make(kind, rest)] = CloudSyncLocalValue(value, ownStamp: ownStamp)
        }

        for p in try WatchProgress.fetchAll(db) {
            guard let id = map.syncId(p.mediaId) else { continue }
            put(.progress, id, .object([
                "kind": .string(p.kind.rawValue),
                "seriesId": SyncJSON(p.seriesId.flatMap(map.syncId)),
                "title": .string(p.title),
                "subtitle": SyncJSON(p.subtitle),
                "posterURL": SyncJSON(p.posterURL),
                "position": .number(p.position),
                "duration": .number(p.duration),
                "completed": .bool(p.completed),
            ]), ownStamp: p.updatedAt.syncMillis)
        }

        for row in try Row.fetchAll(db, sql: "SELECT mediaId, kind, addedAt FROM vodFavorite") {
            guard let id = map.syncId(row["mediaId"]) else { continue }
            let added: Date = row["addedAt"]
            put(.vodFavorite, id, .object(["kind": .string(row["kind"]), "addedAt": SyncJSON(added.syncMillis)]),
                ownStamp: added.syncMillis)
        }

        for row in try Row.fetchAll(db, sql: "SELECT * FROM channelPref") {
            guard let id = map.syncId(row["channelId"]) else { continue }
            put(.channelPref, id, .object([
                "isFavorite": .bool(row["isFavorite"]),
                "favoriteOrder": SyncJSON(row["favoriteOrder"] as Int?),
                "isHidden": .bool(row["isHidden"]),
                "alias": SyncJSON(row["alias"] as String?),
                // An XMLTV channel id, not a playlist id: synced as is.
                "epgIdOverride": SyncJSON(row["epgIdOverride"] as String?),
            ]))
        }

        for row in try Row.fetchAll(db, sql: "SELECT * FROM categoryPref") {
            guard let id = map.syncId(row["categoryId"]) else { continue }
            put(.categoryPref, id, .object([
                "isHidden": .bool(row["isHidden"]),
                "alias": SyncJSON(row["alias"] as String?),
                "sortIndex": SyncJSON(row["sortIndex"] as Int?),
            ]))
        }

        for row in try Row.fetchAll(db, sql: "SELECT channelId, watchedAt FROM history") {
            guard let id = map.syncId(row["channelId"]) else { continue }
            let watched: Date = row["watchedAt"]
            put(.history, id, .object(["watchedAt": SyncJSON(watched.syncMillis)]), ownStamp: watched.syncMillis)
        }

        for group in try CustomGroup.fetchAll(db) {
            put(.group, group.id, .object(["name": .string(group.name), "sortIndex": SyncJSON(group.sortIndex)]))
        }
        for row in try Row.fetchAll(db, sql: "SELECT groupId, channelId, sortIndex FROM customGroupMember") {
            guard let id = map.syncId(row["channelId"]) else { continue }
            put(.groupMember, (row["groupId"] as String) + "/" + id, .object(["sortIndex": SyncJSON(row["sortIndex"] as Int?)]))
        }

        for name in CloudSyncPreferences.keys {
            guard let value = preferences[name] else { continue }
            let key = CloudSyncKey.make(.pref, name)
            if CloudSyncPreferences.idListKeys.contains(name) {
                put(.pref, name, publishedIdList(value, previous: ledger[key]?.value, map: map))
            } else {
                put(.pref, name, value)
            }
        }
        return snap
    }

    /// A list of local item ids as synced ids, followed by ids from the previously published list whose playlist
    /// isn't on this device (so a change here doesn't drop another device's entries).
    static func publishedIdList(_ local: SyncJSON, previous: SyncJSON?, map: CloudSyncSourceMap) -> SyncJSON {
        var list = (local.strings ?? []).compactMap(map.syncId)
        for id in previous?.strings ?? [] {
            guard let fp = CloudSyncSourceMap.fingerprint(ofSyncId: id), !map.hasFingerprint(fp), !list.contains(id) else { continue }
            list.append(id)
        }
        return SyncJSON(list)
    }

    /// A playlist's synced settings: no password, URLs without secrets (lists drop the URLs that have one).
    static func syncValue(of source: Source) -> SyncJSON {
        let main = SourceFingerprint.publicURL(source.url)
        let needsSecret = main.removedSecret || !(source.password ?? "").isEmpty
        let isPublic: (String) -> Bool = { !SourceFingerprint.containsSecret($0) }
        return .object([
            "name": .string(source.name),
            "kind": .string(source.kind.rawValue),
            "url": .string(main.url),
            "username": SyncJSON(source.username),
            "mac": SyncJSON(source.mac),
            "needsSecret": .bool(needsSecret),
            "epgURL": SyncJSON(source.epgURL.flatMap { isPublic($0) ? $0 : nil }),
            "autoLoadEPG": .bool(source.autoLoadEPG),
            "extraEPGURLs": SyncJSON(source.extraEPGURLs.filter(isPublic)),
            "epgTimeshiftHours": .number(source.epgTimeshiftHours),
            "userAgent": SyncJSON(source.userAgent),
            "backupURLs": SyncJSON(source.backupURLs.filter(isPublic)),
            "enabled": .bool(source.enabled),
            "includeLive": .bool(source.includeLive),
            "includeVOD": .bool(source.includeVOD),
            "refreshHours": SyncJSON(source.refreshHours),
            "sortIndex": SyncJSON(source.sortIndex),
        ])
    }

    // MARK: - Apply

    struct SourceOutcome {
        var id: String
        var refresh: Bool
        var createdNeedingPassword: Bool
    }

    /// Creates or updates the local copy of a synced playlist. Existing playlists keep their URL, credentials and
    /// any URLs with secrets; a new one starts without a password and stays off until it's entered (Xtream, or a
    /// link whose token was removed). Returns nil for a malformed record.
    static func applySource(_ db: Database, record: CloudSyncRecord, fingerprint: String, existing: Source?, now: Int64) throws -> SourceOutcome? {
        guard let v = record.value, let kind = v["kind"]?.string.flatMap(Source.Kind.init(rawValue:)),
              let url = v["url"]?.string, !url.isEmpty else { return nil }
        let username = v["username"]?.string
        let mac = v["mac"]?.string
        guard SourceFingerprint.of(kind: kind, url: url, username: username, mac: mac) == fingerprint else { return nil }
        let hasSecret = SourceFingerprint.containsSecret

        var source = existing ?? Source(name: url, kind: kind, url: url, username: username, mac: mac, createdAt: Date(syncMillis: now))
        let before = source
        if let name = v["name"]?.string, !name.isEmpty { source.name = name }
        if !(source.epgURL.map(hasSecret) ?? false) { source.epgURL = v["epgURL"]?.string }
        source.extraEPGURLs = (v["extraEPGURLs"]?.strings ?? []) + source.extraEPGURLs.filter(hasSecret)
        source.backupURLs = (v["backupURLs"]?.strings ?? []) + source.backupURLs.filter(hasSecret)
        source.autoLoadEPG = v["autoLoadEPG"]?.bool ?? source.autoLoadEPG
        source.epgTimeshiftHours = v["epgTimeshiftHours"]?.double ?? source.epgTimeshiftHours
        source.userAgent = v["userAgent"]?.string
        source.includeLive = v["includeLive"]?.bool ?? source.includeLive
        source.includeVOD = v["includeVOD"]?.bool ?? source.includeVOD
        source.refreshHours = v["refreshHours"]?.int
        source.sortIndex = v["sortIndex"]?.int ?? source.sortIndex
        let enabled = v["enabled"]?.bool ?? true

        if existing == nil {
            source.needsPassword = v["needsSecret"]?.bool ?? true
            source.enabled = enabled && !source.needsPassword
            try source.insert(db)
            return SourceOutcome(id: source.id, refresh: source.enabled, createdNeedingPassword: source.needsPassword)
        }
        if !source.needsPassword { source.enabled = enabled }
        guard source != before else { return nil }
        try source.update(db)
        let refresh = source.enabled && (!before.enabled || before.includeLive != source.includeLive || before.includeVOD != source.includeVOD
            || before.epgURL != source.epgURL || before.extraEPGURLs != source.extraEPGURLs
            || before.epgTimeshiftHours != source.epgTimeshiftHours || before.autoLoadEPG != source.autoLoadEPG)
        return SourceOutcome(id: source.id, refresh: refresh, createdNeedingPassword: false)
    }

    /// Writes other devices' records into the user-state tables; preferences are returned (with local ids) instead.
    static func applyRecords(_ db: Database, _ decisions: [String: CloudSyncRemoteRecord], map: CloudSyncSourceMap) throws
        -> (count: Int, preferences: [String: SyncJSON])
    {
        var count = 0
        var preferences: [String: SyncJSON] = [:]
        // Groups before their members.
        let order: (CloudSyncKind?) -> Int = { $0 == .group ? 0 : $0 == .groupMember ? 2 : 1 }
        let sorted = decisions.values.sorted {
            (order(CloudSyncKey.kind(of: $0.record.key)), $0.record.key) < (order(CloudSyncKey.kind(of: $1.record.key)), $1.record.key)
        }
        for r in sorted {
            let record = r.record
            let key = record.key
            let rest = CloudSyncKey.rest(of: key)
            let v = record.value ?? .null
            switch CloudSyncKey.kind(of: key) {
            case .progress:
                guard let id = map.localId(rest), let sourceId = map.sourceId(ofLocalId: id) else { continue }
                if record.deleted {
                    try db.execute(sql: "DELETE FROM watchProgress WHERE mediaId = ?", arguments: [id])
                } else {
                    guard let position = v["position"]?.double, let duration = v["duration"]?.double else { continue }
                    let progress = WatchProgress(
                        mediaId: id, kind: v["kind"]?.string.flatMap(MediaKind.init(rawValue:)) ?? .movie, sourceId: sourceId,
                        seriesId: v["seriesId"]?.string.flatMap(map.localId), title: v["title"]?.string ?? "",
                        subtitle: v["subtitle"]?.string, posterURL: v["posterURL"]?.string, position: position, duration: duration,
                        completed: v["completed"]?.bool ?? false, updatedAt: Date(syncMillis: record.updatedAt))
                    try progress.save(db)
                }
            case .vodFavorite:
                guard let id = map.localId(rest) else { continue }
                if record.deleted {
                    try db.execute(sql: "DELETE FROM vodFavorite WHERE mediaId = ?", arguments: [id])
                } else {
                    let added = v["addedAt"]?.int64.map(Date.init(syncMillis:)) ?? Date(syncMillis: record.updatedAt)
                    try db.execute(sql: "INSERT OR REPLACE INTO vodFavorite (mediaId, kind, addedAt) VALUES (?, ?, ?)",
                                   arguments: [id, v["kind"]?.string ?? MediaKind.movie.rawValue, added])
                }
            case .channelPref:
                guard let id = map.localId(rest) else { continue }
                if record.deleted {
                    try db.execute(sql: "DELETE FROM channelPref WHERE channelId = ?", arguments: [id])
                } else {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO channelPref (channelId, isFavorite, favoriteOrder, isHidden, alias, epgIdOverride)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [id, v["isFavorite"]?.bool ?? false, v["favoriteOrder"]?.int, v["isHidden"]?.bool ?? false,
                                         v["alias"]?.string, v["epgIdOverride"]?.string])
                }
            case .categoryPref:
                guard let id = map.localId(rest) else { continue }
                if record.deleted {
                    try db.execute(sql: "DELETE FROM categoryPref WHERE categoryId = ?", arguments: [id])
                } else {
                    try db.execute(sql: "INSERT OR REPLACE INTO categoryPref (categoryId, isHidden, alias, sortIndex) VALUES (?, ?, ?, ?)",
                                   arguments: [id, v["isHidden"]?.bool ?? false, v["alias"]?.string, v["sortIndex"]?.int])
                }
            case .history:
                guard let id = map.localId(rest) else { continue }
                if record.deleted {
                    try db.execute(sql: "DELETE FROM history WHERE channelId = ?", arguments: [id])
                } else {
                    let watched = v["watchedAt"]?.int64 ?? record.updatedAt
                    try db.execute(sql: "INSERT OR REPLACE INTO history (channelId, watchedAt) VALUES (?, ?)",
                                   arguments: [id, Date(syncMillis: watched)])
                }
            case .group:
                if record.deleted {
                    try db.execute(sql: "DELETE FROM customGroup WHERE id = ?", arguments: [rest])
                } else {
                    guard let name = v["name"]?.string else { continue }
                    // Not INSERT OR REPLACE: replacing the row would cascade-delete the group's channels.
                    try db.execute(sql: """
                        INSERT INTO customGroup (id, name, sortIndex) VALUES (?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, sortIndex = excluded.sortIndex
                        """, arguments: [rest, name, v["sortIndex"]?.int ?? 0])
                }
            case .groupMember:
                guard let slash = rest.firstIndex(of: "/"), let id = map.localId(String(rest[rest.index(after: slash)...])) else { continue }
                let groupId = String(rest[..<slash])
                if record.deleted {
                    try db.execute(sql: "DELETE FROM customGroupMember WHERE groupId = ? AND channelId = ?", arguments: [groupId, id])
                } else {
                    guard try Bool.fetchOne(db, sql: "SELECT 1 FROM customGroup WHERE id = ?", arguments: [groupId]) == true else { continue }
                    try db.execute(sql: "INSERT OR REPLACE INTO customGroupMember (groupId, channelId, sortIndex) VALUES (?, ?, ?)",
                                   arguments: [groupId, id, v["sortIndex"]?.int ?? 0])
                }
            case .pref:
                guard !record.deleted else { continue }
                if CloudSyncPreferences.idListKeys.contains(rest) {
                    preferences[rest] = SyncJSON((v.strings ?? []).compactMap(map.localId))
                } else {
                    preferences[rest] = v
                }
                continue
            case .source, nil:
                continue
            }
            count += 1
        }
        return (count, preferences)
    }

    // MARK: - Ledger

    static func fetchLedger(_ db: Database) throws -> [String: CloudSyncLedgerEntry] {
        let decoder = JSONDecoder()
        var out: [String: CloudSyncLedgerEntry] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, value, localHash, updatedAt, deleted FROM syncLedger") {
            let key: String = row["key"]
            let json: String? = row["value"]
            let value = json.flatMap { try? decoder.decode(SyncJSON.self, from: Data($0.utf8)) }
            out[key] = CloudSyncLedgerEntry(key: key, value: value, localHash: row["localHash"], updatedAt: row["updatedAt"], deleted: row["deleted"])
        }
        return out
    }

    /// Writes only what changed between two ledgers.
    static func writeLedger(_ db: Database, from old: [String: CloudSyncLedgerEntry], to new: [String: CloudSyncLedgerEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for key in old.keys where new[key] == nil {
            try db.execute(sql: "DELETE FROM syncLedger WHERE key = ?", arguments: [key])
        }
        for (key, entry) in new where old[key] != entry {
            let json = try entry.value.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            try db.execute(sql: "INSERT OR REPLACE INTO syncLedger (key, value, localHash, updatedAt, deleted) VALUES (?, ?, ?, ?, ?)",
                           arguments: [key, json, entry.localHash, entry.updatedAt, entry.deleted])
        }
    }
}
