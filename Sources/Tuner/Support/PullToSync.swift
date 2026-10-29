import SwiftUI

extension View {
    /// iPhone/iPad: pull down and let go to sync with iCloud now; pull further to refresh the playlists from the
    /// providers. Nothing on the Mac (Sync Now and the refresh button are in the window).
    func pullToSync() -> some View {
        modifier(PullToSync())
    }
}

/// The system pull-to-refresh fires as soon as its threshold is crossed (before a longer pull can be told apart),
/// so this follows the scroll offset and decides on release, from how far the list was pulled.
private struct PullToSync: ViewModifier {
    #if os(iOS)
    @Environment(AppModel.self) private var model
    @ViewState private var pull: CGFloat = 0
    /// The scroll view's own top inset: 0 when the page runs under the status bar (Home's hero).
    @ViewState private var topInset: CGFloat = 1
    @ViewState private var maxPull: CGFloat = 0
    @ViewState private var dragging = false
    @ViewState private var working: Action?

    private static let syncDistance: CGFloat = 80
    private static let refreshDistance: CGFloat = 170

    private enum Action: Equatable {
        case sync, refresh
    }

    func body(content: Content) -> some View {
        content
            // Home's hero runs under the status bar (`ignoresSafeArea`), so the top inset can be 0 there: measure
            // the pull as overscroll past the top, whatever the inset.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, new in topInset = new }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, new in
                pull = max(0, new)
                if dragging { maxPull = max(maxPull, pull) }
            }
            .onScrollPhaseChange { old, new in
                if new == .interacting {
                    dragging = true
                    maxPull = pull
                } else if old == .interacting {
                    dragging = false
                    let action = action(for: maxPull)
                    maxPull = 0
                    if let action { run(action) }
                }
            }
            .overlay(alignment: .top) { hint }
            .sensoryFeedback(.selection, trigger: dragging ? action(for: maxPull) : nil)
    }

    /// What letting go now would do.
    private func action(for distance: CGFloat) -> Action? {
        if distance >= Self.refreshDistance { return .refresh }
        if distance >= Self.syncDistance, model.cloudSync.isEnabled { return .sync }
        return nil
    }

    private func run(_ action: Action) {
        switch action {
        case .sync: model.cloudSync.syncNow()
        case .refresh: model.syncAll()
        }
        withAnimation(.smooth(duration: 0.2)) { working = action }
        Task { @MainActor in
            // Shown while it runs (at least briefly, so the pull is acknowledged).
            try? await Task.sleep(for: .seconds(1.2))
            while action == .sync ? model.cloudSync.isSyncing : model.isSyncing {
                try? await Task.sleep(for: .milliseconds(300))
            }
            withAnimation(.smooth(duration: 0.25)) { if working == action { working = nil } }
        }
    }

    @ViewBuilder
    private var hint: some View {
        if let working {
            label(working == .sync ? "Syncing with iCloud…" : "Refreshing playlists…", symbol: nil)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else if dragging, pull > 24 {
            let syncOn = model.cloudSync.isEnabled
            switch action(for: maxPull) {
            case .refresh:
                label("Release to refresh playlists", symbol: "arrow.clockwise")
            case .sync:
                label("Release to sync · pull more to refresh playlists", symbol: "icloud")
            case nil:
                label(syncOn ? "Pull to sync with iCloud" : "Pull more to refresh playlists",
                      symbol: syncOn ? "icloud" : "arrow.down")
                    .opacity(min(1, Double(pull / Self.syncDistance)))
            }
        }
    }

    private func label(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.footnote.weight(.semibold))
            } else {
                ProgressView().controlSize(.small)
            }
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
