#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

#if os(macOS)
// (iOS: iOS/Sources/App/MobileRootView.swift)
/// Window root: native sidebar + section content, with the persistent player layered in the detail column.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            DetailRoot()
        }
        // The player sits above the whole split view: NavigationSplitView columns and NavigationStack
        // destinations are separate AppKit hosting views that would otherwise cover it.
        .overlay {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                PlayerHost(previewRect: model.player.previewFrameInWindow.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) },
                           containerSize: proxy.size)
            }
        }
        // Banners must sit above the full-window player, which covers the content column they normally top.
        .overlay(alignment: .top) {
            if model.player.isFullWindow { BannerStack().padding(.top, 16) }
        }
        // In-app trailers sit above everything, the player and banners included.
        .overlay { TrailerOverlay() }
        .background(WindowAccessor { model.mainWindow = $0 })
        .onChange(of: model.player.isFullWindow) { _, full in
            withAnimation(.smooth(duration: 0.35)) { columnVisibility = full ? .detailOnly : .all }
        }
        .toolbar(model.player.isFullWindow ? .hidden : .automatic, for: .windowToolbar)
        .sheet(item: $model.sourceEditor) { request in
            SourceEditorView(request: request).environment(model)
        }
        .sheet(isPresented: $model.showShortcutHelp) { ShortcutHelpView().environment(model) }
        .task { await model.start() }
        .preferredColorScheme(model.prefs.followSystemAppearance ? nil : .dark)
        .tint(model.prefs.accent.color)
    }
}
#endif

/// Section content (the player is layered above the whole split view by `RootView`).
struct DetailRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        sectionContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if !model.player.isFullWindow { BannerStack().padding(.top, 12) }
            }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.sidebarSelection ?? .home {
        case .home: HomeView()
        case .search: SearchView()
        case .movies: MoviesView()
        case .series: SeriesView()
        case .recordings: RecordingsView()
        case .downloads: DownloadsView()
        case .liveTV, .favorites, .recent, .group: LiveTVView()
        }
    }
}

// MARK: - Sidebar

private extension View {
    /// Clicking the row of the section that's already open takes it back to its top page (closes a movie or show
    /// page). The List doesn't report a click on the selected row, so a tap across the row's full width catches it;
    /// the tap ends before the selection changes, so a click that switches sections doesn't count.
    func reselects(_ item: SidebarItem) -> some View {
        modifier(SidebarReselect(item: item))
    }
}

