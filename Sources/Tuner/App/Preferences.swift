import Foundation
import SwiftUI
import TunerCore

enum EngineChoice: String, CaseIterable, Identifiable, Codable {
    case automatic
    case mpv
    case avFoundation

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .mpv: "mpv (libmpv)"
        case .avFoundation: "AVFoundation"
        }
    }
}

/// How episode cards show their picture (episode stills can spoil plot points).
enum EpisodeThumbnailStyle: String, CaseIterable, Identifiable, Codable {
    /// The episode's own still (provider image, else online metadata), like the TV app.
    case show
    /// Stills for watched episodes; unwatched ones are blurred (spoiler-free).
    case blurUnwatched
    /// No episode stills: series artwork with the episode number instead.
    case hide

    var id: String { rawValue }
    var title: String {
        switch self {
        case .show: "Show episode pictures"
        case .blurUnwatched: "Blur unwatched episodes"
        case .hide: "Don't show episode pictures"
        }
    }
}

enum AccentTheme: String, CaseIterable, Identifiable, Codable {
    case cyan, blue, purple, crimson, orange, green, gold

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .cyan: Color(red: 0.0, green: 0.83, blue: 1.0)      // ynotv's default "dark-cyan" #00d4ff
        case .blue: Color(red: 0.25, green: 0.52, blue: 1.0)
        case .purple: Color(red: 0.70, green: 0.40, blue: 1.0)    // #b266ff
        case .crimson: Color(red: 1.0, green: 0.20, blue: 0.33)
        case .orange: Color(red: 1.0, green: 0.58, blue: 0.15)
        case .green: Color(red: 0.20, green: 0.85, blue: 0.50)
        case .gold: Color(red: 0.98, green: 0.80, blue: 0.25)
        }
    }
}

