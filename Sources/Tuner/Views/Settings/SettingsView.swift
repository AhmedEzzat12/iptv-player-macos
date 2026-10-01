import AppKit
import SwiftUI
import TunerCore

/// The app's Settings scene (⌘,): toolbar-style tabs, each a grouped `Form` like System Settings.
struct SettingsView: View {
    @ViewState private var selection: SettingsTab = .playlists

    var body: some View {
        TabView(selection: $selection) {
            Tab("Playlists", systemImage: "play.square.stack", value: SettingsTab.playlists) {
                SettingsPlaylistsPane().settingsPaneFrame(height: 600)
            }
            Tab("Playback", systemImage: "play.rectangle", value: SettingsTab.playback) {
                SettingsPlaybackPane().settingsPaneFrame(height: 620)
            }
            Tab("Guide & Library", systemImage: "calendar", value: SettingsTab.guide) {
                SettingsGuidePane().settingsPaneFrame(height: 560)
            }
            Tab("Metadata", systemImage: "text.below.photo", value: SettingsTab.metadata) {
                SettingsMetadataPane().settingsPaneFrame(height: 680)
            }
            Tab("Recording", systemImage: "record.circle", value: SettingsTab.recording) {
                SettingsRecordingPane().settingsPaneFrame(height: 440)
            }
            Tab("Appearance", systemImage: "paintpalette", value: SettingsTab.appearance) {
                SettingsAppearancePane().settingsPaneFrame(height: 300)
            }
            Tab("Shortcuts", systemImage: "keyboard", value: SettingsTab.shortcuts) {
                SettingsShortcutsEditor().settingsPaneFrame(height: 560)
            }
            Tab("About", systemImage: "info.circle", value: SettingsTab.about) {
                SettingsAboutPane().settingsPaneFrame(height: 580)
            }
        }
    }
}

private enum SettingsTab: Hashable {
    case playlists, playback, guide, metadata, recording, appearance, shortcuts, about
}

private extension View {
    func settingsPaneFrame(height: CGFloat) -> some View {
        frame(width: 720, height: height)
    }
}

// MARK: - Shared rows

/// A row with a title (and optional explanation), a numeric field, a unit and a stepper —
/// the System Settings pattern for "Buffer size: [150] MB [⌃⌄]".
struct SettingsNumberRow: View {
    let title: String
    var subtitle: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var unit: String

    var body: some View {
        let clamped = Binding<Int>(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
                Stepper(title, value: clamped, in: range, step: step)
                    .labelsHidden()
            }
        } label: {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
    }
}

/// A status row for an external tool (mpv, ffmpeg): green check when found, otherwise an orange
/// warning with the Homebrew command and a Copy button.
struct SettingsToolStatusRow: View {
    let found: Bool
    let foundTitle: String
    var foundDetail: String?
    let missingTitle: String
    let missingDetail: String
    let command: String
    @ViewState private var copied = false

    var body: some View {
        if found {
            LabeledContent {
                EmptyView()
            } label: {
                Label {
                    Text(foundTitle)
                    if let foundDetail { Text(foundDetail) }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        } else {
            LabeledContent {
                Button(copied ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
            } label: {
                Label {
                    Text(missingTitle)
                    Text(missingDetail) + Text(" ") + Text(command).font(.callout.monospaced())
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Explanatory text under a settings section (leading-aligned, like System Settings).
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A rounded keyboard key, as in the Keyboard settings pane.
struct SettingsKeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minWidth: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
    }
}

/// Coloured rounded-square icon for a source kind, like the icons in System Settings.
struct SettingsSourceIcon: View {
    let kind: Source.Kind
    var size: CGFloat = 28
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(dimmed ? AnyShapeStyle(Color.gray.gradient) : AnyShapeStyle(kind.settingsTint.gradient))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: kind.settingsSymbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

extension Source.Kind {
    /// Short badge label.
    var settingsBadge: String {
        switch self {
        case .m3u: "M3U"
        case .xtream: "Xtream"
        case .stalker: "Stalker"
        }
    }

    var settingsSymbol: String {
        switch self {
        case .m3u: "list.bullet.rectangle"
        case .xtream: "server.rack"
        case .stalker: "tv.and.mediabox"
        }
    }

    var settingsTint: Color {
        switch self {
        case .m3u: .blue
        case .xtream: .purple
        case .stalker: .orange
        }
    }
}

/// Relative "5 minutes ago" text that stays fresh.
struct SettingsRelativeDate: View {
    let prefix: String
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(prefix + " " + Self.describe(date, now: context.date))
        }
    }

    static func describe(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}
