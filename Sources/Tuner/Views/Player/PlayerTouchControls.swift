import SwiftUI
import TunerCore

// Player controls for narrow touch screens (iPhone; `tunerCompact`). The Mac's single control row doesn't fit a
// phone, so, as in the TV app on iPhone: the transport sits large in the middle of the video, rarely used settings
// move into one "…" menu in the top bar, and the bottom card keeps the title, the timeline and one quiet row.
// Hardware buttons set the volume, so there's no volume control. Never used on the Mac.

/// −10 s / play-pause / +10 s (live: previous channel / play-pause / next channel), centred on the video.
struct PlayerCenterTransport: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let chrome: PlayerChromeController

    var body: some View {
        if let item = slot.item {
            HStack(spacing: 44) {
                if item.isLive {
                    button("chevron.up", label: "Previous Channel", enabled: !model.zapList.isEmpty) { model.channelUp() }
                } else {
                    button("gobackward.10", label: "Back 10 Seconds", enabled: slot.canSeek) { slot.seek(by: -10) }
                }

                Button {
                    if isFailed { slot.retry() } else { slot.togglePause() }
                    chrome.touch()
                } label: {
                    Image(systemName: playSymbol)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PlayerGlassButtonStyle(size: 72))
                .accessibilityLabel(playTitle)

                if item.isLive {
                    button("chevron.down", label: "Next Channel", enabled: !model.zapList.isEmpty) { model.channelDown() }
                } else {
                    button("goforward.10", label: "Forward 10 Seconds", enabled: slot.canSeek) { slot.seek(by: 10) }
                }
            }
            .foregroundStyle(.white)
        }
    }

    private func button(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            chrome.touch()
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(PlayerTransportButtonStyle(size: 56, iconSize: 28))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var isFailed: Bool {
        if case .failed = slot.phase { return true }
        return false
    }

    private var playSymbol: String {
        isFailed ? "arrow.clockwise" : (slot.phase == .ended ? "arrow.counterclockwise" : (slot.phase == .paused ? "play.fill" : "pause.fill"))
    }

    private var playTitle: String {
        isFailed ? "Try Again" : (slot.phase == .ended ? "Replay" : (slot.phase == .paused ? "Play" : "Pause"))
    }
}

/// The bottom card's button row: Audio & Subtitles, Episodes · Next Episode, Full Screen.
struct PlayerTouchControlRow: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    /// Compact height = an iPhone in landscape.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    let slot: PlayerSlot
    let chrome: PlayerChromeController

    private var isEpisode: Bool { model.currentEpisode != nil && slot === model.player.main }

    var body: some View {
        let size: CGFloat = 38
        HStack(spacing: 10) {
            PlayerTracksMenu(slot: slot, size: size)
            if isEpisode {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { model.player.isEpisodeListOpen.toggle() }
                    chrome.touch()
                } label: {
                    PlayerGlassSymbol(symbol: model.player.isEpisodeListOpen ? "rectangle.stack.fill" : "rectangle.stack", size: size)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Episodes")
            }
            Spacer(minLength: 0)
            if isEpisode {
                let next = model.adjacentEpisode(1)
                Button {
                    model.playAdjacentEpisode(1)
                    chrome.touch()
                } label: {
                    Label("Next Episode", systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: size)
                        .playerGlass(in: Capsule(), interactive: true)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(next == nil)
                .opacity(next == nil ? 0.45 : 1)
            }
            #if os(iOS)
            // Full screen = landscape, as in YouTube; the same button (or swiping down) goes back.
            Button {
                PlayerOrientation.toggle()
                chrome.touch()
            } label: {
                PlayerGlassSymbol(symbol: verticalSizeClass == .compact ? "arrow.down.right.and.arrow.up.left"
                                                                        : "arrow.up.left.and.arrow.down.right", size: size)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(verticalSizeClass == .compact ? "Exit Full Screen" : "Full Screen")
            #endif
        }
    }
}

/// "…" in the top bar: playback speed, aspect ratio and statistics.
struct PlayerMoreMenu: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    private static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        @Bindable var slot = slot
        @Bindable var player = model.player
        Menu {
            if slot.item?.isLive == false {
                Picker(selection: $slot.rate) {
                    ForEach(Self.rates, id: \.self) { rate in Text(PlayerSpeedMenu.label(rate)).tag(rate) }
                } label: {
                    Label("Playback Speed", systemImage: "gauge.with.dots.needle.67percent")
                }
                .pickerStyle(.menu)
            }
            Picker(selection: $slot.aspect) {
                ForEach(VideoAspect.allCases) { aspect in Text(aspect.title).tag(aspect) }
            } label: {
                Label("Aspect Ratio", systemImage: "aspectratio")
            }
            .pickerStyle(.menu)
            Divider()
            Toggle(isOn: $player.showStats) {
                Label("Playback Statistics", systemImage: "info.circle")
            }
        } label: {
            PlayerGlassSymbol(symbol: "ellipsis", size: 40)
        }
        .playerMenuStyle()
        .accessibilityLabel("More")
    }
}
