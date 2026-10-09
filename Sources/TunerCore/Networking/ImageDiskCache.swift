import CryptoKit
import Foundation

/// Artwork bytes on disk, one file per URL, whatever caching headers the server sent (IPTV panels often send
/// none, so `URLCache` would fetch the same poster again and again). Size-capped: when the folder grows past
/// `limitBytes`, the least recently used files go until it's at 80 %. Reading a file counts as using it.
public actor ImageDiskCache {
    private let directory: URL
    private let limitBytes: Int64
    /// Writes since the last trim; the folder is measured every `trimInterval` writes, not on each one.
    private var writesSinceTrim = 0
    private let trimInterval: Int

    public init(directory: URL, limitBytes: Int64, trimInterval: Int = 100) {
        self.directory = directory
        self.limitBytes = limitBytes
        self.trimInterval = trimInterval
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The cached bytes for `url`, if any.
    public func data(for url: URL) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // Marks it recently used for the trim.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    public func store(_ data: Data, for url: URL) {
        try? data.write(to: fileURL(for: url), options: .atomic)
        writesSinceTrim += 1
        if writesSinceTrim >= trimInterval { trim() }
    }

    /// Removes the least recently used files until the folder is under 80 % of the limit.
    public func trim() {
        writesSinceTrim = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        var entries: [(url: URL, size: Int64, used: Date)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limitBytes else { return }
        entries.sort { $0.used < $1.used }
        let target = limitBytes * 8 / 10
        for entry in entries where total > target {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writesSinceTrim = 0
    }

    /// Total size of the cached files.
    public func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// SHA-256 of the URL: fixed-length, file-system-safe, and no credentials from a URL end up in a file name.
    nonisolated func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
