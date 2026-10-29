import Foundation

/// Titles and channels Apple's player couldn't play (an error, a load timeout, or sound without picture), kept
/// across launches so the next start goes straight to mpv instead of waiting for AVFoundation to fail again
/// (up to the 15 s load timeout). An episode also marks its show: a show's episodes are usually encoded alike.
/// Entries expire after 30 days, so a provider that changes its encoding gets another chance with AVFoundation.
@MainActor
enum EngineMemory {
    private static let defaultsKey = "engineMemoryMPV"
    private static let lifetime: TimeInterval = 30 * 86_400
    private static let limit = 3000

    /// Key → when it was recorded (seconds since 1970).
    private static var entries: [String: Double] = load()

    /// Whether AVFoundation failed for this item (or its show) recently.
    static func prefersMPV(_ item: PlaybackItem) -> Bool {
        let now = Date().timeIntervalSince1970
        return keys(for: item).contains { entries[$0].map { now - $0 < lifetime } ?? false }
    }

    static func remember(_ item: PlaybackItem) {
        let now = Date().timeIntervalSince1970
        for key in keys(for: item) { entries[key] = now }
        if entries.count > limit {
            // Keep the most recent.
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(entries, forKey: defaultsKey)
    }

    /// Live and catch-up share the channel's encoding; an episode also counts for its show.
    private static func keys(for item: PlaybackItem) -> [String] {
        switch item {
        case .channel(let c), .catchup(let c, _): ["ch:\(c.id)"]
        case .movie(let m): ["movie:\(m.id)"]
        case .episode(let e, let s): ["ep:\(e.id)", "series:\(s.id)"]
        case .recording: [item.id]
        }
    }

    private static func load() -> [String: Double] {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        return stored.filter { now - $0.value < lifetime }
    }
}