private struct SidebarReselect: ViewModifier {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                if model.sidebarSelection == item { model.showSection(item) }
            })
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var newGroupName = ""
    @ViewState private var showNewGroup = false
    @ViewState private var renaming: CustomGroup?
    @ViewState private var renameText = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("Search", systemImage: "magnifyingglass").reselects(.search).tag(SidebarItem.search)
            Label("Home", systemImage: "house").reselects(.home).tag(SidebarItem.home)
            Label("Live TV", systemImage: "dot.radiowaves.left.and.right").reselects(.liveTV).tag(SidebarItem.liveTV)
            Label("Movies", systemImage: "film").reselects(.movies).tag(SidebarItem.movies)
            Label("TV Shows", systemImage: "tv").reselects(.series).tag(SidebarItem.series)
            if Distribution.supportsRecording {
                Label("Recordings", systemImage: "record.circle").reselects(.recordings).tag(SidebarItem.recordings)
            }
            // The tag has to be the outermost modifier: after .badge the List can't see it and the row won't select.
            Label("Downloads", systemImage: "arrow.down.circle")
                .reselects(.downloads)
                .badge(model.activeDownloadCount)
                .tag(SidebarItem.downloads)

            Section {
                Label("Favorites", systemImage: "star").tag(SidebarItem.favorites)
                Label("Recently Watched", systemImage: "clock.arrow.circlepath").tag(SidebarItem.recent)
                ForEach(model.customGroups) { group in
                    Label(group.name, systemImage: "folder").tag(SidebarItem.group(group.id))
                        .contextMenu {
                            Button("Rename…") { renameText = group.name; renaming = group }
                            Button("Delete Group", role: .destructive) { model.deleteGroup(group) }
                        }
                }
            } header: {
                HStack {
                    Text("Channels")
                    Spacer()
                    Button { showNewGroup = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New channel group")
                        // The header spans the whole sidebar; without this the button sat past the rows' edge.
                        .padding(.trailing, 8)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
        .alert("New Group", isPresented: $showNewGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.createGroup(named: name) }
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        } message: {
            Text("Collect channels from any playlist. Right-click a channel to add it.")
        }
        .alert("Rename Group", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let g = renaming, !renameText.isEmpty { model.renameGroup(g, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let event = model.activeSyncs.values.first {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.sourceName).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(syncLabel(event)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button {
                    model.sourceEditor = SourceEditorRequest(source: nil, kind: .m3u)
                } label: {
                    Label("Add Playlist", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                Spacer()
                if model.hasSources {
                    Button { model.syncAll() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(model.isSyncing)
                        .help("Refresh all playlists and guides")
                }
            }
        }
        .padding(12)
    }

    private func syncLabel(_ e: SyncEvent) -> String {
        switch e.phase {
        case .started: "Connecting…"
        case .channels: "Updating channels…"
        case .vod: "Updating movies & shows…"
        case .guide: "Updating guide…"
        default: "Refreshing…"
        }
    }
}

// MARK: - Banners

struct BannerStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tunerCompact) private var compact

    var body: some View {
        // iPhone: only the newest, edge to edge like the system's banners (three stacked would cover the screen);
        // the one before it comes back if it's still due when the newest goes.
        let banners = compact ? Array(model.banners.suffix(1)) : model.banners
        VStack(spacing: 8) {
            ForEach(banners) { banner in
                BannerCard(banner: banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, compact ? 10 : 0)
        .animation(.spring(response: 0.35), value: model.banners)
        .sensoryFeedback(.warning, trigger: banners.last?.id) { _, _ in compact && banners.last?.isError == true }
    }
}

/// Glass, except on iPhone: there the banner covers the top bar's glass buttons, and glass on glass shows them
/// through it (and melts into them), so it gets a thick material instead.
private struct BannerBackground: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content.background(.thickMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            content.tunerGlass(cornerRadius: 18)
        }
    }
}

/// One banner. On touch screens it goes with a swipe up, as the system's do (iPhone drops the close button).
private struct BannerCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tunerCompact) private var compact
    let banner: Banner
    @ViewState private var drag: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.symbol)
                .font(compact ? .title2 : .title3)
                .foregroundStyle(banner.isError ? Color.orange : Color.accentColor)
                .frame(width: compact ? 32 : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(compact ? .subheadline.weight(.semibold) : .callout.weight(.semibold))
                    .lineLimit(2)
                if let m = banner.message {
                    Text(m).font(compact ? .footnote : .caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let title = banner.actionTitle, let action = banner.action {
                Button(title) {
                    action()
                    model.dismissBanner(banner.id)
                }
                .buttonStyle(GlassButtonStyle())
            }
            if !compact {
                Button { model.dismissBanner(banner.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 14 : 12)
        .frame(maxWidth: compact ? 520 : 460)
        .modifier(BannerBackground(compact: compact))
        .contentShape(.rect(cornerRadius: compact ? 24 : 18))
        .offset(y: drag)
        .gesture(swipeUp, isEnabled: TouchScreen.isAvailable)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Dismiss") { model.dismissBanner(banner.id) }
    }

    /// Follows the finger upwards (and only a little downwards); far or fast enough up dismisses it.
    private var swipeUp: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let y = value.translation.height
                drag = y < 0 ? y : y / 6
            }
            .onEnded { value in
                if value.translation.height < -24 || value.predictedEndTranslation.height < -80 {
                    model.dismissBanner(banner.id)
                } else {
                    withAnimation(.spring(response: 0.3)) { drag = 0 }
                }
            }
    }
}

#if os(macOS)
// MARK: - Window access

/// Captures the hosting NSWindow (for full screen toggling and keyboard routing).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
#endif
