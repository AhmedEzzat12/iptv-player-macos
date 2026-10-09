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
    @ViewState private var seekFeedback: SeekFeedback?
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
                PlayerSeekFeedbackView(feedback: seekFeedback, size: size)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .task(id: seekFeedback.token) {
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        withAnimation(.smooth(duration: 0.3)) { self.seekFeedback = nil }
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
            // Repeated double taps on the same side add up ("20 seconds", "30 seconds"…), as on YouTube.
            let streak = seekFeedback.map { $0.side == side ? $0.seconds + 10 : 10 } ?? 10
            withAnimation(.smooth(duration: 0.2)) {
                seekFeedback = SeekFeedback(side: side, seconds: streak, location: location,
                                            token: (seekFeedback?.token ?? 0) + 1)
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

    #endif
}

#if !os(macOS)
/// One double-tap seek: which side, the running total, where the finger was.
struct SeekFeedback: Equatable {
    let side: Int
    let seconds: Int
    let location: CGPoint
    let token: Int
}

/// Double-tap seek feedback: the tapped side lights up as a rounded half-pane, a ripple spreads from the finger,
/// and chevrons sweep in the seek direction above the running total.
private struct PlayerSeekFeedbackView: View {
    let feedback: SeekFeedback
    let size: CGSize

    var body: some View {
        let forward = feedback.side > 0
        let paneWidth = size.width * 0.42
        ZStack {
            // The lit half-pane, curved on its inner edge.
            Ellipse()
                .fill(Color.white.opacity(0.13))
                .frame(width: paneWidth * 2, height: size.height * 1.5)
                .position(x: forward ? size.width + paneWidth * 0.35 : -paneWidth * 0.35, y: size.height / 2)

            PlayerSeekRipple()
                .id(feedback.token)
                .position(feedback.location)

            VStack(spacing: 8) {
                PhaseAnimator([0, 1, 2, 3]) { phase in
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { index in
                            let lit = forward ? index == phase : 2 - index == phase
                            Image(systemName: forward ? "arrowtriangle.forward.fill" : "arrowtriangle.backward.fill")
                                .font(.system(size: 13, weight: .bold))
                                .opacity(lit ? 1 : 0.35)
                        }
                    }
                } animation: { _ in .easeInOut(duration: 0.16) }
                Text("\(feedback.seconds) seconds")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(feedback.seconds)))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 4)
            .position(x: forward ? size.width - paneWidth * 0.45 : paneWidth * 0.45, y: size.height / 2)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// A soft circle that grows and fades from the finger (a new one for every tap).
private struct PlayerSeekRipple: View {
    @ViewState private var expanded = false

    var body: some View {
        Circle()
            .fill(Color.white.opacity(expanded ? 0 : 0.28))
            .frame(width: 180, height: 180)
            .scaleEffect(expanded ? 1.6 : 0.2)
            .onAppear {
                withAnimation(.easeOut(duration: 0.55)) { expanded = true }
            }
    }
}
#endif
