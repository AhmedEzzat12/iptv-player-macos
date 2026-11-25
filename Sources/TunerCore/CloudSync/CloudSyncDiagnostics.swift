import Foundation

/// Problems a sync pass can see but not fix, shown in Settings → Sync.
public enum CloudSyncDiagnostics {
    /// Playlists that look like the same account added twice with different server addresses. Devices match
    /// playlists by server and username, so a provider added as `a.example:8080` on one device and `b.example:8080`
    /// on another is two playlists: each device also gets the other's copy, and watch progress, favourites and
    /// hidden channels follow whichever copy was used. One notice per account; nothing names the server.
    public static func duplicatePlaylistNotices(_ sources: [Source]) -> [String] {
        var groups: [String: [Source]] = [:]
        for source in sources {
            guard let user = source.username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !user.isEmpty else { continue }
            let mac = source.kind == .stalker ? (source.mac ?? "").lowercased() : ""
            groups["\(source.kind.rawValue)|\(user)|\(mac)", default: []].append(source)
        }
        return groups.values
            .filter { copies in
                Set(copies.map { SourceFingerprint.of(kind: $0.kind, url: $0.url, username: $0.username, mac: $0.mac) }).count > 1
            }
            .map { copies in copies.sorted { $0.createdAt < $1.createdAt } }
            .sorted { $0[0].name.localizedStandardCompare($1[0].name) == .orderedAscending }
            .map { copies in
                let names = copies.map { "“\($0.name)”" }.joined(separator: " and ")
                return "\(names) look like the same account with different server addresses, so they sync as separate "
                    + "playlists and progress follows whichever one you watched with. Use the same server address on every "
                    + "device and remove the extra copy."
            }
    }
}
