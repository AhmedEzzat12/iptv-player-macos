import Foundation

/// A key's current value in this device's data, as built for export.
public struct CloudSyncLocalValue: Sendable, Hashable {
    public var value: SyncJSON
    /// The record's own change time when it has one (watch progress, history, favourites); others are timestamped
    /// when an export first notices the change.
    public var ownStamp: Int64?

    public init(_ value: SyncJSON, ownStamp: Int64? = nil) {
        self.value = value
        self.ownStamp = ownStamp
    }
}

/// A record from another device's file.
public struct CloudSyncRemoteRecord: Sendable, Hashable {
    public var record: CloudSyncRecord
    public var deviceId: String

    public init(_ record: CloudSyncRecord, deviceId: String) {
        self.record = record
        self.deviceId = deviceId
    }
}

/// Snapshot diff and last-writer-wins merge, kept free of I/O so they can be tested on their own.
public enum CloudSyncMerge {
    /// Deletions are remembered (and published) this long, so devices that were away can still catch up.
    public static let tombstoneLifetime: Int64 = 60 * 24 * 3600 * 1000
    /// Timestamp of values found on the very first sync of a device: older than anything, so what the other devices
    /// already agreed on wins over this device's defaults. Restamped to "now" if nothing replaces them.
    public static let provisionalStamp: Int64 = 0

    /// The ledger after noticing local changes: new or changed values get `now` (or their own newer change time),
    /// values that disappeared become deletions. `frozen` keys keep their ledger entry as is (playlists waiting for a
    /// password). Keys for which `isLocal` is false (their playlist isn't on this device any more) are dropped without
    /// a deletion, so removing a playlist here doesn't remove anything on the other devices.
    public static func diff(
        snapshot: [String: CloudSyncLocalValue],
        ledger: [String: CloudSyncLedgerEntry],
        frozen: Set<String> = [],
        isLocal: (String) -> Bool = { _ in true },
        firstSync: Bool,
        now: Int64
    ) -> [String: CloudSyncLedgerEntry] {
        var out: [String: CloudSyncLedgerEntry] = [:]
        out.reserveCapacity(max(snapshot.count, ledger.count))
        for (key, local) in snapshot where !frozen.contains(key) {
            let hash = local.value.contentHash
            let previous = ledger[key]
            if let previous, !previous.deleted, previous.localHash == hash {
                out[key] = previous
                continue
            }
            let stamp: Int64
            if let own = local.ownStamp, own > (previous?.updatedAt ?? Int64.min) {
                stamp = own
            } else if firstSync && previous == nil {
                stamp = provisionalStamp
            } else {
                stamp = max(now, (previous?.updatedAt ?? 0) + 1)
            }
            out[key] = CloudSyncLedgerEntry(key: key, value: local.value, localHash: hash, updatedAt: stamp, deleted: false)
        }
        for (key, entry) in ledger where snapshot[key] == nil {
            if frozen.contains(key) {
                out[key] = entry
                continue
            }
            guard isLocal(key) else { continue }
            switch CloudSyncKey.kind(of: key) {
            case .pref:
                out[key] = entry
            case .source:
                // Kept for good: without it, another device's copy would bring a deleted playlist back.
                out[key] = entry.deleted ? entry
                    : CloudSyncLedgerEntry(key: key, value: nil, localHash: "", updatedAt: max(now, entry.updatedAt + 1), deleted: true)
            default:
                if entry.deleted {
                    if now - entry.updatedAt < tombstoneLifetime { out[key] = entry }
                } else {
                    out[key] = CloudSyncLedgerEntry(key: key, value: nil, localHash: "", updatedAt: max(now, entry.updatedAt + 1), deleted: true)
                }
            }
        }
        return out
    }

    /// The newest record per key across other devices' files (ties: the larger device id).
    public static func newest(_ files: [CloudSyncDeviceFile]) -> [String: CloudSyncRemoteRecord] {
        var out: [String: CloudSyncRemoteRecord] = [:]
        for file in files {
            for record in file.records {
                if let current = out[record.key], !wins(record.updatedAt, file.deviceId, over: current.record.updatedAt, current.deviceId) { continue }
                out[record.key] = CloudSyncRemoteRecord(record, deviceId: file.deviceId)
            }
        }
        return out
    }

    /// Remote records that replace this device's state: newer than what it has (ties broken by device id) and
    /// different from it. A deletion of something this device never had is ignored, and a deleted playlist is never
    /// deleted elsewhere.
    public static func decide(
        local: [String: CloudSyncLedgerEntry],
        remote: [String: CloudSyncRemoteRecord],
        localDeviceId: String
    ) -> [String: CloudSyncRemoteRecord] {
        var out: [String: CloudSyncRemoteRecord] = [:]
        for (key, r) in remote {
            if r.record.deleted && CloudSyncKey.kind(of: key) == .source { continue }
            if let l = local[key] {
                guard wins(r.record.updatedAt, r.deviceId, over: l.updatedAt, localDeviceId) else { continue }
                if l.deleted == r.record.deleted && l.valueHash == r.record.valueHash { continue }
            } else if r.record.deleted {
                continue
            }
            out[key] = r
        }
        return out
    }

    static func wins(_ stamp: Int64, _ device: String, over otherStamp: Int64, _ otherDevice: String) -> Bool {
        stamp > otherStamp || (stamp == otherStamp && device > otherDevice)
    }
}
