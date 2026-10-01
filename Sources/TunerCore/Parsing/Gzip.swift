import CZlib
import Foundation

public enum GzipError: LocalizedError {
    case unreadable
    case writeFailed
    case corrupt

    public var errorDescription: String? {
        switch self {
        case .unreadable: "Could not read the compressed file"
        case .writeFailed: "Could not write the decompressed file"
        case .corrupt: "The compressed file is damaged or truncated"
        }
    }
}

/// gzip support via the system zlib (`gzread` handles multi-member files, which some EPG providers emit).
public enum Gzip {
    public static func isGzipped(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    public static func isGzipped(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isGzipped((try? handle.read(upToCount: 2)) ?? Data())
    }

    /// Streams `input` to `output` without holding the decompressed bytes in memory.
    public static func decompress(fileAt input: URL, to output: URL) throws {
        switch tuner_gunzip_file(input.path, output.path) {
        case 0: return
        case -1: throw GzipError.unreadable
        case -2: throw GzipError.writeFailed
        default: throw GzipError.corrupt
        }
    }

    public static func decompress(_ data: Data) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
        let input = tmp.appendingPathComponent("tuner-\(UUID().uuidString).gz")
        let output = tmp.appendingPathComponent("tuner-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try data.write(to: input)
        try decompress(fileAt: input, to: output)
        return try Data(contentsOf: output)
    }
}
