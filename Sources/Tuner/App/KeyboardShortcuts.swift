import AppKit
import SwiftUI

// MARK: - Actions & bindings

/// Everything a single-key shortcut can do. Defaults follow ynotv; every key can be remapped in
/// Settings → Shortcuts (stored in `Preferences.shortcutOverrides`).
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    // Playback
    case togglePlay, mute, seekBack, seekForward, volumeUp, volumeDown
    case cycleAudio, cycleSubtitles, stats, pictureInPicture, fullScreen
    // Player
    case openPlayer, exitPlayer
    // Live TV
    case channelUp, channelDown, previousChannel, toggleFavorite, recordNow
    // Navigation
    case home, liveTV, movies, series, search, recordings, help
    // Layout
    case layoutSingle, layoutPictureInPicture, layoutMainPlusThree, layoutGrid

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case playback = "Playback"
        case player = "Player"
        case liveTV = "Live TV"
        case navigation = "Navigation"
        case layout = "Multiview Layout"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .togglePlay, .mute, .seekBack, .seekForward, .volumeUp, .volumeDown, .cycleAudio, .cycleSubtitles,
             .stats, .pictureInPicture, .fullScreen: .playback
        case .openPlayer, .exitPlayer: .player
        case .channelUp, .channelDown, .previousChannel, .toggleFavorite, .recordNow: .liveTV
        case .home, .liveTV, .movies, .series, .search, .recordings, .help: .navigation
        case .layoutSingle, .layoutPictureInPicture, .layoutMainPlusThree, .layoutGrid: .layout
        }
    }

    var title: String {
        switch self {
        case .togglePlay: "Play / Pause"
        case .mute: "Mute"
        case .seekBack: "Skip back 10 seconds"
        case .seekForward: "Skip forward 10 seconds"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .cycleAudio: "Next audio track"
        case .cycleSubtitles: "Next subtitle track"
        case .stats: "Playback statistics"
        case .pictureInPicture: "Picture in Picture"
        case .fullScreen: "Full screen"
        case .openPlayer: "Open the player"
        case .exitPlayer: "Leave the player"
        case .channelUp: "Previous channel in list"
        case .channelDown: "Next channel in list"
        case .previousChannel: "Last watched channel"
        case .toggleFavorite: "Add / remove favourite"
        case .recordNow: "Record current channel"
        case .home: "Home"
        case .liveTV: "Live TV guide"
        case .movies: "Movies"
        case .series: "TV Shows"
        case .search: "Search"
        case .recordings: "Recordings"
        case .help: "Show keyboard shortcuts"
        case .layoutSingle: "Single view"
        case .layoutPictureInPicture: "Picture in picture layout"
        case .layoutMainPlusThree: "Main + 3 layout"
        case .layoutGrid: "2 × 2 grid"
        }
    }

    /// Note shown in Settings for actions that only work in a certain context.
    var contextNote: String? {
        switch self {
        case .seekBack, .seekForward: "While the player fills the window"
        case .channelUp, .channelDown: "While watching live TV full window"
        case .openPlayer: "While something is playing in the preview or mini player"
        default: nil
        }
    }

    /// Default key name ("" = unassigned).
    var defaultKey: String {
        switch self {
        case .togglePlay: "space"
        case .mute: "m"
        case .seekBack: "left"
        case .seekForward: "right"
        case .volumeUp: "="
        case .volumeDown: "-"
        case .cycleAudio: "a"
        case .cycleSubtitles: "j"
        case .stats: "i"
        case .pictureInPicture: "p"
        case .fullScreen: "f"
        case .openPlayer: "return"
        case .exitPlayer: "escape"
        case .channelUp: "up"
        case .channelDown: "down"
        case .previousChannel: "q"
        case .toggleFavorite: ""
        case .recordNow: ""
        case .home: "h"
        case .liveTV: "g"
        case .movies: ""
        case .series: ""
        case .search: "s"
        case .recordings: "r"
        case .help: "/"
        case .layoutSingle: "1"
        case .layoutPictureInPicture: "2"
        case .layoutMainPlusThree: "3"
        case .layoutGrid: "4"
        }
    }
}

/// Key names used in bindings: special keys by name ("space", "left", "f5"…), otherwise the lowercased character.
enum ShortcutKey {
    static let specialNames: [UInt16: String] = [
        49: "space", 36: "return", 76: "return", 53: "escape", 48: "tab", 51: "delete", 117: "forwarddelete",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
        109: "f10", 103: "f11", 111: "f12",
    ]

