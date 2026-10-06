import SwiftUI
import TunerCore

/// Chips for All / Favorites / Recent / groups / categories, plus the category browser, channel filter and sort.
struct LiveGuideFilterBar: View {
    @Environment(AppModel.self) private var model
    let store: LiveGuideStore
    @Binding var filterText: String

    @ViewState private var showBrowser = false
    @ViewState private var renaming: ChannelCategory?
    @ViewState private var renameText = ""

    @Environment(\.tunerCompact) private var compact

    var body: some View {
        Group {
            if compact {
                // Narrow screens: filter + buttons on one row, the chips scrolling below.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        searchField
                        categoriesButton
                        sortMenu
                    }
                    .padding(.horizontal, VODMetrics.inset)
                    chips
                        .contentMargins(.horizontal, VODMetrics.inset, for: .scrollContent)
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 10) {
                    if model.sources.count > 1 {
                        sourcePicker
                    }
                    chips
                    categoriesButton
                    searchField
                    sortMenu
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            if case .source(let id) = model.liveScope { store.sourceFilter = id }
        }
        .onChange(of: model.liveScope) { _, scope in
            // "Live TV" in the sidebar means every source.
            if scope == .all { store.sourceFilter = nil }
        }
        .onChange(of: store.categories) { _, categories in
            // The selected category was hidden (here, in the browser or in Settings): fall back to all channels.
            if case .category(let id) = model.liveScope, !categories.isEmpty, !categories.contains(where: { $0.id == id }) {
                select(allScope)
            }
        }
        .alert("Rename Category", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let category = renaming {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    model.renameCategory(category, to: name == category.name ? nil : name.nilIfEmpty)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(renaming.map { "Original name: \($0.name)" } ?? "")
        }
    }

    private var categoriesButton: some View {
        Button { showBrowser.toggle() } label: {
            Label("Categories", systemImage: "list.bullet")
        }
        .buttonStyle(LiveGuideChipButtonStyle(selected: false))
        .help("Browse all categories")
        .popover(isPresented: $showBrowser, arrowEdge: .bottom) {
            LiveCategoryBrowser(
                current: model.liveScope,
                onSelect: { category in
                    showBrowser = false
                    select(.category(category.id))
                },
                onRename: { category in
                    showBrowser = false
                    renameText = category.displayName
                    // Let the popover close before presenting the alert.
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        renaming = category
                    }
                }
            )
            .environment(model)
        }
    }

    // MARK: Chips

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    chip("All Channels", symbol: "square.grid.3x3.fill", scope: allScope)
                    chip("Favorites", symbol: "star.fill", scope: .favorites)
                    chip("Recently Watched", symbol: "clock.arrow.circlepath", scope: .recent)
                    ForEach(model.customGroups) { group in
                        chip(group.name, symbol: "folder.fill", scope: .group(group.id))
                    }
                    ForEach(categorySections, id: \.sourceId) { section in
                        separator
                        if showSourceLabels {
                            Text(sourceName(section.sourceId).uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(0.5)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        ForEach(section.categories) { category in
                            chip(category.displayName, symbol: nil, scope: .category(category.id))
                                .contextMenu { categoryMenu(category) }
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never)
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.015),
                                       .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .onAppear {
                Task {
                    await Task.yield()
                    proxy.scrollTo(model.liveScope, anchor: .center)
                }
            }
            .onChange(of: model.liveScope) { _, scope in
                withAnimation(.smooth) { proxy.scrollTo(scope, anchor: .center) }
            }
        }
    }

    private func chip(_ title: String, symbol: String?, scope: ChannelScope) -> some View {
        Button { select(scope) } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(LiveGuideChipButtonStyle(selected: model.liveScope == scope))
        .id(scope)
    }

