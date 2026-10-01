import Foundation

/// Writes channels back out as an extended M3U (with renames, hidden channels removed).
public enum M3UExporter {
    public static func export(_ channels: [Channel], categoryNames: [String: String], resolveURL: (Channel) -> String?) -> String {
        var out = "#EXTM3U\n"
        for ch in channels {
            guard let url = resolveURL(ch) else { continue }
            var attrs: [String] = []
            if let tvg = ch.tvgId { attrs.append("tvg-id=\"\(escape(tvg))\"") }
            attrs.append("tvg-name=\"\(escape(ch.displayName))\"")
            if let logo = ch.logoURL { attrs.append("tvg-logo=\"\(escape(logo))\"") }
            if let n = ch.number { attrs.append("tvg-chno=\"\(n)\"") }
            if let cat = ch.categoryId.flatMap({ categoryNames[$0] }) { attrs.append("group-title=\"\(escape(cat))\"") }
            out += "#EXTINF:-1 \(attrs.joined(separator: " ")),\(ch.displayName)\n"
            if let ua = ch.userAgent { out += "#EXTVLCOPT:http-user-agent=\(ua)\n" }
            if let ref = ch.referrer { out += "#EXTVLCOPT:http-referrer=\(ref)\n" }
            out += url + "\n"
        }
        return out
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
}
