import SwiftUI
import TunerCore

/// Live TV: a preview + programme-details header, the category/filter bar and the programme guide.
/// Shown for Live TV, Favorites, Recently Watched and custom groups; the list follows `model.liveScope`.
struct LiveTVView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var store = LiveGuideStore()
    @ViewState private var filterText = ""
    @ViewState private var search = ""

    var body: some View {
        if model.hasSources {
            screen
        } else {
            WelcomeView()
        }
    }

    private var screen: some View {
        GeometryReader { geo in
            let headerHeight = min(380, max(220, (geo.size.height * 0.34).rounded()))
            VStack(spacing: 0) {
                if model.isOffline {
                    OfflineBanner()
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                }
                LiveGuideHeader(store: store)
                    .frame(height: headerHeight)
                LiveGuideFilterBar(store: store, filterText: $filterText)
                    // Its horizontal ScrollView is vertically greedy; keep the bar at its natural height.
                    .fixedSize(horizontal: false, vertical: true)
                guide
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(alignment: .top) {
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 420)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .navigationTitle(store.title(for: model.liveScope, model: model))
        .task {
            store.attach(model)
            await store.runClock()
        }
        .task(id: listKey) { await loadChannels(listKey) }
        .task(id: LiveGuideRevisionKey(library: model.libraryRevision, user: model.userRevision)) {
            if let list = try? await model.db.categories(kind: .live) { store.setCategories(list) }
        }
        .task(id: filterText) {
            // Debounce typing before querying 20k+ channels.
            if !filterText.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            search = filterText.trimmingCharacters(in: .whitespaces)
        }
        .onChange(of: model.guideRevision) { _, _ in store.invalidatePrograms() }
        .onChange(of: playingChannelId) { _, _ in
            store.followPlaying(model.player.main.item?.channel)
        }
        .onDisappear { store.cancelPendingPreview() }
        .alert("Rename Channel", isPresented: renameBinding) {
            @Bindable var store = store
            TextField("Name", text: $store.renameText)
            Button("Rename") {
                if let channel = store.renameTarget {
                    let name = store.renameText.trimmingCharacters(in: .whitespaces)
                    model.rename(channel, to: name == channel.name ? nil : name.nilIfEmpty)
                }
            }
            if store.renameTarget?.alias != nil {
                Button("Use Original Name") {
                    if let channel = store.renameTarget { model.rename(channel, to: nil) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.renameTarget.map { "Original name: \($0.name)" } ?? "")
        }
        .alert("New Group", isPresented: newGroupBinding) {
            @Bindable var store = store
            TextField("Name", text: $store.newGroupName)
            Button("Create") {
                let name = store.newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.createGroup(named: name, with: store.newGroupTarget) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.newGroupTarget.map { "Creates a group containing \($0.displayName)." } ?? "")
        }
    }

    // MARK: Guide area / empty states

    @ViewBuilder
    private var guide: some View {
        if !store.channels.isEmpty {
            LiveGuideGrid(store: store)
        } else if !store.hasLoaded {
            Color.clear
        } else if model.isSyncing, isBrowseScope {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading channels…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            emptyScope
        }
    }

    @ViewBuilder
    private var emptyScope: some View {
        switch model.liveScope {
        case .favorites:
            ContentUnavailableView {
                Label("No Favorites Yet", systemImage: "star")
            } description: {
                Text("Right-click any channel in the guide and choose Add to Favorites, or use the star next to Play.")
            }
        case .recent:
            ContentUnavailableView {
                Label("Nothing Watched Yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Channels you watch appear here, most recent first.")
            }
        case .group:
            ContentUnavailableView {
                Label("This Group Is Empty", systemImage: "folder")
            } description: {
                Text("Right-click any channel in the guide and choose Add to Group.")
            }
        default:
            ContentUnavailableView {
                Label("No Channels", systemImage: "tv")
            } description: {
                Text("There are no channels to show here. Hidden channels and categories are not listed.")
            } actions: {
                if model.liveScope != .all {
                    Button("Show All Channels") {
                        store.sourceFilter = nil
                        model.liveScope = .all
                    }
                }
            }
        }
    }

    // MARK: Loading

    private var isBrowseScope: Bool {
        switch model.liveScope {
        case .all, .source, .category: true
        default: false
        }
    }

    private var playingChannelId: String? { model.player.main.item?.channel?.id }

    private var listKey: LiveListKey {
        LiveListKey(
            signature: LiveGuideListSignature(scope: model.liveScope, search: search, sort: model.prefs.channelSort,
                                              hideAdult: model.prefs.hideAdultContent),
            library: model.libraryRevision,
            user: model.userRevision
        )
    }

    private func loadChannels(_ key: LiveListKey) async {
        let sig = key.signature
        let scopeChanged = model.zapList.isEmpty || lastZapScope != sig.scope
        do {
            var list = try await model.db.channels(scope: sig.scope, search: sig.search.isEmpty ? nil : sig.search, sort: sig.sort)
            if sig.hideAdult { list.removeAll { $0.isAdult } }
            guard !Task.isCancelled else { return }
            store.setChannels(list, signature: sig)
            // "Recent" reorders on every channel change; keep the zap order stable while zapping through it.
            if (scopeChanged || sig.scope != .recent), model.zapList != list {
                model.zapList = list
            }
            lastZapScope = sig.scope
        } catch {
            guard !Task.isCancelled else { return }
            store.setChannels([], signature: sig)
        }
        // The header channel may come from elsewhere (e.g. playing from Home); keep its state fresh.
        if let selected = store.selectedChannel, !store.contains(selected.id),
           let fresh = try? await model.db.channel(id: selected.id) {
            store.refreshSelected(fresh)
        }
    }

    @ViewState private var lastZapScope: ChannelScope?

    // MARK: Dialog bindings

    private var renameBinding: Binding<Bool> {
        Binding(get: { store.renameTarget != nil }, set: { if !$0 { store.renameTarget = nil } })
    }

    private var newGroupBinding: Binding<Bool> {
        Binding(get: { store.newGroupTarget != nil }, set: { if !$0 { store.newGroupTarget = nil } })
    }
}

private struct LiveListKey: Hashable {
    var signature: LiveGuideListSignature
    var library: Int
    var user: Int
}

/// Generic "reload when these revisions change" key for `.task(id:)` in the Live views.
struct LiveGuideRevisionKey: Hashable {
    var library: Int
    var user: Int
    var extra = false
}
