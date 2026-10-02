import AppKit
import SwiftUI
import TunerCore

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
        case .liveTV, .favorites, .recent, .group: LiveTVView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var newGroupName = ""
    @ViewState private var showNewGroup = false
    @ViewState private var renaming: CustomGroup?
    @ViewState private var renameText = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            Label("Live TV", systemImage: "dot.radiowaves.left.and.right").tag(SidebarItem.liveTV)
            Label("Movies", systemImage: "film").tag(SidebarItem.movies)
            Label("TV Shows", systemImage: "tv").tag(SidebarItem.series)
            Label("Recordings", systemImage: "record.circle").tag(SidebarItem.recordings)

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

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.banners) { banner in
                HStack(spacing: 12) {
                    Image(systemName: banner.symbol)
                        .font(.title3)
                        .foregroundStyle(banner.isError ? Color.orange : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title).font(.callout.weight(.semibold))
                        if let m = banner.message { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                    Spacer(minLength: 8)
                    if let title = banner.actionTitle, let action = banner.action {
                        Button(title) {
                            action()
                            model.dismissBanner(banner.id)
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                    Button { model.dismissBanner(banner.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 460)
                .tunerGlass(cornerRadius: 18)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35), value: model.banners)
    }
}

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
