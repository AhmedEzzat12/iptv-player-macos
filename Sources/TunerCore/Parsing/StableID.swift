import Foundation

/// Deterministic identifiers so favourites, hidden flags and EPG overrides survive resyncs.
public enum StableID {
    /// DJB2 hash (wrapping Int32, absolute value, base-36, max 8 chars) — same scheme as ynotv.
    public static func hash(_ string: String) -> String {
        var h: Int32 = 5381
        for byte in string.utf8 {
            h = h &* 33 &+ Int32(byte)
        }
        let magnitude = h == Int32.min ? UInt32(Int32.max) + 1 : UInt32(abs(h))
        return String(String(magnitude, radix: 36).prefix(8))
    }

    /// Replaces anything outside `[A-Za-z0-9._-]` with `_`.
    public static func sanitize(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-":
                out.unicodeScalars.append(scalar)
            default:
                out.append("_")
            }
        }
        return out
    }

    /// Lowercased slug keeping Unicode letters/digits, runs of other characters collapsed to `-`.
    public static func slug(_ string: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in string.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "category-\(hash(string))" : out
    }
}

/// Builds unique channel ids for one M3U source during a parse.
struct M3UChannelIDAllocator {
    let sourceId: String
    private var used: Set<String> = []

    init(sourceId: String) {
        self.sourceId = sourceId
    }

    mutating func allocate(tvgId: String?, url: String) -> String {
        let base: String
        if let tvg = tvgId?.nilIfEmpty {
            let primary = "\(sourceId)_\(StableID.sanitize(tvg))"
            if used.insert(primary).inserted { return primary }
            base = "\(primary)_\(StableID.hash(url))"
        } else {
            base = "\(sourceId)_url_\(StableID.hash(url))"
        }
        if used.insert(base).inserted { return base }
        var n = 2
        while !used.insert("\(base)_\(n)").inserted { n += 1 }
        return "\(base)_\(n)"
    }
}