    /// Name for a key event, or nil for keys that can't be bound (modifiers alone etc.).
    static func name(code: UInt16, characters: String?) -> String? {
        if let special = specialNames[code] { return special }
        guard let c = characters?.lowercased(), c.count == 1, let scalar = c.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar) else { return nil }
        // Shifted variants map to their base key (+ is on the = key on most layouts).
        switch c {
        case "+": return "="
        case "?": return "/"
        case "_": return "-"
        default: return c
        }
    }

    /// Human-readable label for Settings and the help sheet.
    static func label(_ name: String) -> String {
        switch name {
        case "": "—"
        case "space": "Space"
        case "return": "Return"
        case "escape": "Esc"
        case "tab": "Tab"
        case "delete": "⌫"
        case "forwarddelete": "⌦"
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "home": "Home"
        case "end": "End"
        case "pageup": "Page Up"
        case "pagedown": "Page Down"
        case "=": "+"
        default: name.uppercased()
        }
    }
}

extension Preferences {
    /// Effective key for an action (override, else default).
    func key(for action: ShortcutAction) -> String {
        shortcutOverrides[action.rawValue] ?? action.defaultKey
    }

    /// The action bound to a key, if any.
    func action(forKey key: String) -> ShortcutAction? {
        ShortcutAction.allCases.first { self.key(for: $0) == key }
    }

    /// Binds `key` to `action`, unbinding it from any other action. Returns the action that lost the key.
    @discardableResult
    func bind(_ action: ShortcutAction, to key: String) -> ShortcutAction? {
        var overrides = shortcutOverrides
        var displaced: ShortcutAction?
        if !key.isEmpty, let other = self.action(forKey: key), other != action {
            overrides[other.rawValue] = ""
            displaced = other
        }
        overrides[action.rawValue] = key == action.defaultKey ? nil : key
        shortcutOverrides = overrides
        return displaced
    }

    func resetShortcuts() {
        shortcutOverrides = [:]
    }
}

// MARK: - Dispatcher

/// Single-key shortcuts, active only in the main window and never while typing in a text field.
/// Menu commands with ⌘ equivalents live in `TunerCommands`.
@MainActor
final class KeyboardShortcuts {
    private var monitor: Any?
    private weak var model: AppModel?
    /// While Settings is recording a new binding, shortcuts are suspended.
    static var isRecording = false

    init(model: AppModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Local monitors run on the main thread; pass plain values across the isolation boundary.
            let key = Key(code: event.keyCode, characters: event.charactersIgnoringModifiers,
                          hasModifiers: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty)
            let handled = MainActor.assumeIsolated { self.handle(key) }
            return handled ? nil : event
        }
    }

    /// Legacy flat list (current defaults) for older views.
    static var reference: [(String, String)] {
        ShortcutAction.allCases.filter { !$0.defaultKey.isEmpty }.map { (ShortcutKey.label($0.defaultKey), $0.title) }
    }

    private struct Key: Sendable {
        let code: UInt16
        let characters: String?
        let hasModifiers: Bool
    }

    private func handle(_ event: Key) -> Bool {
        guard !Self.isRecording, let model, let window = NSApp.keyWindow, window === model.mainWindow else { return false }
        if window.firstResponder is NSText { return false }
        guard !event.hasModifiers, let name = ShortcutKey.name(code: event.code, characters: event.characters) else { return false }
        if name == "escape", model.showShortcutHelp {
            model.showShortcutHelp = false
            return true
        }
        guard let action = model.prefs.action(forKey: name) else { return false }
        return perform(action, model: model, window: window)
    }

    /// Runs an action if it applies in the current context; returns false to let the key through.
    @discardableResult
    func perform(_ action: ShortcutAction, model: AppModel, window: NSWindow?) -> Bool {
        let player = model.player
        let main = player.main
        let full = player.isFullWindow
        let live = main.item?.isLive == true

        switch action {
        case .togglePlay:
            guard player.hasMedia else { return false }
            main.togglePause()
        case .mute:
            guard player.hasMedia else { return false }
            main.isMuted.toggle()
        case .seekBack, .seekForward:
            guard full, player.hasMedia else { return false }
            main.seek(by: action == .seekBack ? -10 : 10)
        case .volumeUp, .volumeDown:
            guard player.hasMedia else { return false }
            main.volume = min(150, max(0, main.volume + (action == .volumeUp ? 5 : -5)))
            model.prefs.volume = main.volume
        case .cycleAudio:
            guard player.hasMedia else { return false }
            let track = main.cycleAudioTrack()
            model.notify(Banner(symbol: "speaker.wave.2", title: "Audio", message: track?.label ?? "No other audio tracks"))
        case .cycleSubtitles:
            guard player.hasMedia else { return false }
            let track = main.cycleSubtitleTrack()
            model.notify(Banner(symbol: "captions.bubble", title: "Subtitles",
                                message: track?.label ?? (main.subtitleTracks.isEmpty ? "No subtitles available" : "Off")))
        case .stats:
            player.showStats.toggle()
        case .pictureInPicture:
            guard main.isPictureInPicturePossible else { return false }
            main.togglePictureInPicture()
        case .fullScreen:
            if player.hasMedia, !full { model.enterFullWindow() }
            model.toggleWindowFullScreen()
        case .openPlayer:
            guard player.hasMedia, !full else { return false }
            model.enterFullWindow()
        case .exitPlayer:
            guard full else { return false }
            if let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            model.exitFullWindow()
        case .channelUp, .channelDown:
            guard full, live else { return false }
            action == .channelUp ? model.channelUp() : model.channelDown()
        case .previousChannel:
            model.playPreviousChannel()
        case .toggleFavorite:
            guard live, let channel = main.item?.channel else { return false }
            model.toggleFavorite(channel)
            model.notify(Banner(symbol: channel.isFavorite ? "star.slash" : "star.fill",
                                title: channel.isFavorite ? "Removed from Favorites" : "Added to Favorites", message: channel.displayName))
        case .recordNow:
            guard live, let channel = main.item?.channel else { return false }
            model.recordNow(channel)
        case .home: model.sidebarSelection = .home
        case .liveTV: model.sidebarSelection = .liveTV
        case .movies: model.sidebarSelection = .movies
        case .series: model.sidebarSelection = .series
        case .search: model.sidebarSelection = .search
        case .recordings: model.sidebarSelection = .recordings
        case .help: model.showShortcutHelp.toggle()
        case .layoutSingle: player.layout = .single
        case .layoutPictureInPicture: player.layout = .pictureInPicture
        case .layoutMainPlusThree: player.layout = .bigAndBottom
        case .layoutGrid: player.layout = .grid2x2
        }
        return true
    }
}

