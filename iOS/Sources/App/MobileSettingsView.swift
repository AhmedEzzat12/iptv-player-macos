import SwiftUI
import TunerCore

/// Settings on iPhone/iPad: the Mac's Settings panes (shared Forms) behind a navigation list, like the
/// Settings app. Recording isn't offered: iOS apps can't run the ffmpeg recorder.
struct MobileSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Playlists", "play.square.stack", .blue) { SettingsPlaylistsPane() }
                }
                Section {
                    row("Playback", "play.rectangle", .orange) { SettingsPlaybackPane() }
                    row("Guide & Library", "calendar", .red) { SettingsGuidePane() }
                    row("Metadata", "text.below.photo", .purple) { SettingsMetadataPane() }
                    row("Downloads", "arrow.down.circle", .green) { SettingsDownloadsPane() }
                    row("AI", "sparkles", .indigo) { SettingsAIPane() }
                    row("Appearance", "paintpalette", .pink) { SettingsAppearancePane() }
                }
                Section {
                    row("Keyboard Shortcuts", "keyboard", .gray) { SettingsShortcutsPane() }
                    row("About", "info.circle", .gray) { SettingsAboutPane() }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row<Destination: View>(_ title: String, _ symbol: String, _ tint: Color,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
                .environment(model)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}
