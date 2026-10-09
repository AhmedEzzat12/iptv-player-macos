import SwiftUI
import TunerCore

// Pieces of the iPhone player (`tunerCompact`; laid out by PlayerPhoneChrome). Never used on the Mac.

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
                .buttonStyle(PlayerGlassButtonStyle(size: 76))
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
        .buttonStyle(PlayerGlassButtonStyle(size: 58))
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

