import SwiftUI
import TunerCore

/// Providers ship dozens of movie/series categories ("Arabic Movies - عربي 2024", "Netflix - أفلام نت فليكس"…).
/// Browse pages show them as a few group menus (Platforms, Genres, By Year…) plus the user's pinned categories,
/// instead of one chip per category. Grouping and name cleanup come from `CategoryClassifier` (TunerCore).
struct VODCategoryGroups {
    /// Non-empty groups in display order, each with its categories (By Year newest first).
    let groups: [(group: CategoryGroup, categories: [ChannelCategory])]
    private let groupById: [String: CategoryGroup]

    init(_ categories: [ChannelCategory]) {
        var buckets: [CategoryGroup: [(ChannelCategory, CategoryFacet)]] = [:]
        var byId: [String: CategoryGroup] = [:]
        for category in categories {
            let facet = CategoryClassifier.facet(for: category.name)
            buckets[facet.group, default: []].append((category, facet))
            byId[category.id] = facet.group
        }
        groupById = byId
        groups = CategoryGroup.displayOrder.compactMap { group in
            guard var members = buckets[group], !members.isEmpty else { return nil }
            if group == .byYear {
                // Newest first; the provider's order breaks ties (e.g. Arabic before English for the same year).
                members = members.enumerated().sorted { a, b in
                    let ya = a.element.1.latestYear ?? 0, yb = b.element.1.latestYear ?? 0
                    return ya != yb ? ya > yb : a.offset < b.offset
                }.map(\.element)
            }
            return (group, members.map(\.0))
        }
    }

    func group(of categoryId: String) -> CategoryGroup? { groupById[categoryId] }
}

extension ChannelCategory {
    /// The user's rename wins; otherwise the provider's name in the chosen style.
    func presentedName(_ style: CategoryNameStyle) -> String {
        if let alias = alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty { return alias }
        return CategoryClassifier.facet(for: name).displayName(style)
    }
}

/// A chip that opens a menu of one group's categories. Shows the chosen category's name while one of them is
/// selected, otherwise the group's name.
struct VODCategoryGroupChip: View {
    let group: CategoryGroup
    let categories: [ChannelCategory]
    let selectedId: String?
    let style: CategoryNameStyle
    let select: (String) -> Void
    @ViewState private var hovering = false

    private var selected: ChannelCategory? { categories.first { $0.id == selectedId } }

    var body: some View {
        let isSelected = selected != nil
        Menu {
            Section(group.title) {
                ForEach(categories) { category in
                    Toggle(isOn: Binding(get: { category.id == selectedId }, set: { _ in select(category.id) })) {
                        // Title + subtitle: a count run into the name is ambiguous ("TOP 264 Movie 256").
                        Text(category.presentedName(style))
                        if category.itemCount > 0 {
                            Text(category.itemCount == 1 ? "1 title" : "\(category.itemCount.formatted()) titles")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selected?.presentedName(style) ?? group.shortTitle).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.background.opacity(0.7)) : AnyShapeStyle(.secondary))
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background(
                Capsule().fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.14 : 0.08)))
            )
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("\(group.title): \(categories.count) categories")
    }
}

/// Organise a library's categories: how names read, which are pinned as chips, which are hidden.
struct VODCategoryManager: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: VODBrowseKind
    /// The category the browse page shows (checkmarked here).
    var selectedId: String?
    /// Tapping a category shows it on the browse page and closes the sheet.
    var onSelect: (String) -> Void = { _ in }

    @ViewState private var categories: [ChannelCategory] = []
    @ViewState private var search = ""

    private var style: CategoryNameStyle { model.prefs.categoryNameStyle }

    private var filtered: [ChannelCategory] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return categories }
        return categories.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.presentedName(style).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        @Bindable var prefs = model.prefs
        NavigationStack {
            List {
                Section {
                    Picker("Category Names", selection: $prefs.categoryNameStyle) {
                        ForEach(CategoryNameStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Pin categories you use often: they appear first on the \(kind.title) page. Hidden categories and their titles are left out everywhere.")
                }

                let pinned = model.prefs.pinnedCategoryIds.compactMap { id in categories.first { $0.id == id } }
                if !pinned.isEmpty, search.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { row($0) }
                            .onMove { from, to in
                                var ids = pinned.map(\.id)
                                ids.move(fromOffsets: from, toOffset: to)
                                model.prefs.pinnedCategoryIds = ids + model.prefs.pinnedCategoryIds.filter { !ids.contains($0) }
                            }
                    }
                }

                ForEach(VODCategoryGroups(filtered).groups, id: \.group) { entry in
                    Section {
                        ForEach(entry.categories) { row($0) }
                    } header: {
                        Label(entry.group.title, systemImage: entry.group.symbol)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search categories")
            .navigationTitle("\(kind.title) Categories")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 680)
        #endif
        .task(id: model.libraryRevision) { await load() }
        .task(id: model.userRevision) { await load() }
    }

    private func row(_ category: ChannelCategory) -> some View {
        let isPinned = model.prefs.pinnedCategoryIds.contains(category.id)
        return HStack(spacing: 12) {
            // Name and count: tap to show this category (hidden ones can't be shown until unhidden).
            Button {
                onSelect(category.id)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.presentedName(style))
                            .foregroundStyle(category.isHidden ? .secondary : .primary)
                        // The provider's name underneath, unless it only differs by spacing.
                        if style != .original, category.presentedName(style).filter({ !$0.isWhitespace }) != category.name.filter({ !$0.isWhitespace }) {
                            Text(category.name).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if category.id == selectedId {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                    Text(category.itemCount.formatted())
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(category.isHidden)
            .help(category.isHidden ? "Show this category first" : "Show \(category.presentedName(style))")
            Button { togglePin(category) } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(isPinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(category.isHidden)
            .help(isPinned ? "Unpin" : "Pin to the \(kind.title) page")
            .accessibilityLabel(isPinned ? "Unpin \(category.presentedName(style))" : "Pin \(category.presentedName(style))")
            Button { model.setCategoryHidden(category, hidden: !category.isHidden) } label: {
                Image(systemName: category.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(category.isHidden ? Color.orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(category.isHidden ? "Show this category" : "Hide this category")
            .accessibilityLabel(category.isHidden ? "Show \(category.presentedName(style))" : "Hide \(category.presentedName(style))")
        }
    }

    private func togglePin(_ category: ChannelCategory) {
        var ids = model.prefs.pinnedCategoryIds
        if let index = ids.firstIndex(of: category.id) { ids.remove(at: index) } else { ids.append(category.id) }
        model.prefs.pinnedCategoryIds = ids
    }

    private func load() async {
        let list = (try? await model.db.categories(kind: kind.categoryKind, includeHidden: true)) ?? []
        if list != categories { categories = list }
    }
}
