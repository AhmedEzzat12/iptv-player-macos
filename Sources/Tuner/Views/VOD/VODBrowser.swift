import SwiftUI
import TunerCore

/// Which library a browse page shows.
enum VODBrowseKind: String {
    case movies
    case series

    var title: String { self == .movies ? "Movies" : "TV Shows" }
    var categoryKind: CategoryKind { self == .movies ? .movie : .series }
    var symbol: String { self == .movies ? "film" : "tv" }
}

/// Movies / TV Shows browse page: large title, category chips, sort and poster-size menu, a toolbar
/// search field, and an adaptive poster grid paged 200 at a time.
struct VODBrowser: View {
    @Environment(AppModel.self) private var model
    let kind: VODBrowseKind

    @SceneStorage private var storedCategoryId: String
    @ViewState private var categories: [ChannelCategory] = []
    @ViewState private var search = ""
    @ViewState private var items: [VODItem] = []
    @ViewState private var canLoadMore = false
    @ViewState private var isLoading = true
    @ViewState private var isLoadingMore = false
    @ViewState private var errorMessage: String?
    @ViewState private var favorites: Set<String> = []
    @ViewState private var progress: [String: Double] = [:]
    @ViewState private var appliedFilter: VODBrowseFilter?
    @ViewState private var generation = 0
    @ViewState private var retryToken = 0
    @ViewState private var scrollPosition = ScrollPosition(edge: .top)
    @ViewState private var showCategoryManager = false

    private static let pageSize = 200

    init(kind: VODBrowseKind) {
        self.kind = kind
        _storedCategoryId = SceneStorage(wrappedValue: "", "vod.\(kind.rawValue).category")
    }

    private var selectedCategoryId: String? { storedCategoryId.isEmpty ? nil : storedCategoryId }

    private var selectedCategory: ChannelCategory? {
        guard let id = selectedCategoryId else { return nil }
        return categories.first { $0.id == id }
    }

    /// Categories worth a chip: non-empty ones, plus Stalker categories (their items load on open).
    private var visibleCategories: [ChannelCategory] {
        let stalker = Set(model.sources.filter { $0.kind == .stalker }.map(\.id))
        return categories.filter { $0.itemCount > 0 || stalker.contains($0.sourceId) }
    }

    private var hasStalkerCategories: Bool {
        let stalker = Set(model.sources.filter { $0.kind == .stalker }.map(\.id))
        return categories.contains { stalker.contains($0.sourceId) }
    }


    private var filter: VODBrowseFilter {
        VODBrowseFilter(
            categoryId: selectedCategoryId,
            search: search.trimmingCharacters(in: .whitespacesAndNewlines),
            sort: model.prefs.vodSort
        )
    }

