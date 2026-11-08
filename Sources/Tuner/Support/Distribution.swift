import Foundation

/// Which app this is: the Mac app from GitHub Releases (Sparkle updates, Homebrew's mpv and ffmpeg), the Mac App Store
/// app (sandboxed, mpv built in; compiled with `TUNER_APP_STORE`) or the iPhone/iPad app.
enum Distribution {
    #if TUNER_APP_STORE
    static let isMacAppStore = true
    #else
    static let isMacAppStore = false
    #endif

    /// The name users see. The App Store apps (iPhone, iPad, Mac) are "Antenna" (another IPTV app already has "Tuner"
    /// on the App Store); the GitHub Mac app keeps "Tuner", and the code, repo and data folders stay "Tuner".
    static var appName: String {
        #if os(macOS) && !TUNER_APP_STORE
        "Tuner"
        #else
        "Antenna"
        #endif
    }

    /// Recording and the AirPlay converter run ffmpeg as a separate program, which only the GitHub Mac app can
    /// (iOS apps can't start programs; sandboxed Mac App Store apps can't run Homebrew's).
    static var runsFFmpeg: Bool {
        #if os(macOS)
        !isMacAppStore
        #else
        false
        #endif
    }

    /// Recording needs ffmpeg (above).
    static var supportsRecording: Bool { runsFFmpeg }
}

extension Distribution {
    /// Where to read an M3U file the user picked from. The Mac App Store app may read a picked file only while it
    /// keeps a security-scoped bookmark to it, so it saves one (restored at launch by `restorePlaylistFileAccess`);
    /// the file is still read where it is, so refreshes see the user's edits. The other apps need nothing.
    static func playlistFileURL(for picked: URL) -> URL {
        #if TUNER_APP_STORE
        // Access stays open for this run; the bookmark brings it back after a relaunch.
        _ = picked.startAccessingSecurityScopedResource()
        if let data = try? picked.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                               includingResourceValuesForKeys: nil, relativeTo: nil) {
            var bookmarks = UserDefaults.standard.dictionary(forKey: playlistBookmarksKey) as? [String: Data] ?? [:]
            bookmarks[picked.path] = data
            UserDefaults.standard.set(bookmarks, forKey: playlistBookmarksKey)
        }
        #endif
        return picked
    }

    /// Mac App Store app, at launch: reopens access to the playlist files picked earlier and forgets files that are
    /// gone. A no-op elsewhere.
    static func restorePlaylistFileAccess() {
        #if TUNER_APP_STORE
        let stored = UserDefaults.standard.dictionary(forKey: playlistBookmarksKey) as? [String: Data] ?? [:]
        var kept: [String: Data] = [:]
        for (path, data) in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                     bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            let fresh = stale ? try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                       includingResourceValuesForKeys: nil, relativeTo: nil) : nil
            kept[path] = fresh ?? data
        }
        if kept.count != stored.count || kept != stored {
            UserDefaults.standard.set(kept, forKey: playlistBookmarksKey)
        }
        #endif
    }

    private static let playlistBookmarksKey = "playlistFileBookmarks"
}
