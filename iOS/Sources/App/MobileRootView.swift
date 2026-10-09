import SwiftUI
import TunerCore

/// iPhone/iPad root: Apple TV app–style tabs (a bottom tab bar on iPhone, a sidebar-adaptable top bar on iPad),
/// with the persistent player layered above everything.
struct MobileRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewState private var showSettings = false

    /// iPhone layout: always on a phone (a Pro Max in landscape reports a regular width, which would otherwise
    /// swap the player for the iPad/Mac panel and turn its gestures off), and on narrow iPad windows.
    private var phoneLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || sizeClass == .compact
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: tabSelection) {
            Tab("Home", systemImage: "house", value: SidebarItem.home) {
                // The hero's artwork runs up under the status bar, as in the TV app.
                // (Only once there's a library: the Welcome screen keeps clear of the status bar.)
                section { HomeView().ignoresSafeArea(edges: model.hasSources ? .top : []) }
            }
            Tab("Live TV", systemImage: "dot.radiowaves.left.and.right", value: SidebarItem.liveTV) {
                section { LiveTVView() }
            }
            Tab("Movies", systemImage: "film", value: SidebarItem.movies) {
                section { MoviesView() }
            }
            Tab("TV Shows", systemImage: "tv", value: SidebarItem.series) {
                section { SeriesView() }
            }
            // iPad only; on iPhone, Downloads is a button in the top bar (a sixth tab would turn into "More").
            if !phoneLayout {
                Tab("Downloads", systemImage: "arrow.down.circle", value: SidebarItem.downloads) {
                    section { DownloadsView() }
                }
                .badge(model.activeDownloadCount)
            }
            Tab(value: SidebarItem.search, role: .search) {
                // SearchView brings its own NavigationStack (a second one around it would nest stacks).
                SearchView()
            }
        }
        // iPad: a top tab bar that can open as a sidebar. iPhone: a plain tab bar (the adaptable style left a
        // sidebar handle on the screen's left edge).
        .modifier(TabStyleForWidth(compact: phoneLayout))
        // The persistent player sits above the tabs (one engine view per slot, moved between presentations).
        .overlay {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                PlayerHost(previewRect: model.player.previewFrameInWindow.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) },
                           containerSize: proxy.size)
            }
        }
        .overlay(alignment: .top) { BannerStack().padding(.top, 8) }
        .overlay { TrailerOverlay() }
        .environment(\.tunerCompact, phoneLayout)
        // While Settings is up, it presents the source editor itself (a second sheet can't stack from here).
        .sheet(item: showSettings ? .constant(nil) : $model.sourceEditor) { request in
            SourceEditorView(request: request).environment(model)
        }
        .sheet(isPresented: $showSettings) {
            MobileSettingsView()
                .environment(model)
                .sheet(item: $model.sourceEditor) { request in
                    SourceEditorView(request: request).environment(model)
                }
        }
        // iPhone: the full-screen player follows rotation (and the full-screen button); browsing stays portrait.
        .onChange(of: model.player.isFullWindow) { _, full in
            if full { PlayerOrientation.playerOpened() } else { PlayerOrientation.playerClosed() }
        }
        .task { await model.start() }
        #if DEBUG
        .task { await DebugLaunch.run(model) }
        #endif
    }

    /// A tab's root: its own navigation stack, with Settings in the top bar.
    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // The screens draw their own headers; an empty title view keeps the bar clear.
                    ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                    if phoneLayout {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                DownloadsView().navigationBarTitleDisplayMode(.inline)
                            } label: {
                                Image(systemName: model.activeDownloadCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                            }
                            .accessibilityLabel("Downloads")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
        // Heroes (Home, movie and show pages) run up under the bar; no dimming band over their artwork.
        .scrollEdgeEffectHidden(true, for: .top)
    }

    /// The model keeps the Mac's sidebar selection; tabs map onto the same destinations.
    private var tabSelection: Binding<SidebarItem> {
        Binding(get: {
            let item = model.sidebarSelection ?? .home
            return item.showsLiveTV ? .liveTV : item
        }, set: { item in
            // Tapping Search while it's already open puts the cursor in its field (the first tap leaves the
            // keyboard closed so the results and tab bar stay visible).
            if item == .search, model.sidebarSelection == .search {
                model.focusSearch()
            } else {
                model.sidebarSelection = item
            }
        })
    }
}

private struct TabStyleForWidth: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content.tabViewStyle(.tabBarOnly)
        } else {
            content.tabViewStyle(.sidebarAdaptable)
        }
    }
}
