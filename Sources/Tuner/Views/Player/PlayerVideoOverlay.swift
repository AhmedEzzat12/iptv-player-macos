import SwiftUI
import TunerCore

/// Interaction and status above the full-window video. The video itself is drawn underneath by `PlayerHost`; this
/// layer handles clicks/taps (toggle the chrome; double-click: window full screen on the Mac; double tap on the left
/// or right third: seek on touch screens) and shows the status cards (buffering, errors).
struct PlayerVideoOverlay: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let size: CGSize
    /// Area covered by the chrome (top bar, control panel); status cards stay out of it.
    var statusInsets = EdgeInsets()
    let chrome: PlayerChromeController
    let onClose: () -> Void
    #if !os(macOS)
    /// Touch: the previous tap (for YouTube-style double tap to seek) and the seek indicator.
    @ViewState private var lastTap: (date: Date, side: Int)?
    /// An edge tap's show/hide, held back briefly in case a second tap makes it a seek.
    @ViewState private var pendingTap: Task<Void, Never>?
    @ViewState private var seekFeedback: (side: Int, token: Int)?
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            #if os(macOS)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.toggleWindowFullScreen() }
                .onTapGesture { tapped() }
            #else
            // Touch: no double-tap recognizer (it would hold every single tap ~0.3 s); taps are handled at once and
            // a quick second tap on the left/right third seeks instead (YouTube).
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in touchTapped(at: value.location) })
            if let seekFeedback {
                seekIndicator(side: seekFeedback.side)
                    .id(seekFeedback.token)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .task(id: seekFeedback.token) {
                        try? await Task.sleep(for: .milliseconds(650))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.2)) { self.seekFeedback = nil }
                    }
            }
            #endif

            if slot.item != nil {
                let statusHeight = max(0, size.height - statusInsets.top - statusInsets.bottom)
                PlayerStatusOverlay(slot: slot, size: CGSize(width: size.width, height: statusHeight), onClose: onClose)
                    .padding(.top, statusInsets.top)
                    .padding(.bottom, statusInsets.bottom)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(slot.item?.title ?? "Player")
    }

    /// Click/tap on the video: closes the episode list first (like clicking outside a popover), else toggles the chrome.
    private func tapped() {
        if model.player.isEpisodeListOpen {
            withAnimation(.smooth(duration: 0.3)) { model.player.isEpisodeListOpen = false }
        } else {
            chrome.toggle()
        }
    }

    #if !os(macOS)
    /// How long an edge tap waits for a second tap (iOS's own double-tap interval is about this).
    private static let doubleTapWindow: Duration = .milliseconds(250)

    /// YouTube-style: a tap in the middle shows/hides the controls at once. A tap on the left/right third waits a
    /// moment: a second tap there seeks −10/+10 s instead (the controls stay as they were, so the second tap can't
    /// land on a just-shown button), and further quick taps keep seeking.
    private func touchTapped(at location: CGPoint) {
        let side = location.x < size.width / 3 ? -1 : (location.x > size.width * 2 / 3 ? 1 : 0)
        let now = Date()
        let canSeek = side != 0 && slot.canSeek && slot.item?.isLive == false && !model.player.isEpisodeListOpen
        defer { lastTap = (now, side) }

        if canSeek, let last = lastTap, last.side == side, now.timeIntervalSince(last.date) < 0.35 {
            pendingTap?.cancel()
            pendingTap = nil
            slot.seek(by: Double(side) * 10)
            withAnimation(.easeOut(duration: 0.12)) {
                seekFeedback = (side, (seekFeedback?.token ?? 0) + 1)
            }
            return
        }
        pendingTap?.cancel()
        guard canSeek else {
            pendingTap = nil
            tapped()
            return
        }
        pendingTap = Task { @MainActor in
            try? await Task.sleep(for: Self.doubleTapWindow)
            guard !Task.isCancelled else { return }
            pendingTap = nil
            tapped()
        }
    }

    private func seekIndicator(side: Int) -> some View {
        HStack {
            if side > 0 { Spacer() }
            Image(systemName: side < 0 ? "gobackward.10" : "goforward.10")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.black.opacity(0.35), in: Circle())
                .padding(.horizontal, size.width * 0.12)
            if side < 0 { Spacer() }
        }
        .frame(maxHeight: .infinity)
    }
    #endif
}
