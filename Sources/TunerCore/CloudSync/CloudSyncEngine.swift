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
    /// Records in this device's file as last written or read, so unchanged state isn't rewritten (and re-uploaded).
    private var published: [CloudSyncRecord]?
    private var publishedFolder: URL?

    public init(db: AppDatabase, device: Device) {
        self.db = db
        self.device = device
    }

    public func setDeviceName(_ name: String) {
        guard name != device.name else { return }
        device.name = name
        published = nil
    }

    /// One pass: read the other devices' files, apply what's newer, publish this device's state.
    /// `preferences` are this device's whitelisted preferences (`CloudSyncPreferences.keys`) with local ids.
    public func sync(folder: URL, preferences: [String: SyncJSON], now: Date = Date()) async -> CloudSyncReport {
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
        report.peers = listing.files.map {
            CloudSyncPeer(id: $0.deviceId, name: $0.deviceName, platform: $0.platform, exportedAt: $0.exportedAt, recordCount: $0.records.count)
        }

        let ownPrefs = preferences.filter { CloudSyncPreferences.keys.contains($0.key) }
        let result: CloudSyncPassResult
        do {
            result = try await db.cloudSyncPass(remote: CloudSyncMerge.newest(listing.files), preferences: ownPrefs,
                                                deviceId: device.id, now: now)
        } catch {
            Self.log.error("Sync pass failed: \(error.localizedDescription, privacy: .public)")
            report.error = "Couldn't update the library: \(error.localizedDescription)"
            return report
        }
        report.preferences = result.preferences
        report.appliedCount = result.appliedCount
        report.readySourceIds = result.refreshSourceIds
        report.sourcesNeedingPassword = result.createdNeedingPassword

        if publishedFolder != folder {
            published = listing.own?.deviceName == device.name ? listing.own?.records : nil
            publishedFolder = folder
        }
        if listing.own == nil || published != result.records {
            let file = CloudSyncDeviceFile(deviceId: device.id, deviceName: device.name, platform: device.platform,
                                           appVersion: device.appVersion, exportedAt: now, records: result.records)
            do {
                try CloudSyncFolder.write(file, to: folder)
                published = result.records
                report.wroteFile = true
            } catch {
                Self.log.error("Sync file not written: \(error.localizedDescription, privacy: .public)")
                report.error = error.localizedDescription
            }
        }
        Self.log.info("Sync pass: \(listing.files.count) other devices, \(result.appliedCount) changes applied, \(result.preferences.count) preferences, \(result.records.count) records published\(report.wroteFile ? " (file written)" : "")")
        return report
    }
}
