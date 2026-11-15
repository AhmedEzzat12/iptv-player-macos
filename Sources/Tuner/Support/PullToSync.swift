import SwiftUI

extension View {
    /// iPhone/iPad: pull down and let go for one action, or keep holding the pull for a moment for another (by default
    /// sync with iCloud, and refresh the playlists from the providers; Settings → Guide & Library). Nothing on the Mac
    /// (Sync Now and the refresh button are in the window).
    func pullToSync() -> some View {
        modifier(PullToSync())
    }
}

/// The system pull-to-refresh fires as soon as its threshold is crossed, so this follows the scroll offset instead.
/// Past `distance`, letting go runs the pull action; staying past it for `pullHoldSeconds` arms the hold action, so a
/// quick, deep pull no longer refreshes every playlist by accident. Pulling back up before letting go cancels.
private struct PullToSync: ViewModifier {
    #if os(iOS)
    @Environment(AppModel.self) private var model
    @ViewState private var pull: CGFloat = 0
    /// The scroll view's own top inset: 0 when the page runs under the status bar (Home's hero).
    @ViewState private var topInset: CGFloat = 1
    @ViewState private var dragging = false
    /// When the pull went past `distance` (the hold is timed from here), and whether the hold has armed.
    @ViewState private var heldSince: Date?
    @ViewState private var holdArmed = false
    @ViewState private var holdTimer: Task<Void, Never>?
    @ViewState private var working: PullAction?

    private static let distance: CGFloat = 80
    /// A little give once past the line, so a finger that sags while holding doesn't restart the hold.
    private static let keepDistance: CGFloat = 60

    func body(content: Content) -> some View {
        content
            // Home's hero runs under the status bar (`ignoresSafeArea`), so the top inset can be 0 there: measure
            // the pull as overscroll past the top, whatever the inset.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, new in topInset = new }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, new in
                pull = max(0, new)
                if dragging { followHold() }
            }
            .onScrollPhaseChange { old, new in
                if new == .interacting {
                    dragging = true
                    resetHold()
                    followHold()
                } else if old == .interacting {
                    dragging = false
                    let action = releaseAction
                    resetHold()
                    if let action { run(action) }
                }
            }
            .overlay(alignment: .top) { hint }
            .sensoryFeedback(.selection, trigger: heldSince != nil)
            .sensoryFeedback(.impact(weight: .medium), trigger: holdArmed) { _, armed in armed }
    }

    // MARK: - Hold

    private var pullAction: PullAction? { available(model.prefs.pullAction) }
    private var holdAction: PullAction? { available(model.prefs.pullHoldAction) }

    /// Nil for "Nothing", and for iCloud while sync is off.
    private func available(_ action: PullAction) -> PullAction? {
        switch action {
        case .nothing: nil
        case .syncICloud: model.cloudSync.isEnabled ? action : nil
        case .refreshPlaylists: action
        }
    }

    /// Starts timing the hold once the pull passes the line; going back above it starts over.
    private func followHold() {
        if heldSince == nil {
            guard pull >= Self.distance else { return }
            heldSince = Date()
            guard holdAction != nil else { return }
            let seconds = max(0.5, model.prefs.pullHoldSeconds)
            holdTimer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, dragging, heldSince != nil else { return }
                withAnimation(.smooth(duration: 0.2)) { holdArmed = true }
            }
        } else if pull < Self.keepDistance {
            resetHold()
        }
    }

    private func resetHold() {
        holdTimer?.cancel()
        holdTimer = nil
        heldSince = nil
        holdArmed = false
    }

    /// What letting go now does: the hold action once armed, the pull action past the line, else nothing.
    private var releaseAction: PullAction? {
        guard heldSince != nil else { return nil }
        return holdArmed ? holdAction : pullAction
    }

    private func run(_ action: PullAction) {
        switch action {
        case .syncICloud: model.cloudSync.syncNow()
        case .refreshPlaylists: model.syncAll()
        case .nothing: return
        }
        withAnimation(.smooth(duration: 0.2)) { working = action }
        Task { @MainActor in
            // Shown while it runs (at least briefly, so the pull is acknowledged).
            try? await Task.sleep(for: .seconds(1.2))
            while action == .syncICloud ? model.cloudSync.isSyncing : model.isSyncing {
                try? await Task.sleep(for: .milliseconds(300))
            }
            withAnimation(.smooth(duration: 0.25)) { if working == action { working = nil } }
        }
    }

    // MARK: - Hint

    @ViewBuilder
    private var hint: some View {
        if let working {
            label(working == .syncICloud ? "Syncing with iCloud…" : "Refreshing playlists…") {
                ProgressView().controlSize(.small)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if dragging, pull > 24, pullAction != nil || holdAction != nil {
            if holdArmed, let holdAction {
                label("Release to \(Self.verb(holdAction))") { icon(holdAction) }
            } else if let heldSince {
                label(pastLineText) {
                    if holdAction != nil {
                        HoldRing(since: heldSince, seconds: max(0.5, model.prefs.pullHoldSeconds))
                    } else if let pullAction {
                        icon(pullAction)
                    }
                }
            } else {
                label(beforeLineText) { Image(systemName: "arrow.down") }
                    .opacity(min(1, Double(pull / Self.distance)))
            }
        }
    }

    private var beforeLineText: String {
        if let pullAction { return "Pull to \(Self.verb(pullAction))" }
        return "Pull and hold to \(Self.verb(holdAction ?? .refreshPlaylists))"
    }

    private var pastLineText: String {
        switch (pullAction, holdAction) {
        case let (pull?, hold?): "Release to \(Self.verb(pull)) · hold to \(Self.verb(hold))"
        case let (pull?, nil): "Release to \(Self.verb(pull))"
        case let (nil, hold?): "Hold to \(Self.verb(hold))"
        case (nil, nil): ""
        }
    }

    private static func verb(_ action: PullAction) -> String {
        switch action {
        case .syncICloud: "sync with iCloud"
        case .refreshPlaylists: "refresh playlists"
        case .nothing: ""
        }
    }

    private func icon(_ action: PullAction) -> some View {
        Image(systemName: action == .syncICloud ? "icloud" : "arrow.clockwise")
            .font(.footnote.weight(.semibold))
    }

    private func label<Icon: View>(_ text: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 8) {
            icon()
            Text(text).font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        // Under the status bar and the top buttons when the page runs up behind them.
        .padding(.top, topInset < 1 ? Self.windowTopInset + 58 : 6)
        .allowsHitTesting(false)
    }

    private static var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets.top ?? 59
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}

#if os(iOS)
/// Fills as the hold time passes.
private struct HoldRing: View {
    let since: Date
    let seconds: Double

    var body: some View {
        TimelineView(.animation) { context in
            let progress = min(1, context.date.timeIntervalSince(since) / seconds)
            ZStack {
                Circle().stroke(.secondary.opacity(0.35), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        }
    }
}
#endif
