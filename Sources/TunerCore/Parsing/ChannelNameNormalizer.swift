import Foundation

/// Normalises channel names so a playlist entry like "US| CNN HD ᴴᴰ" can be matched to
/// an XMLTV `<display-name>` such as "CNN", and duplicate channels across sources can be grouped.
public enum ChannelNameNormalizer {
    /// Quality/packaging tokens that never distinguish one channel from another.
    /// Deliberately NOT included: "plus" (Canal+ ≠ Canal), "east"/"west" (different schedules),
    /// "live" (often part of a distinct channel name).
    static let noiseTokens: Set<String> = [
        "hd", "fhd", "uhd", "qhd", "sd", "4k", "8k", "hevc", "h265", "h264", "x265", "x264", "1080p", "1080i",
        "1080", "720p", "720", "576p", "2160p", "50fps", "60fps", "fps", "hdr", "raw", "backup", "vip", "tv",
        "ᴴᴰ", "ᵁᴴᴰ", "ʰᵈ", "multi", "multiaudio", "audio",
    ]

    /// Common country prefixes like `US:`, `UK |`, `[CA]`, `|DE|`.
    static let prefixPattern = try! NSRegularExpression(
        pattern: #"^\s*[\[\(|]?\s*[A-Za-z]{2,3}\s*[\]\)|:\-]+\s*"#
    )
    static let bracketPattern = try! NSRegularExpression(pattern: #"[\[\(\{][^\]\)\}]*[\]\)\}]"#)

    public static func normalize(_ name: String) -> String {
        var s = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        s = replace(prefixPattern, in: s, with: "")
        s = replace(bracketPattern, in: s, with: " ")
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: "+", with: " plus ")

        var tokens: [String] = []
        var current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }

        let meaningful = tokens.filter { !noiseTokens.contains($0) }
        // Never normalise a name to nothing ("HD" alone keeps its token).
        return (meaningful.isEmpty ? tokens : meaningful).joined()
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
