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
    /// Where to read an M3U file the user picked from. The Mac App Store app may read a picked file only until it
    /// quits, so it copies the file into its library folder, where playlist refreshes can read it later; the other
    /// apps use the file where it is.
    static func playlistFileURL(for picked: URL) -> URL {
        #if TUNER_APP_STORE
        let folder = TunerApp.dataDirectory.appendingPathComponent("Playlist Files", isDirectory: true)
        let copy = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(picked.lastPathComponent)")
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: picked, to: copy)
            return copy
        } catch {
            return picked
        }
        #else
        picked
        #endif
    }
}
