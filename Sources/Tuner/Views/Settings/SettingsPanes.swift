#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

// MARK: - Playback

struct SettingsPlaybackPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                Picker("Playback engine", selection: $prefs.engine) {
                    ForEach(EngineChoice.allCases) { Text($0.title).tag($0) }
                }
                SettingsToolStatusRow(
                    found: model.mpvAvailable,
                    foundTitle: "mpv is installed",
                    foundDetail: "MPEG-TS, MKV and other formats play with mpv.",
                    missingTitle: "mpv isn't installed",
                    missingDetail: "Install mpv for MPEG-TS/MKV support:",
                    command: "brew install mpv"
                )
                Toggle(isOn: $prefs.hardwareDecoding) {
                    Text("Hardware decoding")
                    Text("Decode video on the GPU. Turn off if you see green frames or artifacts.")
                }
            } header: {
                Text("Engine")
            } footer: {
                SettingsFooter("Automatic uses AVFoundation for HLS/MP4 and switches to mpv for formats it can't play.")
            }

            Section("Buffering") {
                SettingsNumberRow(title: "Network buffer", subtitle: "Read ahead to ride out network hiccups.",
                                  value: $prefs.bufferMegabytes, range: 16...2048, step: 16, unit: "MB")
                SettingsNumberRow(title: "Timeshift buffer", subtitle: "Lets you pause and rewind live TV.",
                                  value: $prefs.timeshiftMegabytes, range: 0...4096, step: 64, unit: "MB")
            }

            Section("Reliability") {
                Toggle(isOn: $prefs.autoFailover) {
                    Text("Automatic failover")
                    Text("When a live stream stops, reconnect and try the channel's alternates.")
                }
                SettingsNumberRow(title: "Stall timeout", subtitle: "How long a frozen stream waits before reconnecting.",
                                  value: $prefs.stallTimeoutSeconds, range: 3...120, unit: "s")
                SettingsNumberRow(title: "Reconnect attempts", value: $prefs.maxRetries, range: 0...50, unit: "")
            }

            Section("Movies & Shows") {
                Toggle("Resume where you left off", isOn: $prefs.resumePlayback)
                Toggle("Play the next episode automatically", isOn: $prefs.autoplayNextEpisode)
                Picker(selection: $prefs.upNextCountdown) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                } label: {
                    Text("“Up Next” countdown")
                    Text(prefs.upNextCountdown == 0
                         ? "The next episode starts as soon as one ends."
                         : "Shows the next episode near the end, with Play Now and Cancel.")
                }
                .disabled(!prefs.autoplayNextEpisode)
                SettingsNumberRow(title: "Catch-up padding", subtitle: "Start catch-up programs a little early.",
                                  value: $prefs.catchupPaddingMinutes, range: 0...30, unit: "min")
            }

            Section {
                TextField("User agent", text: $prefs.defaultUserAgent, prompt: Text("Default"))
            } header: {
                Text("Network")
            } footer: {
                SettingsFooter("Sent to providers that don't set their own. Some providers only accept specific players, for example VLC/3.0.20.")
            }

            Section {
                TextEditor(text: $prefs.mpvExtraOptions)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    .frame(minHeight: 84)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Advanced mpv Options")
            } footer: {
                SettingsFooter("One key=value per line, for example deinterlace=yes. Lines starting with # are ignored. Applies to streams opened afterwards.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.defaultUserAgent) { _, _ in
            Task { await model.applyPreferences() }
        }
    }
}

// MARK: - Guide & Library