// MARK: - Menus

/// Menu bar commands (⌘ equivalents) — discoverable versions of the single-key shortcuts.
struct TunerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Playlist…") { model.sourceEditor = SourceEditorRequest(source: nil, kind: .m3u) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Refresh All Playlists") { model.syncAll() }
                .keyboardShortcut("r", modifiers: [.command])
        }
        CommandMenu("Go") {
            Button("Home") { model.sidebarSelection = .home }.keyboardShortcut("1", modifiers: .command)
            Button("Live TV") { model.sidebarSelection = .liveTV }.keyboardShortcut("2", modifiers: .command)
            Button("Movies") { model.sidebarSelection = .movies }.keyboardShortcut("3", modifiers: .command)
            Button("TV Shows") { model.sidebarSelection = .series }.keyboardShortcut("4", modifiers: .command)
            Button("Recordings") { model.sidebarSelection = .recordings }.keyboardShortcut("5", modifiers: .command)
            Button("Search") { model.sidebarSelection = .search }.keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Playback") {
            Button("Play/Pause") { model.player.main.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Skip Forward") { model.player.main.seek(by: 10) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Skip Back") { model.player.main.seek(by: -10) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Next Channel") { model.channelDown() }.keyboardShortcut("]", modifiers: .command)
            Button("Previous Channel") { model.channelUp() }.keyboardShortcut("[", modifiers: .command)
            Button("Last Channel") { model.playPreviousChannel() }.keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("Volume Up") {
                model.player.main.volume = min(150, model.player.main.volume + 5)
                model.prefs.volume = model.player.main.volume
            }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") {
                model.player.main.volume = max(0, model.player.main.volume - 5)
                model.prefs.volume = model.player.main.volume
            }.keyboardShortcut(.downArrow, modifiers: .command)
            Button("Mute") { model.player.main.isMuted.toggle() }.keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
            Button("Open Player") { model.enterFullWindow() }.keyboardShortcut(.return, modifiers: .command)
            // Second path for Esc (the key monitor handles it first); disabled — and so not consuming Esc
            // in sheets and fields — unless the player fills the window.
            Button("Leave Player") {
                if let window = model.mainWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                model.exitFullWindow()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!model.player.isFullWindow)
            Button("Stop") { model.stopPlayback() }.keyboardShortcut(".", modifiers: .command)
            Button("Show Playback Statistics") { model.player.showStats.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Layout") {
            ForEach(Array(MultiviewLayout.allCases.enumerated()), id: \.element) { index, layout in
                Button(layout.title) { model.player.layout = layout }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.showShortcutHelp = true }.keyboardShortcut("/", modifiers: .command)
        }
    }
}

// MARK: - Help sheet

/// Current bindings (reflects remapping), grouped like Settings.
struct ShortcutHelpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ShortcutAction.Group.allCases) { group in
                        let actions = ShortcutAction.allCases.filter { $0.group == group && !model.prefs.key(for: $0).isEmpty }
                        if !actions.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.rawValue).font(.headline).foregroundStyle(.secondary)
                                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                                    ForEach(actions) { action in
                                        GridRow {
                                            ShortcutKeyCap(label: ShortcutKey.label(model.prefs.key(for: action)))
                                            Text(action.title)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text("Media keys (⏯ ⏮ ⏭), AirPods and Control Center also control playback. Change keys in Settings → Shortcuts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
    }
}

/// A rounded key label.
struct ShortcutKeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.body, design: .rounded).weight(.semibold))
            .frame(minWidth: 28)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }
}