    private var separator: some View {
        Capsule().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 18).padding(.horizontal, 4)
    }

    @ViewBuilder
    private func categoryMenu(_ category: ChannelCategory) -> some View {
        Button("Rename…") {
            renameText = category.displayName
            renaming = category
        }
        if category.alias != nil {
            Button("Use Original Name") { model.renameCategory(category, to: nil) }
        }
        Divider()
        Button("Hide Category") { hide(category) }
    }

    private var allScope: ChannelScope {
        store.sourceFilter.map { .source($0) } ?? .all
    }

    private struct ChipSection {
        var sourceId: String
        var categories: [ChannelCategory]
    }

    /// Categories with channels, grouped by source (in source order), filtered by the source picker.
    private var categorySections: [ChipSection] {
        var sections: [ChipSection] = []
        for category in store.categories where category.itemCount > 0 {
            if let filter = store.sourceFilter, category.sourceId != filter { continue }
            if sections.last?.sourceId == category.sourceId {
                sections[sections.count - 1].categories.append(category)
            } else {
                sections.append(ChipSection(sourceId: category.sourceId, categories: [category]))
            }
        }
        return sections
    }

    private var showSourceLabels: Bool { model.sources.count > 1 && store.sourceFilter == nil }

    private func sourceName(_ id: String) -> String {
        model.sources.first { $0.id == id }?.name ?? "Playlist"
    }

    // MARK: Source picker

    private var sourcePicker: some View {
        Picker("Source", selection: Binding(get: { store.sourceFilter }, set: setSource)) {
            Text("All Sources").tag(String?.none)
            Divider()
            ForEach(model.sources) { source in
                Text(source.name).tag(Optional(source.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 170)
        .help("Show categories from one playlist")
    }

    private func setSource(_ id: String?) {
        store.sourceFilter = id
        switch model.liveScope {
        case .all, .source:
            select(id.map { .source($0) } ?? .all)
        case .category(let cid):
            if let id, store.categories.first(where: { $0.id == cid })?.sourceId != id { select(.source(id)) }
        default:
            break
        }
    }

    // MARK: Search & sort

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Filter channels", text: $filterText)
                .textFieldStyle(.plain)
                #if os(macOS)
                .onExitCommand { filterText = "" }
                #endif
            if !filterText.isEmpty {
                Button { filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .frame(width: compact ? nil : 190)
        .frame(maxWidth: compact ? .infinity : nil)
    }

    private var sortMenu: some View {
        @Bindable var prefs = model.prefs
        let fixedOrder: Bool = {
            switch model.liveScope {
            case .favorites, .recent, .group: true
            default: false
            }
        }()
        return Menu {
            Picker("Sort By", selection: $prefs.channelSort) {
                ForEach(ChannelSort.allCases, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.inline)
            .disabled(fixedOrder)
            Divider()
            Toggle("Show Channel Numbers", isOn: $prefs.showChannelNumbers)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(fixedOrder ? "This list keeps its own order" : "Sort channels")
    }

    // MARK: Actions

    private func select(_ scope: ChannelScope) {
        withAnimation(.snappy(duration: 0.25)) {
            switch scope {
            case .favorites:
                model.sidebarSelection = .favorites
            case .recent:
                model.sidebarSelection = .recent
            case .group(let id):
                model.sidebarSelection = .group(id)
            default:
                if model.sidebarSelection != .liveTV { model.sidebarSelection = .liveTV }
                model.liveScope = scope
            }
        }
    }

    private func hide(_ category: ChannelCategory) {
        model.setCategoryHidden(category, hidden: true)
    }
}

// MARK: - Chip style

/// Apple TV–style pill: white when selected, translucent otherwise; brightens on hover.
struct LiveGuideChipButtonStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        LiveChipBody(configuration: configuration, selected: selected)
    }

    private struct LiveChipBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.colorScheme) private var colorScheme
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary)
                .background(
                    Capsule().fill(selected ? Color.primary : Color.primary.opacity(hovering ? 0.14 : 0.07))
                )
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        }
    }
}

// MARK: - Category browser

/// Searchable list of every live category, grouped by source, with counts; right-click to hide or rename.
private struct LiveCategoryBrowser: View {
    @Environment(AppModel.self) private var model
    let current: ChannelScope
    var onSelect: (ChannelCategory) -> Void
    var onRename: (ChannelCategory) -> Void

    @ViewState private var query = ""
    @ViewState private var showHidden = false
    @ViewState private var categories: [ChannelCategory] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search categories", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                Toggle("Hidden", isOn: $showHidden)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Include hidden categories")
            }
            .padding(12)

            Divider()

            if filteredSections.isEmpty {
                Group {
                    if query.isEmpty {
                        ContentUnavailableView("No Categories", systemImage: "list.bullet",
                                               description: Text("Your playlists don't define any live categories."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredSections, id: \.sourceId) { section in
                        SwiftUI.Section(model.sources.first { $0.id == section.sourceId }?.name ?? "Playlist") {
                            ForEach(section.categories) { category in
                                row(category)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 360, height: 460)
        .task(id: LiveGuideRevisionKey(library: model.libraryRevision, user: model.userRevision, extra: showHidden)) {
            categories = (try? await model.db.categories(kind: .live, includeHidden: showHidden)) ?? []
        }
    }

    private func row(_ category: ChannelCategory) -> some View {
        let selected = current == .category(category.id)
        return Button { onSelect(category) } label: {
            HStack(spacing: 8) {
                Image(systemName: category.isHidden ? "eye.slash" : "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(category.isHidden ? Color.secondary : Color.accentColor)
                    .opacity(category.isHidden || selected ? 1 : 0)
                    .frame(width: 14)
                Text(category.displayName)
                    .lineLimit(1)
                    .foregroundStyle(category.isHidden ? .secondary : .primary)
                Spacer(minLength: 8)
                Text("\(category.itemCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(category.isHidden)
        .contextMenu {
            Button(category.isHidden ? "Show Category" : "Hide Category") {
                model.setCategoryHidden(category, hidden: !category.isHidden)
            }
            Button("Rename…") { onRename(category) }
            if category.alias != nil {
                Button("Use Original Name") { model.renameCategory(category, to: nil) }
            }
        }
    }

    private struct BrowserSection {
        var sourceId: String
        var categories: [ChannelCategory]
    }

    private var filteredSections: [BrowserSection] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var sections: [BrowserSection] = []
        for category in categories {
            if !words.isEmpty {
                let name = category.displayName.lowercased()
                guard words.allSatisfy({ name.contains($0) }) else { continue }
            }
            if sections.last?.sourceId == category.sourceId {
                sections[sections.count - 1].categories.append(category)
            } else {
                sections.append(BrowserSection(sourceId: category.sourceId, categories: [category]))
            }
        }
        return sections
    }
}
