import Foundation

/// Reading and writing device files in the sync folder (a folder in iCloud Drive, or any folder for tests), with
/// file coordination so iCloud never sees a half-written file.
public enum CloudSyncFolder {
    public struct Listing: Sendable {
        /// Other devices' files (one per device: the newest when iCloud kept conflict copies).
        public var files: [CloudSyncDeviceFile] = []
        /// This device's own file as last written, if present.
        public var own: CloudSyncDeviceFile?
        /// Files that were skipped, in words.
        public var notices: [String] = []
        /// Files iCloud hasn't downloaded yet (a download was requested; they're read on a later pass).
        public var pending = 0
    }

    public enum FolderError: LocalizedError {
        case missing
        case unreadable(String)
        case notWritten(String)

        public var errorDescription: String? {
            switch self {
            case .missing: "The sync folder isn't available. Choose it again in Settings → Sync."
            case .unreadable(let reason): "Couldn't read the sync folder: \(reason)"
            case .notWritten(let reason): "Couldn't save this device's sync file: \(reason)"
            }
        }
    }

    /// Larger files aren't sync files (a device file holds user state only, typically well under 1 MB).
    static let maxFileSize = 64 * 1024 * 1024

    public static func fileName(deviceId: String) -> String { "\(deviceId).json" }

    public static func read(_ folder: URL, ownDeviceId: String) throws(FolderError) -> Listing {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw .missing }
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey]
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw .unreadable(error.localizedDescription)
        }

        var listing = Listing()
        var byDevice: [String: CloudSyncDeviceFile] = [:]
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            // iCloud placeholder of a file not downloaded yet: ".<name>.json.icloud".
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let real = folder.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                try? fm.startDownloadingUbiquitousItem(at: real)
                listing.pending += 1
                continue
            }
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isUbiquitousItem == true {
                let status = values?.ubiquitousItemDownloadingStatus
                if status != .current { try? fm.startDownloadingUbiquitousItem(at: url) }
                if status == .notDownloaded {
                    listing.pending += 1
                    continue
                }
            }
            if let size = values?.fileSize, size > maxFileSize {
                listing.notices.append("Skipped \(name): too large to be a Tuner sync file.")
                continue
            }
            guard let data = coordinatedRead(url) else {
                listing.notices.append("Skipped \(name): couldn't be read.")
                continue
            }
            let file: CloudSyncDeviceFile
            do {
                file = try CloudSyncDeviceFile.decode(data)
            } catch .otherSchema(let schema) {
                listing.notices.append(schema > CloudSyncDeviceFile.currentSchema
                    ? "Skipped \(name): written by a newer version of Tuner. Update Tuner on this device."
                    : "Skipped \(name): written by an older version of Tuner.")
                continue
            } catch {
                listing.notices.append("Skipped \(name): damaged or incomplete (it may still be uploading).")
                continue
            }
            if file.deviceId == ownDeviceId {
                if listing.own.map({ $0.exportedAt < file.exportedAt }) ?? true { listing.own = file }
            } else if byDevice[file.deviceId].map({ $0.exportedAt < file.exportedAt }) ?? true {
                byDevice[file.deviceId] = file
            }
        }
        listing.files = byDevice.values.sorted { $0.deviceId < $1.deviceId }
        if listing.pending > 0 {
            listing.notices.append(listing.pending == 1 ? "Waiting for 1 file to download from iCloud."
                                                        : "Waiting for \(listing.pending) files to download from iCloud.")
        }
        return listing
    }

    /// Replaces this device's file atomically.
    public static func write(_ file: CloudSyncDeviceFile, to folder: URL) throws(FolderError) {
        let data: Data
        do {
            data = try file.encoded()
        } catch {
            throw .notWritten(error.localizedDescription)
        }
        let url = folder.appendingPathComponent(fileName(deviceId: file.deviceId))
        var coordinationError: NSError?
        var writeError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw .notWritten(error.localizedDescription) }
    }

    static func coordinatedRead(_ url: URL) -> Data? {
        var coordinationError: NSError?
        var data: Data?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { target in
            data = try? Data(contentsOf: target)
        }
        return coordinationError == nil ? data : nil
    }
}
