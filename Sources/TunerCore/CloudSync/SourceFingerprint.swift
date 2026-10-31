import CryptoKit
import Foundation

/// Identifies "the same playlist" on every device without its secrets. Local ids start with a random per-device source
/// id (`"<sourceId>_<suffix>"`), so synced records name a playlist by this fingerprint instead
/// (`"<fingerprint>|<suffix>"`).
///
/// Fingerprint = hash of the kind, the normalised URL (lowercased scheme and host, default port and trailing slashes
/// dropped, no user info, password/token-like query parameters removed, the rest sorted), the lowercased username and,
/// for Stalker, the MAC address. Passwords are never part of it.
public enum SourceFingerprint {
    public static func of(_ source: Source) -> String {
        of(kind: source.kind, url: source.url, username: source.username, mac: source.mac)
    }

    public static func of(kind: Source.Kind, url: String, username: String?, mac: String?) -> String {
        var parts = ["tuner-source-1", kind.rawValue, normalizedURL(url),
                     (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        if kind == .stalker { parts.append((mac ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// The URL in the form the fingerprint hashes: secrets removed, cosmetic differences evened out.
    public static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased() else {
            var s = trimmed.lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        comps.scheme = scheme
        comps.user = nil
        comps.password = nil
        comps.host = comps.host?.lowercased()
        if (scheme == "http" && comps.port == 80) || (scheme == "https" && comps.port == 443) { comps.port = nil }
        var path = stripPathCredentials(comps.percentEncodedPath).path
        while path.hasSuffix("/") { path.removeLast() }
        comps.percentEncodedPath = path
        let items = (comps.queryItems ?? []).filter { !isSecretParameter($0.name) }
            .sorted { ($0.name.lowercased(), $0.value ?? "") < ($1.name.lowercased(), $1.value ?? "") }
        comps.queryItems = items.isEmpty ? nil : items
        comps.fragment = nil
        return comps.string ?? trimmed.lowercased()
    }

    /// Query parameter names that carry a secret (`password`, `pass`, `token`, `api_key`…).
    public static func isSecretParameter(_ name: String) -> Bool {
        let n = name.lowercased()
        if ["p", "pwd", "pw", "key", "apikey", "sig", "signature"].contains(n) { return true }
        return ["pass", "token", "secret", "auth", "api_key", "apikey"].contains { n.contains($0) }
    }

    /// `raw` without a password in its user info or secret query parameters, and whether anything was removed.
    /// The rest of the URL is kept as written (it is shown in the source editor on the other device).
    public static func publicURL(_ raw: String) -> (url: String, removedSecret: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed), comps.scheme != nil else { return (trimmed, false) }
        var removed = false
        if comps.password != nil {
            comps.password = nil
            removed = true
        }
        let stripped = stripPathCredentials(comps.percentEncodedPath)
        if stripped.removed {
            comps.percentEncodedPath = stripped.path
            removed = true
        }
        if let items = comps.queryItems {
            let kept = items.filter { !isSecretParameter($0.name) }
            if kept.count != items.count {
                removed = true
                comps.queryItems = kept.isEmpty ? nil : kept
            }
        }
        guard removed else { return (trimmed, false) }
        return (comps.string ?? trimmed, true)
    }

    /// Path words after which IPTV panels put the account's username and password
    /// (`/playlist/USER/PASS/m3u_plus`, `/live/USER/PASS/123.ts`, `/m3u/USER/PASS`).
    static let credentialPathKeywords: Set<String> = ["playlist", "live", "movie", "series", "m3u", "m3u8", "get", "xmltv", "timeshift", "panel"]

    /// The path with the two segments that follow a credential keyword replaced by `USER` / `PASSWORD`, and whether
    /// any were. Conservative: only when two non-empty segments follow the keyword.
    static func stripPathCredentials(_ path: String) -> (path: String, removed: Bool) {
        var segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var removed = false
        var i = 0
        while i < segments.count {
            if credentialPathKeywords.contains(segments[i].lowercased()), i + 2 < segments.count,
               !segments[i + 1].isEmpty, !segments[i + 2].isEmpty,
               segments[i + 1] != "USER" || segments[i + 2] != "PASSWORD" {
                segments[i + 1] = "USER"
                segments[i + 2] = "PASSWORD"
                removed = true
                i += 3
            } else {
                i += 1
            }
        }
        return (segments.joined(separator: "/"), removed)
    }

    /// Whether `raw` carries a secret (it is then left out of synced lists such as backup URLs and extra guides).
    public static func containsSecret(_ raw: String) -> Bool {
        publicURL(raw).removedSecret
    }
}
