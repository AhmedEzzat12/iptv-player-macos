#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore
import UniformTypeIdentifiers

/// First-run onboarding, shown in Home / Live TV while there are no sources.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tunerCompact) private var compact

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background { WelcomeBackdrop() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            hero
                .padding(.bottom, 36)

            if compact {
                VStack(spacing: 12) { optionCards }
                    .padding(.bottom, 24)
                VStack(spacing: 12) { fileButtons }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .padding(.bottom, 24)
            } else {
                HStack(spacing: 16) { optionCards }
                    .padding(.bottom, 28)
                HStack(spacing: 12) { fileButtons }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .padding(.bottom, 28)
            }

            Text("Tuner doesn't provide any channels — add a playlist from your provider.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, compact ? 20 : 40)
        .padding(.vertical, compact ? 32 : 48)
    }

    @ViewBuilder
    private var optionCards: some View {
        ForEach(WelcomeOption.all) { option in
            WelcomeOptionCard(option: option, compact: compact) {
                model.sourceEditor = SourceEditorRequest(source: nil, kind: option.kind)
            }
        }
    }

    @ViewBuilder
    private var fileButtons: some View {
        Button(action: openFile) {
            Label("Open M3U File…", systemImage: "doc")
        }
        Button(action: addFreeChannels) {
            Label("Try Free Channels", systemImage: "sparkles.tv")
        }
        .help("Adds the free, public iptv-org playlist of US channels")
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.tv")
                .font(.system(size: 76, weight: .regular))
                .foregroundStyle(
                    LinearGradient(colors: [model.prefs.accent.color, AccentTheme.purple.color, AccentTheme.crimson.color],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .symbolRenderingMode(.hierarchical)
                .shadow(color: model.prefs.accent.color.opacity(0.35), radius: 24)
                .padding(.bottom, 6)
            Text("Welcome to Tuner")
                .font(.largeTitle.weight(.bold))
            Text("Live TV, movies and shows from your IPTV provider, all in one place.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Playlist"
        panel.message = "Choose an M3U playlist file."
        panel.allowedContentTypes = [UTType.m3uPlaylist, UTType(filenameExtension: "m3u8"), UTType.plainText].compactMap { $0 }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.addSource(Source(name: url.deletingPathExtension().lastPathComponent, kind: .m3u, url: url.absoluteString))
        }
        if let window = model.mainWindow ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private func addFreeChannels() {
        model.addSource(Source(name: "Free TV (iptv-org)", kind: .m3u, url: "https://iptv-org.github.io/iptv/countries/us.m3u"))
    }
}

private struct WelcomeOption: Identifiable {
    let kind: Source.Kind
    let symbol: String
    let title: String
    let detail: String
    var id: Source.Kind { kind }

    static let all: [WelcomeOption] = [
        WelcomeOption(kind: .m3u, symbol: "list.bullet.rectangle.portrait", title: "M3U Playlist",
                      detail: "Add a playlist link from your provider."),
        WelcomeOption(kind: .xtream, symbol: "server.rack", title: "Xtream Codes",
                      detail: "Sign in with a server, username and password."),
        WelcomeOption(kind: .stalker, symbol: "tv.and.mediabox", title: "Stalker Portal",
                      detail: "Connect a MAG portal with your MAC address."),
    ]
}

private struct WelcomeOptionCard: View {
    let option: WelcomeOption
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(option.kind.settingsTint.gradient)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: option.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.bottom, 18)
                Text(option.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 4)
                Text(option.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(width: compact ? nil : 210, height: compact ? nil : 196, alignment: .topLeading)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.03)
        .accessibilityLabel(option.title)
        .accessibilityHint(option.detail)
    }
}

/// Soft colour wash behind the hero, like the TV app's onboarding.
private struct WelcomeBackdrop: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [model.prefs.accent.color.opacity(0.22), .clear],
                           center: UnitPoint(x: 0.3, y: 0.15), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [AccentTheme.purple.color.opacity(0.18), .clear],
                           center: UnitPoint(x: 0.75, y: 0.3), startRadius: 0, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}
