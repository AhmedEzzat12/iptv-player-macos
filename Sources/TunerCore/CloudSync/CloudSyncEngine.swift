import CryptoKit
import Foundation
import os

/// iCloud Drive sync through a plain folder (no CloudKit: the apps have no iCloud entitlement). Each device writes
/// only its own `<deviceId>.json` with its user state and reads the others', so there are no write conflicts; per
/// key, the newest change wins. One pass at a time, off the main actor.
public actor CloudSyncEngine {
    public struct Device: Sendable, Hashable {
        public var id: String
        public var name: String
        /// "macOS" or "iOS".
        public var platform: String
        public var appVersion: String?

        public init(id: String, name: String, platform: String, appVersion: String?) {
            self.id = id
            self.name = name
            self.platform = platform
            self.appVersion = appVersion
        }
    }

    static let log = Logger(subsystem: "app.tuner.macos", category: "Sync")

    public let db: AppDatabase
    public private(set) var device: Device
    /// Seals playlist passwords for the other devices and opens the ones sealed for this one (`CloudSyncSecrets`).
    private let key: CloudSyncSecrets.PrivateKey
    /// Records in this device's file as last written or read, so unchanged state isn't rewritten (and re-uploaded).
    private var published: [CloudSyncRecord]?
    private var publishedRemoved: [String: Int64]?
    private var publishedRecipients: [String: String]?
    private var publishedFolder: URL?

    public init(db: AppDatabase, device: Device, key: CloudSyncSecrets.PrivateKey = .init()) {
        self.db = db
        self.device = device
        self.key = key
    }

    public func setDeviceName(_ name: String) {
        guard name != device.name else { return }
        device.name = name
        published = nil
    }

    /// A new identity (this device was removed from sync and joins again as a new device).
    public func setDeviceId(_ id: String) {
        guard id != device.id else { return }
        device.id = id
        published = nil
        publishedFolder = nil
    }

    /// One pass: read the other devices' files, apply what's newer, publish this device's state.
    /// `preferences` are this device's whitelisted preferences (`CloudSyncPreferences.keys`) with local ids.
    /// `includeSecrets` publishes playlists with their passwords (and links with tokens).
    /// `trustedKeys` are the devices the user allowed to receive passwords, with the key they had then (device id →
    /// base64 public key): passwords are sealed only for those, and only while their key is unchanged.
    /// `removedDevices` are the devices this device knows were removed from sync (id → sync milliseconds); their files
    /// are deleted and ignored, and when this device's own id is among the removed (here or in any file) the pass
    /// stops and reports `removedThisDevice`.
    public func sync(folder: URL, preferences: [String: SyncJSON], includeSecrets: Bool = false,
                     trustedKeys: [String: String] = [:], removedDevices: [String: Int64] = [:],
                     now: Date = Date()) async -> CloudSyncReport {
        var report = CloudSyncReport(finishedAt: now)
        let listing: CloudSyncFolder.Listing
        do {
            listing = try CloudSyncFolder.read(folder, ownDeviceId: device.id)
        } catch {
            Self.log.error("Sync folder unavailable: \(error.localizedDescription, privacy: .public)")
            report.error = error.localizedDescription
            return report
        }
        report.notices = listing.notices

        var removed = removedDevices
        for file in listing.files + [listing.own].compactMap({ $0 }) {
            removed.merge(file.removedDevices ?? [:]) { max($0, $1) }
        }
        report.removedDevices = removed
        if removed[device.id] != nil {
            Self.log.info("This device was removed from sync on another device")
            report.removedThisDevice = true
            return report
        }
        var files = listing.files.map { CloudSyncSecrets.open($0, reader: device.id, key: key) }
        for file in files where removed[file.deviceId] != nil {
            CloudSyncFolder.delete(deviceId: file.deviceId, in: folder)
        }
        files.removeAll { removed[$0.deviceId] != nil }

        report.peers = files.map {
            CloudSyncPeer(id: $0.deviceId, name: $0.deviceName, platform: $0.platform, exportedAt: $0.exportedAt,
                          recordCount: $0.records.count, appVersion: $0.appVersion, publicKey: $0.publicKey)
        }

        let ownPrefs = preferences.filter { CloudSyncPreferences.keys.contains($0.key) }
        let result: CloudSyncPassResult
        do {
            result = try await db.cloudSyncPass(remote: CloudSyncMerge.newest(files), preferences: ownPrefs,
                                                deviceId: device.id, includeSecrets: includeSecrets, now: now)
        } catch is CancellationError {
            // A newer pass took over (a change or Sync Now while this one ran): nothing went wrong.
            report.cancelled = true
            return report
        } catch {
            Self.log.error("Sync pass failed: \(error.localizedDescription, privacy: .public)")
            report.error = "Couldn't update the library: \(error.localizedDescription)"
            return report
        }
        report.preferences = result.preferences
        report.appliedCount = result.appliedCount
        report.readySourceIds = result.refreshSourceIds
        report.sourcesNeedingPassword = result.createdNeedingPassword

        // Passwords are sealed only for devices the user allowed, while they still have the key they had then: anyone
        // who can write to the folder could add a device file, so a new or changed key gets nothing.
        var recipients: [String: CloudSyncSecrets.PublicKey] = [:]
        for file in files {
            guard let text = file.publicKey, trustedKeys[file.deviceId] == text,
                  let publicKey = CloudSyncSecrets.publicKey(text) else { continue }
            recipients[file.deviceId] = publicKey
        }
        let recipientKeys = recipients.mapValues { $0.rawRepresentation.base64EncodedString() }
        let ownKey = CloudSyncSecrets.publicKeyString(key)

        if publishedFolder != folder {
            let own = listing.own.map { CloudSyncSecrets.open($0, reader: device.id, key: key) }
            published = own?.deviceName == device.name && own?.publicKey == ownKey ? own?.records : nil
            publishedRemoved = listing.own?.removedDevices ?? [:]
            publishedRecipients = nil
            publishedFolder = folder
        }
        let hasSecrets = result.records.contains { $0.value?[CloudSyncSecrets.plainField] != nil }
        let recipientsChanged = hasSecrets && publishedRecipients != recipientKeys
        if listing.own == nil || published != result.records || publishedRemoved != removed || recipientsChanged {
            let sealed = CloudSyncSecrets.seal(result.records, writer: device.id, key: key, recipients: recipients)
            let file = CloudSyncDeviceFile(deviceId: device.id, deviceName: device.name, platform: device.platform,
                                           appVersion: device.appVersion, exportedAt: now, records: sealed,
                                           removedDevices: removed, publicKey: ownKey)
            do {
                try CloudSyncFolder.write(file, to: folder)
                published = result.records
                publishedRemoved = removed
                publishedRecipients = recipientKeys
                report.wroteFile = true
            } catch {
                Self.log.error("Sync file not written: \(error.localizedDescription, privacy: .public)")
                report.error = error.localizedDescription
            }
        }
        Self.log.info("Sync pass: \(files.count) other devices, \(result.appliedCount) changes applied, \(result.preferences.count) preferences, \(result.records.count) records published\(report.wroteFile ? " (file written)" : "")")
        return report
    }
}
