import SwiftUI
import TunerCore

/// Hover controls and status for the main slot when it isn't full window: inside the guide's preview
/// slot (`.preview`) or as the floating mini player (`.mini`). Double-click opens the full player.
/// Sized exactly to the video rect, so nothing outside it intercepts clicks.
struct PlayerCompactControls: View {
    enum Style {
        case preview
        case mini
    }

    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let style: Style
    let size: CGSize
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style == .mini ? 14 : 12, style: .continuous)
        ZStack {
            Color.clear
                .contentShape(shape)
                .onTapGesture(count: 2) { model.enterFullWindow() }

            PlayerStatusOverlay(slot: slot, size: size, onClose: { model.stopPlayback() })

            Group {
                switch style {
                case .preview: previewControls
                case .mini: miniControls
                }
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .onHover { inside in withAnimation(.easeInOut(duration: 0.2)) { hovering = inside } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(slot.item?.title ?? "Player")
    }

    private var isPaused: Bool { slot.phase == .paused || slot.phase == .ended }

    private var playPauseSymbol: String {
        switch slot.phase {
        case .ended: "arrow.counterclockwise"
        case .paused: "play.fill"
        default: "pause.fill"
        }
    }

    private var muteSymbol: String {
        PlayerVolumeControl.symbol(for: slot.isMuted ? 0 : slot.volume)
    }

    // MARK: Preview (guide)

    private var previewControls: some View {
        let small = size.width < 300
        let button: CGFloat = small ? 26 : 30
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { slot.togglePause() } label: { Image(systemName: playPauseSymbol) }
                    .buttonStyle(PlayerGlassButtonStyle(size: button))
                    .help(isPaused ? "Play" : "Pause")
                Button { slot.isMuted.toggle() } label: { Image(systemName: muteSymbol) }
                    .buttonStyle(PlayerGlassButtonStyle(size: button))
                    .help(slot.isMuted ? "Unmute" : "Mute")
                if !small, slot.item?.isLive == true { PlayerLivePill() }
                Spacer(minLength: 4)
                Button { model.enterFullWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(PlayerGlassButtonStyle(size: button))
                    .help("Full Window (Return)")
            }
            .padding(10)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(size.height, 90))
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: Mini player

    private var miniControls: some View {
        let item = slot.item
        let subtitle = item?.isLive == true ? slot.currentProgram?.title : item?.subtitle
        let showsCenterButton = [PlayerSlot.Phase.playing, .paused].contains(slot.phase)
        // Failure/end cards carry their own buttons; keep only close/expand so nothing overlaps them.
        let showsCard: Bool = {
            switch slot.phase {
            case .failed, .ended: true
            default: false
            }
        }()
        return ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .black.opacity(0.1), location: 0.4),
                .init(color: .black.opacity(0.1), location: 0.55),
                .init(color: .black.opacity(0.7), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    Button { model.stopPlayback() } label: { Image(systemName: "xmark") }
                        .buttonStyle(PlayerGlassButtonStyle(size: 28))
                        .help("Stop (⌘.)")
                    Spacer()
                    Button { model.enterFullWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(PlayerGlassButtonStyle(size: 28))
                        .help("Open Player (Return)")
                }
                Spacer(minLength: 0)
                if !showsCard {
                    HStack(alignment: .bottom, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                if item?.isLive == true { PlayerLivePill() }
                                Text(item?.title ?? "")
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                            }
                            if let subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Button { slot.isMuted.toggle() } label: { Image(systemName: muteSymbol) }
                            .buttonStyle(PlayerGlassButtonStyle(size: 28))
                            .help(slot.isMuted ? "Unmute" : "Mute")
                    }
                }
            }
            .padding(10)

            if showsCenterButton {
                Button { slot.togglePause() } label: {
                    Image(systemName: playPauseSymbol).contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PlayerGlassButtonStyle(size: 46))
                .help(isPaused ? "Play" : "Pause")
            }
        }
        .foregroundStyle(.white)
    }
}