/// User preferences persisted in UserDefaults. Observable so views update live.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    // Playback
    var engine: EngineChoice { didSet { set(engine.rawValue, "engine") } }
    var hardwareDecoding: Bool { didSet { set(hardwareDecoding, "hardwareDecoding") } }
    var bufferMegabytes: Int { didSet { set(bufferMegabytes, "bufferMegabytes") } }
    var timeshiftMegabytes: Int { didSet { set(timeshiftMegabytes, "timeshiftMegabytes") } }
    var mpvExtraOptions: String { didSet { set(mpvExtraOptions, "mpvExtraOptions") } }
    var defaultUserAgent: String { didSet { set(defaultUserAgent, "defaultUserAgent") } }
    var autoFailover: Bool { didSet { set(autoFailover, "autoFailover") } }
    var stallTimeoutSeconds: Int { didSet { set(stallTimeoutSeconds, "stallTimeoutSeconds") } }
    var maxRetries: Int { didSet { set(maxRetries, "maxRetries") } }
    var resumePlayback: Bool { didSet { set(resumePlayback, "resumePlayback") } }
    var autoplayNextEpisode: Bool { didSet { set(autoplayNextEpisode, "autoplayNextEpisode") } }
    /// Seconds the "Up Next" card counts down before the next episode starts; 0 = no card (starts right away).
    var upNextCountdown: Int { didSet { set(upNextCountdown, "upNextCountdown") } }
    var volume: Double { didSet { set(volume, "volume") } }
    var catchupPaddingMinutes: Int { didSet { set(catchupPaddingMinutes, "catchupPaddingMinutes") } }

    // Guide & library
    var channelSort: ChannelSort { didSet { set(channelSort.rawValue, "channelSort") } }
    var showChannelNumbers: Bool { didSet { set(showChannelNumbers, "showChannelNumbers") } }
    var hideAdultContent: Bool { didSet { set(hideAdultContent, "hideAdultContent") } }
    var liveRefreshHours: Int { didSet { set(liveRefreshHours, "liveRefreshHours") } }
    var vodRefreshHours: Int { didSet { set(vodRefreshHours, "vodRefreshHours") } }
    var vodSort: VODSort { didSet { set(vodSort.rawValue, "vodSort") } }
    var posterSize: Double { didSet { set(posterSize, "posterSize") } }
    var reminderLeadMinutes: Int { didSet { set(reminderLeadMinutes, "reminderLeadMinutes") } }
    var showChannelBannerOnZap: Bool { didSet { set(showChannelBannerOnZap, "showChannelBannerOnZap") } }

    // Recording
    var recordingsPath: String { didSet { set(recordingsPath, "recordingsPath") } }
    var recordingStartPaddingMinutes: Int { didSet { set(recordingStartPaddingMinutes, "recordingStartPaddingMinutes") } }
    var recordingEndPaddingMinutes: Int { didSet { set(recordingEndPaddingMinutes, "recordingEndPaddingMinutes") } }

    // Downloads (movies and episodes saved for offline viewing)
    var downloadsPath: String { didSet { set(downloadsPath, "downloadsPath") } }

    // Online metadata (Cinemeta by default; TMDB when a key is set)
    var metadataEnabled: Bool { didSet { set(metadataEnabled, "metadataEnabled") } }
    var tmdbAPIKey: String { didSet { set(tmdbAPIKey, "tmdbAPIKey") } }
    var metadataLanguage: String { didSet { set(metadataLanguage, "metadataLanguage") } }
    var episodeThumbnails: EpisodeThumbnailStyle { didSet { set(episodeThumbnails.rawValue, "episodeThumbnails") } }

    // Appearance
    var accent: AccentTheme { didSet { set(accent.rawValue, "accent") } }
    var followSystemAppearance: Bool { didSet { set(followSystemAppearance, "followSystemAppearance") } }

    // Keyboard: single-key shortcut overrides (action raw value → key name; "" = unassigned)
    var shortcutOverrides: [String: String] { didSet { set(shortcutOverrides, "shortcutOverrides") } }

    // Session state
    var lastChannelId: String? { didSet { set(lastChannelId, "lastChannelId") } }
    var resumeLastChannelOnLaunch: Bool { didSet { set(resumeLastChannelOnLaunch, "resumeLastChannelOnLaunch") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func v<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }

        engine = EngineChoice(rawValue: v("engine", "")) ?? .automatic
        hardwareDecoding = v("hardwareDecoding", true)
        bufferMegabytes = v("bufferMegabytes", 150)
        timeshiftMegabytes = v("timeshiftMegabytes", 256)
        mpvExtraOptions = v("mpvExtraOptions", "")
        defaultUserAgent = v("defaultUserAgent", "")
        autoFailover = v("autoFailover", true)
        stallTimeoutSeconds = v("stallTimeoutSeconds", 12)
        maxRetries = v("maxRetries", 10)
        resumePlayback = v("resumePlayback", true)
        autoplayNextEpisode = v("autoplayNextEpisode", true)
        upNextCountdown = v("upNextCountdown", 10)
        volume = v("volume", 100.0)
        catchupPaddingMinutes = v("catchupPaddingMinutes", 0)

        channelSort = ChannelSort(rawValue: v("channelSort", "")) ?? .provider
        showChannelNumbers = v("showChannelNumbers", false)
        hideAdultContent = v("hideAdultContent", false)
        liveRefreshHours = v("liveRefreshHours", 6)
        vodRefreshHours = v("vodRefreshHours", 24)
        vodSort = VODSort(rawValue: v("vodSort", "")) ?? .added
        posterSize = v("posterSize", 150.0)
        reminderLeadMinutes = v("reminderLeadMinutes", 2)
        showChannelBannerOnZap = v("showChannelBannerOnZap", true)

        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        recordingsPath = v("recordingsPath", moviesDir.appendingPathComponent("Tuner Recordings").path)
        recordingStartPaddingMinutes = v("recordingStartPaddingMinutes", 1)
        recordingEndPaddingMinutes = v("recordingEndPaddingMinutes", 5)
        // A scratch library (TUNER_DATA_DIR) never downloads into a folder chosen outside it.
        let storedDownloadsPath: String = v("downloadsPath", Self.defaultDownloadsPath)
        if let scratch = TunerApp.dataDirectoryOverride?.standardizedFileURL.path, !storedDownloadsPath.hasPrefix(scratch) {
            downloadsPath = Self.defaultDownloadsPath
        } else {
            downloadsPath = storedDownloadsPath
        }

        metadataEnabled = v("metadataEnabled", true)
        episodeThumbnails = EpisodeThumbnailStyle(rawValue: v("episodeThumbnails", "")) ?? .show
        tmdbAPIKey = v("tmdbAPIKey", "")
        let region = Locale.current.region?.identifier ?? "US"
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        metadataLanguage = v("metadataLanguage", "\(language)-\(region)")

        accent = AccentTheme(rawValue: v("accent", "")) ?? .cyan
        followSystemAppearance = v("followSystemAppearance", false)

        shortcutOverrides = defaults.dictionary(forKey: "shortcutOverrides") as? [String: String] ?? [:]
        lastChannelId = defaults.string(forKey: "lastChannelId")
        resumeLastChannelOnLaunch = v("resumeLastChannelOnLaunch", true)
    }

    /// `~/Movies/Tuner Downloads`; test runs with a scratch library (TUNER_DATA_DIR) keep downloads inside it, so they
    /// never touch the user's folder.
    static var defaultDownloadsPath: String {
        if let scratch = TunerApp.dataDirectoryOverride {
            return scratch.appendingPathComponent("Downloads", isDirectory: true).path
        }
        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return moviesDir.appendingPathComponent("Tuner Downloads", isDirectory: true).path
    }

    private func set(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    var metadataSettings: MetadataSettings {
        MetadataSettings(enabled: metadataEnabled, tmdbAPIKey: tmdbAPIKey.nilIfEmpty, language: metadataLanguage)
    }

    /// `key=value` lines from the advanced mpv options box (comments with `#`).
    var parsedMPVOptions: [(String, String)] {
        mpvExtraOptions.split(whereSeparator: \.isNewline).compactMap { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { return nil }
            if l.hasPrefix("--") { l.removeFirst(2) }
            let parts = l.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "yes")
        }
    }
}