    var body: some View {
        ScrollView {
            // Lazy so the paging footer only appears (and loads the next page) when scrolled into view.
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                content
                if canLoadMore, !items.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .task(id: items.count) { await loadMore() }
                }
            }
            .padding(.bottom, 40)
        }
        .scrollPosition($scrollPosition)
        .background(VODTheme.background)
        .navigationTitle(kind.title)
        .searchable(text: $search, placement: .toolbar, prompt: "Search \(kind.title)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { sortMenu }
        }
        .task(id: model.libraryRevision) { await loadCategories() }
        .task(id: model.userRevision) { await loadUserState() }
        .task(id: VODBrowseLoadKey(filter: filter, library: model.libraryRevision, retry: retryToken)) {
            await loadFirstPage(filter)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VODPageTitle(title: selectedCategory?.presentedName(nameStyle) ?? kind.title, subtitle: countLabel)
                manageButton
            }
            .padding(.horizontal, VODMetrics.inset)

            if model.isOffline {
                OfflineBanner()
                    .padding(.horizontal, VODMetrics.inset)
            }

            if !visibleCategories.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        VODChip(title: "All", isSelected: selectedCategoryId == nil) { select(nil) }
                        ForEach(pinnedCategories) { category in
                            VODChip(
                                title: category.presentedName(nameStyle),
                                count: category.itemCount > 0 ? category.itemCount : nil,
                                isSelected: category.id == selectedCategoryId
                            ) {
                                select(category.id)
                            }
                            .help(sourceName(category.sourceId) ?? category.name)
                        }
                        if !pinnedCategories.isEmpty {
                            Capsule().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 18).padding(.horizontal, 2)
                        }
                        ForEach(categoryGroups.groups, id: \.group) { entry in
                            VODCategoryGroupChip(
                                group: entry.group,
                                // A pinned category stays in its group's menu too, so the menu shows the whole group.
                                categories: entry.categories,
                                selectedId: pinnedIds.contains(selectedCategoryId ?? "") ? nil : selectedCategoryId,
                                style: nameStyle,
                                select: { select($0) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                .contentMargins(.horizontal, VODMetrics.inset, for: .scrollContent)
                .frame(height: 36)
            }
        }
        .padding(.top, 14)
    }

    private var countLabel: String? {
        guard !items.isEmpty else { return nil }
        let n = items.count
        return canLoadMore ? "\(n.formatted())+" : n.formatted()
    }

    private var nameStyle: CategoryNameStyle { model.prefs.categoryNameStyle }

    private var categoryGroups: VODCategoryGroups { VODCategoryGroups(visibleCategories) }

    private var pinnedIds: Set<String> { Set(model.prefs.pinnedCategoryIds) }

    /// Pinned categories that are visible here, in pin order.
    private var pinnedCategories: [ChannelCategory] {
        model.prefs.pinnedCategoryIds.compactMap { id in visibleCategories.first { $0.id == id } }
    }

    /// Opens the category organiser (names, pins, hidden categories).
    @ViewBuilder
    private var manageButton: some View {
        if !visibleCategories.isEmpty {
            Button { showCategoryManager = true } label: {
                Label("Categories", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Organise categories: pin, hide and choose how names read")
            .sheet(isPresented: $showCategoryManager) {
                VODCategoryManager(kind: kind).environment(model)
            }
        }
    }

    private var sortMenu: some View {
        @Bindable var prefs = model.prefs
        return Menu {
            Picker("Sort By", selection: $prefs.vodSort) {
                ForEach(VODSort.allCases, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.inline)
            Picker("Poster Size", selection: $prefs.posterSize) {
                Text("Small").tag(120.0)
                Text("Medium").tag(150.0)
                Text("Large").tag(190.0)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort & View", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort and poster size")
    }

    // MARK: Grid

    @ViewBuilder
    private var content: some View {
        if let errorMessage, items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load \(selectedCategory?.displayName ?? kind.title)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { retryToken += 1 }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else if items.isEmpty, isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 360)
        } else if items.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            grid
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !filter.search.isEmpty {
            ContentUnavailableView.search(text: filter.search)
        } else if model.isSyncing {
            ContentUnavailableView {
                Label("Loading \(kind.title)", systemImage: kind.symbol)
            } description: {
                Text("Your playlists are still syncing.")
            }
        } else if selectedCategoryId != nil {
            ContentUnavailableView("Nothing in This Category", systemImage: kind.symbol)
        } else if hasStalkerCategories {
            ContentUnavailableView(
                "Choose a Category",
                systemImage: kind.symbol,
                description: Text("Stalker portals load \(kind.title.lowercased()) one category at a time.")
            )
        } else {
            ContentUnavailableView(
                "No \(kind.title)",
                systemImage: kind.symbol,
                description: Text("\(kind.title) from your Xtream, Stalker or M3U playlists appear here.")
            )
        }
    }

    private var grid: some View {
        let size = max(100, model.prefs.posterSize)
        let columns = [GridItem(.adaptive(minimum: size, maximum: size * 1.45), spacing: 22, alignment: .top)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(items) { item in
                    NavigationLink(value: item.route) {
                        VODPosterCard(
                            item: item,
                            width: nil,
                            progress: progress[item.mediaId],
                            isFavorite: favorites.contains(item.mediaId)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        VODItemMenu(item: item, isFavorite: favorites.contains(item.mediaId))
                    }
                }
            }
            .padding(.horizontal, VODMetrics.inset)
            .padding(.top, 6)
    }

    // MARK: Actions & loading

    private func select(_ categoryId: String?) {
        withAnimation(.snappy(duration: 0.2)) { storedCategoryId = categoryId ?? "" }
    }

    private func sourceName(_ id: String) -> String? {
        model.sources.first { $0.id == id }?.name
    }

    private func loadCategories() async {
        let list = (try? await model.db.categories(kind: kind.categoryKind)) ?? []
        guard !Task.isCancelled else { return }
        if list != categories { categories = list }
        // A remembered category that was removed or hidden falls back to All.
        if let id = selectedCategoryId, !list.isEmpty, !list.contains(where: { $0.id == id }) {
            storedCategoryId = ""
        }
    }

    private func loadUserState() async {
        let db = model.db
        let ids: [String]
        switch kind {
        case .movies: ids = ((try? await db.favoriteMovies()) ?? []).map(\.id)
        case .series: ids = ((try? await db.favoriteSeries()) ?? []).map(\.id)
        }
        let cw = (try? await db.continueWatching(limit: 100)) ?? []
        guard !Task.isCancelled else { return }
        favorites = Set(ids)
        progress = kind == .movies
            ? Dictionary(cw.filter { $0.kind == .movie }.map { ($0.mediaId, $0.fraction) }, uniquingKeysWith: { a, _ in a })
            : [:]
    }

    private func loadFirstPage(_ filter: VODBrowseFilter) async {
        let sameFilter = appliedFilter == filter
        // Debounce typing in the search field.
        if !sameFilter, appliedFilter?.search != filter.search, !filter.search.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        generation += 1
        let gen = generation
        isLoading = true
        errorMessage = nil
        // A new category starts from a blank grid; search/sort changes keep showing the old results until the new ones arrive.
        if !sameFilter, appliedFilter?.categoryId != filter.categoryId {
            items = []
            canLoadMore = false
        }

        // Stalker portals load a category's items on first open.
        if let id = filter.categoryId {
            if categories.isEmpty { await loadCategories() }
            if let category = categories.first(where: { $0.id == id }) {
                do {
                    try await model.sync.loadCategoryIfNeeded(category)
                } catch {
                    guard !Task.isCancelled, gen == generation else { return }
                    errorMessage = error.localizedDescription
                    isLoading = false
                    appliedFilter = filter
                    return
                }
            }
        }

        let limit = sameFilter ? max(Self.pageSize, items.count) : Self.pageSize
        do {
            let page = try await fetch(filter, limit: limit, offset: 0)
            guard !Task.isCancelled, gen == generation else { return }
            if page != items { items = page }
            canLoadMore = page.count == limit
            if !sameFilter { scrollPosition.scrollTo(edge: .top) }
        } catch {
            guard !Task.isCancelled, gen == generation else { return }
            errorMessage = error.localizedDescription
        }
        appliedFilter = filter
        isLoading = false
    }

    private func loadMore() async {
        guard canLoadMore, !isLoadingMore, !isLoading, let filter = appliedFilter else { return }
        let gen = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await fetch(filter, limit: Self.pageSize, offset: items.count),
              !Task.isCancelled, gen == generation else { return }
        let known = Set(items.map(\.id))
        items.append(contentsOf: page.filter { !known.contains($0.id) })
        canLoadMore = page.count == Self.pageSize
    }

    private func fetch(_ filter: VODBrowseFilter, limit: Int, offset: Int) async throws -> [VODItem] {
        let search = filter.search.isEmpty ? nil : filter.search
        switch kind {
        case .movies:
            return try await model.db.movies(categoryId: filter.categoryId, search: search, sort: filter.sort, limit: limit, offset: offset)
                .map(VODItem.movie)
        case .series:
            return try await model.db.series(categoryId: filter.categoryId, search: search, sort: filter.sort, limit: limit, offset: offset)
                .map(VODItem.series)
        }
    }
}

private struct VODBrowseFilter: Hashable {
    var categoryId: String?
    var search: String
    var sort: VODSort
}

private struct VODBrowseLoadKey: Hashable {
    var filter: VODBrowseFilter
    var library: Int
    var retry: Int
}