struct SettingsGuidePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Channels") {
                Picker("Sort channels by", selection: $prefs.channelSort) {
                    ForEach(ChannelSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show channel numbers", isOn: $prefs.showChannelNumbers)
                Toggle(isOn: $prefs.showChannelBannerOnZap) {
                    Text("Show channel banner when zapping")
                    Text("Briefly shows the channel and what's on when you change channels.")
                }
                Toggle(isOn: $prefs.hideAdultContent) {
                    Text("Hide adult content")
                    Text("Hides categories and channels marked as adult.")
                }
            }

            Section {
                Picker("Live TV and guide", selection: $prefs.liveRefreshHours) {
                    ForEach(Self.options([0, 1, 3, 6, 12, 24], including: prefs.liveRefreshHours), id: \.self) {
                        Text(Self.intervalTitle($0)).tag($0)
                    }
                }
                Picker("Movies and shows", selection: $prefs.vodRefreshHours) {
                    ForEach(Self.options([0, 6, 12, 24, 48, 168], including: prefs.vodRefreshHours), id: \.self) {
                        Text(Self.intervalTitle($0)).tag($0)
                    }
                }
            } header: {
                Text("Automatic Refresh")
            } footer: {
                SettingsFooter("Playlists can override these in their own settings. Refresh any time with ⌘R.")
            }

            Section("Reminders") {
                Picker("Remind me", selection: $prefs.reminderLeadMinutes) {
                    ForEach(Self.options([0, 1, 2, 5, 10, 15, 30], including: prefs.reminderLeadMinutes), id: \.self) { minutes in
                        Text(minutes == 0 ? "When it starts" : "\(minutes) minute\(minutes == 1 ? "" : "s") before").tag(minutes)
                    }
                }
            }

            Section("Library") {
                Slider(value: $prefs.posterSize, in: 110...240) {
                    Text("Poster size")
                } minimumValueLabel: {
                    Image(systemName: "photo").imageScale(.small).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    static func options(_ base: [Int], including current: Int) -> [Int] {
        base.contains(current) ? base : (base + [current]).sorted()
    }

    static func intervalTitle(_ hours: Int) -> String {
        switch hours {
        case 0: "Manually"
        case 1: "Every hour"
        case 24: "Every day"
        case 168: "Every week"
        case let h where h % 24 == 0: "Every \(h / 24) days"
        default: "Every \(hours) hours"
        }
    }
}

// MARK: - Recording

struct SettingsRecordingPane: View {
    @Environment(AppModel.self) private var model
    @ViewState private var ffmpeg = RecordingService.ffmpegPath()

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Location") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Show in Finder", action: showInFinder)
                        Button("Choose…", action: chooseFolder)
                    }
                } label: {
                    Label {
                        Text("Save recordings to")
                        Text((prefs.recordingsPath as NSString).abbreviatingWithTildeInPath)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } icon: {
                        Image(nsImage: folderIcon)
                            .resizable()
                            .frame(width: 22, height: 22)
                    }
                }
            }

            Section {
                SettingsNumberRow(title: "Start early by", value: $prefs.recordingStartPaddingMinutes, range: 0...30, unit: "min")
                SettingsNumberRow(title: "Keep recording for", subtitle: "After the program is scheduled to end.",
                                  value: $prefs.recordingEndPaddingMinutes, range: 0...60, unit: "min")
            } header: {
                Text("Padding")
            } footer: {
                SettingsFooter("Programs often start and end a little off schedule. Padding applies to newly scheduled recordings.")
            }

            Section("Recorder") {
                SettingsToolStatusRow(
                    found: ffmpeg != nil,
                    foundTitle: "ffmpeg is installed",
                    foundDetail: ffmpeg,
                    missingTitle: "ffmpeg isn't installed",
                    missingDetail: "Recording needs ffmpeg. Install ffmpeg:",
                    command: "brew install ffmpeg"
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { ffmpeg = RecordingService.ffmpegPath() }
        .onChange(of: prefs.recordingsPath) { _, _ in apply() }
        .onChange(of: prefs.recordingStartPaddingMinutes) { _, _ in apply() }
        .onChange(of: prefs.recordingEndPaddingMinutes) { _, _ in apply() }
    }

    private var folderURL: URL { URL(fileURLWithPath: model.prefs.recordingsPath, isDirectory: true) }

    private var folderIcon: NSImage {
        FileManager.default.fileExists(atPath: folderURL.path)
            ? NSWorkspace.shared.icon(forFile: folderURL.path)
            : NSWorkspace.shared.icon(for: .folder)
    }

    private func apply() {
        Task { await model.applyPreferences() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Tuner saves recordings."
        panel.directoryURL = folderURL
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.prefs.recordingsPath = url.path
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private func showInFinder() {
        let url = folderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Appearance

struct SettingsAppearancePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        ForEach(AccentTheme.allCases) { theme in
                            SettingsAccentSwatch(theme: theme, selected: prefs.accent == theme) {
                                prefs.accent = theme
                            }
                        }
                    }
                } label: {
                    Text("Accent color")
                    Text(prefs.accent.title)
                }
                Toggle(isOn: $prefs.followSystemAppearance) {
                    Text("Follow system appearance")
                    Text("When off, Tuner always uses its dark appearance, like the TV app.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsAccentSwatch: View {
    let theme: AccentTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(theme.color.gradient)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.black.opacity(0.15)))
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 1)
                    }
                }
                .padding(2)
                .overlay {
                    if selected { Circle().strokeBorder(theme.color.opacity(0.6), lineWidth: 2) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(theme.title)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Shortcuts

struct SettingsShortcutsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(KeyboardShortcuts.reference, id: \.0) { key, action in
                    LabeledContent(action) {
                        HStack(spacing: 4) {
                            ForEach(Self.keys(in: key), id: \.self) { part in
                                if part == "/" && key.contains(" / ") || part == "or" || part == "–" {
                                    Text(part).foregroundStyle(.secondary)
                                } else {
                                    SettingsKeyCap(key: part)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                SettingsFooter("These single-key shortcuts work in the main window whenever you're not typing. Menu commands show their shortcuts in the menu bar.")
            }
        }
        .formStyle(.grouped)
    }

    /// Splits "← / →", "G or L" and "1 – 4" into key caps and separators.
    static func keys(in text: String) -> [String] {
        let parts = text.split(separator: " ").map(String.init)
        return parts.count > 1 ? parts : [text]
    }
}

// MARK: - About

struct SettingsAboutPane: View {
    @Bindable private var updater = UpdaterService.shared

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.24), .black],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 96, height: 96)
                        .overlay {
                            Image(systemName: "play.tv.fill")
                                .font(.system(size: 46, weight: .regular))
                                .foregroundStyle(LinearGradient(colors: [AccentTheme.cyan.color, AccentTheme.purple.color],
                                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    Text("Tuner").font(.system(size: 26, weight: .bold))
                    Text(Self.versionString).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Live TV, movies and shows from your IPTV playlists — with a program guide, catch-up, multiview and recording.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("Updates") {
                if updater.isEnabled {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    LabeledContent {
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                    } label: {
                        Text("Last checked")
                        Text(updater.lastCheck.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                    }
                } else {
                    Text("Automatic updates are available in builds downloaded from GitHub Releases.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Acknowledgements") {
                LabeledContent("mpv / libmpv", value: "Video playback")
                LabeledContent("FFmpeg", value: "Recording")
                LabeledContent("GRDB.swift", value: "SQLite toolkit")
                LabeledContent("Sparkle", value: "Automatic updates")
                LabeledContent("ynotv", value: "The IPTV player that inspired Tuner")
            }

            Section {
                LabeledContent {
                    Button("Show Library Folder", action: Self.showLibraryFolder)
                } label: {
                    Text("Library")
                    Text("Your playlists, guide and watch history are stored on this Mac.")
                }
            }
        }
        .formStyle(.grouped)
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "Development" }
        if let build = info?["CFBundleVersion"] as? String, build != version { return "Version \(version) (\(build))" }
        return "Version \(version)"
    }

    static func showLibraryFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Tuner", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
