import AppKit
import SwiftUI
import TunerCore
import UniformTypeIdentifiers

/// Settings → Playlists: the user's sources (reorder, enable, edit, refresh, export, delete)
/// and the global XMLTV feeds shared by every playlist.
struct SettingsPlaylistsPane: View {
    @Environment(AppModel.self) private var model
    /// The source editor is presented here (not on the main window) so it appears over Settings.
    @ViewState private var editing: SourceEditorRequest?
    @ViewState private var pendingDelete: Source?
    @ViewState private var exporting: Set<String> = []
    @ViewState private var exported: Set<String> = []
    @ViewState private var exportError: String?
    @ViewState private var feeds: [EPGFeed] = []
    /// Global feeds downloading for the first time (added here or from the online guides sheet).
    @ViewState private var downloadingFeeds: Set<String> = []
    @ViewState private var browsingGuides = false

    var body: some View {
        Form {
            Section {
                if model.sources.isEmpty {
                    emptyRow
                } else {
                    ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                        SettingsSourceRow(
                            source: source,
                            sync: model.activeSyncs[source.id],
                            isExporting: exporting.contains(source.id),
                            justExported: exported.contains(source.id),
                            canMoveUp: index > 0,
                            canMoveDown: index < model.sources.count - 1,
                            onEdit: { editing = SourceEditorRequest(source: source, kind: source.kind) },
                            onExport: { export(source) },
                            onDelete: { pendingDelete = source },
                            onMove: { move(index, by: $0) },
                            onDropSource: { reorder($0, onto: index) }
                        )
                    }
                }
            } header: {
                Text("Playlists")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.sources.count > 1 ? "Drag to change the order playlists appear in." : "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.sources.count > 1 {
                        Button("Refresh All") { model.syncAll() }
                            .disabled(model.isSyncing)
                    }
                    addMenu
                }
            }

            SettingsGlobalFeedsSection(
                feeds: feeds,
                downloading: downloadingFeeds,
                reload: reloadFeeds,
                add: addGlobalFeed,
                browse: { browsingGuides = true }
            )
        }
        .formStyle(.grouped)
        .task(id: model.guideRevision) { await reloadFeeds() }
        .sheet(item: $editing) { request in
            SourceEditorView(request: request).environment(model)
        }
        .sheet(isPresented: $browsingGuides) {
            SettingsOnlineGuidesSheet(feeds: feeds, downloading: downloadingFeeds, add: addGlobalFeed)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { source in
            Button("Delete Playlist", role: .destructive) { model.deleteSource(source) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its channels, movies, shows and guide are removed from Tuner. You can add it again at any time.")
        }
        .alert(
            "Couldn't Export Playlist",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "play.square.stack")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No playlists yet").font(.body.weight(.medium))
                SettingsFooter("Add an M3U playlist, Xtream Codes account or Stalker portal from your provider.")
            }
        }
        .padding(.vertical, 8)
    }

    private var addMenu: some View {
        Menu {
            ForEach(Source.Kind.allCases, id: \.self) { kind in
                Button {
                    editing = SourceEditorRequest(source: nil, kind: kind)
                } label: {
                    Label(kind.displayName + "…", systemImage: kind.settingsSymbol)
                }
            }
        } label: {
            Label("Add Playlist", systemImage: "plus")
        }
        .fixedSize()
    }

    private func reloadFeeds() async {
        let all = (try? await model.db.epgFeeds()) ?? []
        feeds = all.filter { $0.sourceId == nil }
    }

    /// Adds a global guide feed for `url` (unless one exists) and downloads just that feed.
    /// Returns an error message for the save or the download.
    private func addGlobalFeed(_ url: String) async -> String? {
        let existing = ((try? await model.db.epgFeeds()) ?? []).filter { $0.sourceId == nil }
        guard !existing.contains(where: { $0.url == url }) else { return nil }
        let priority = (existing.map(\.priority).max() ?? -1) + 1
        let feed = EPGFeed(id: "global#" + UUID().uuidString, url: url, sourceId: nil, priority: priority)
        do {
            try await model.db.save(feed)
        } catch {
            return error.localizedDescription
        }
        await reloadFeeds()
        // Download only the new feed rather than re-fetching every global guide.
        downloadingFeeds.insert(feed.id)
        let error = await model.sync.guide.refreshFeed(id: feed.id)
        downloadingFeeds.remove(feed.id)
        await reloadFeeds()
        return error
    }

    /// Drop of a dragged playlist onto row `target`: it takes that row's place.
    private func reorder(_ draggedId: String, onto target: Int) {
        guard let from = model.sources.firstIndex(where: { $0.id == draggedId }), from != target else { return }
        model.moveSources(from: IndexSet(integer: from), to: target > from ? target + 1 : target)
    }

    private func move(_ index: Int, by step: Int) {
        let target = index + step
        guard target >= 0, target < model.sources.count else { return }
        model.moveSources(from: IndexSet(integer: index), to: step > 0 ? target + 1 : target)
    }

    private func export(_ source: Source) {
        let panel = NSSavePanel()
        panel.title = "Export Playlist"
        panel.message = "Saves the visible channels of “\(source.name)” as an M3U playlist."
        panel.prompt = "Export"
        panel.nameFieldStringValue = Self.fileName(for: source.name) + ".m3u"
        panel.allowedContentTypes = [.m3uPlaylist]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let id = source.id
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            exporting.insert(id)
            Task { @MainActor in
                let text = await model.exportM3U(sourceId: id)
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    exported.insert(id)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(4))
                        exported.remove(id)
                    }
                } catch {
                    exportError = error.localizedDescription
                }
                exporting.remove(id)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private static func fileName(for name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Playlist" : cleaned
    }
}

// MARK: - Source row

private struct SettingsSourceRow: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let sync: SyncEvent?
    let isExporting: Bool
    let justExported: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    let onDropSource: (String) -> Void
    @ViewState private var dropTargeted = false

    /// Drag payload prefix so only Tuner playlist rows are accepted as drops.
    private static let dragPrefix = "tuner-playlist:"

    var body: some View {
        HStack(spacing: 12) {
            SettingsSourceIcon(kind: source.kind, size: 32, dimmed: !source.enabled)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(source.kind.settingsBadge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                        .foregroundStyle(.secondary)
                }
                statusLine
                if source.enabled, sync == nil, !accountDetails.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(accountDetails.enumerated()), id: \.offset) { index, part in
                            if index > 0 { Text(" · ") }
                            Text(part.text).foregroundStyle(part.color)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if let error = source.lastError, !error.isEmpty, sync == nil, source.enabled {
                    Label {
                        Text(error).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            if isExporting {
                ProgressView().controlSize(.small).help("Exporting…")
            } else if justExported {
                Label("Exported", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("Exported")
            }

            Toggle("Enabled", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(source.enabled ? "Turn off to hide this playlist without deleting it" : "Turn on to show this playlist")

            Button(action: onEdit) {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Edit playlist details")

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 4)
        .background {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .padding(.horizontal, -8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .draggable(Self.dragPrefix + source.id) {
            HStack(spacing: 8) {
                SettingsSourceIcon(kind: source.kind, size: 20)
                Text(source.name).font(.body.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first(where: { $0.hasPrefix(Self.dragPrefix) }) else { return false }
            onDropSource(String(payload.dropFirst(Self.dragPrefix.count)))
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            actions
            Divider()
            Button("Move Up") { onMove(-1) }.disabled(!canMoveUp)
            Button("Move Down") { onMove(1) }.disabled(!canMoveDown)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Edit…", action: onEdit)
        Button("Refresh Now") { model.sync(source.id) }
            .disabled(sync != nil || !source.enabled)
        Button("Export M3U…", action: onExport)
            .disabled(source.channelCount == 0 || source.kind == .stalker || isExporting)
        Divider()
        Button("Delete…", role: .destructive, action: onDelete)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { source.enabled },
            set: { value in
                var updated = model.sources.first { $0.id == source.id } ?? source
                updated.enabled = value
                model.updateSource(updated)
            }
        )
    }

    // MARK: Status

    @ViewBuilder
    private var statusLine: some View {
        if let sync {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(Self.phaseText(sync))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if !source.enabled {
            Text("Off").font(.callout).foregroundStyle(.secondary)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(statusText(now: context.date))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func statusText(now: Date) -> String {
        var parts: [String] = []
        if let date = source.lastSyncedAt {
            parts.append("Updated " + SettingsRelativeDate.describe(date, now: now))
        } else {
            parts.append(source.lastError == nil ? "Not updated yet" : "Couldn't update")
        }
        if source.lastSyncedAt != nil {
            parts.append(Self.count(source.channelCount, "channel", "channels"))
            if source.movieCount > 0 { parts.append(Self.count(source.movieCount, "movie", "movies")) }
            if source.seriesCount > 0 { parts.append(Self.count(source.seriesCount, "show", "shows")) }
        }
        return parts.joined(separator: " · ")
    }

    private struct DetailPart {
        var text: String
        var color: Color = .secondary
    }

    /// Expiry and connection details (Xtream / Stalker accounts).
    private var accountDetails: [DetailPart] {
        var parts: [DetailPart] = []
        if let expiry = source.expiresAt {
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: expiry)).day ?? 0
            let date = expiry.formatted(date: .abbreviated, time: .omitted)
            if expiry < Date() {
                parts.append(DetailPart(text: "Expired \(date)", color: .red))
            } else if days < 7 {
                let when = days <= 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
                parts.append(DetailPart(text: "Expires \(when) (\(date))", color: .orange))
            } else {
                parts.append(DetailPart(text: "Expires \(date)"))
            }
        }
        if let max = source.maxConnections, max > 0 {
            parts.append(DetailPart(text: "\(source.activeConnections ?? 0) of \(max) connections in use"))
        }
        return parts
    }

    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }

    static func phaseText(_ event: SyncEvent) -> String {
        switch event.phase {
        case .started: "Connecting…"
        case .channels: "Updating channels…"
        case .vod: "Updating movies & shows…"
        case .guide: "Updating guide…"
        default: "Updating…"
        }
    }
}

// MARK: - Global guide feeds

private struct SettingsGlobalFeedsSection: View {
    @Environment(AppModel.self) private var model
    let feeds: [EPGFeed]
    /// Ids of feeds downloading for the first time.
    let downloading: Set<String>
    let reload: () async -> Void
    /// Adds and downloads a feed for a URL; returns an error message.
    let add: (String) async -> String?
    /// Opens the online guides catalogue.
    let browse: () -> Void
    @ViewState private var newURL = ""
    @ViewState private var refreshing = false
    @ViewState private var refreshError: String?

    private var busy: Bool { refreshing || !downloading.isEmpty }

    var body: some View {
        Section {
            ForEach(feeds) { feed in
                SettingsFeedRow(feed: feed, refreshing: refreshing || downloading.contains(feed.id)) { remove(feed) }
            }
            HStack(spacing: 8) {
                TextField("Add guide URL", text: $newURL, prompt: Text("https://example.com/guide.xml.gz"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addURL)
                Button("Add", action: addURL)
                    .disabled(Self.normalized(newURL) == nil)
            }
            LabeledContent {
                Button("Browse Online Guides…", action: browse)
            } label: {
                Text("Free guides")
                Text("Ready-made guides by country and network — Saudi Arabia, UAE, Egypt, beIN Sports, UK, US and more.")
            }
            if let refreshError {
                Label {
                    Text(refreshError).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Global Guide Feeds")
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                }
                if !feeds.isEmpty {
                    Button("Refresh Guides") { Task { await refresh() } }
                        .controlSize(.small)
                        .disabled(busy)
                }
            }
        } footer: {
            SettingsFooter("XMLTV guides used for channels from every playlist. They fill in programs for channels whose own guide has none.")
        }
    }

    private func addURL() {
        guard let url = Self.normalized(newURL) else { return }
        newURL = ""
        guard !feeds.contains(where: { $0.url == url }) else { return }
        refreshError = nil
        Task { refreshError = await add(url) }
    }

    private func remove(_ feed: EPGFeed) {
        Task {
            try? await model.db.deleteFeed(id: feed.id)
            await reload()
            // Programmes cascade with the feed; re-point channels that used it.
            try? await model.sync.guide.resolveEPGKeys()
        }
    }

    private func refresh() async {
        refreshing = true
        refreshError = await model.sync.guide.refreshGlobalFeeds()
        refreshing = false
        await reload()
    }

    /// Accepts http(s) and file URLs; adds `https://` when the scheme is missing.
    static func normalized(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? s : nil
        case "file": return url.path.isEmpty ? nil : s
        default: return nil
        }
    }
}

private struct SettingsFeedRow: View {
    let feed: EPGFeed
    let refreshing: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let flag = SettingsCountryFlag.emoji(catalogueName?.countryCode) {
                Text(flag)
                    .font(.system(size: 22))
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.teal.gradient)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "calendar")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(feed.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                status.font(.callout)
            }
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove this guide")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(feed.url, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    /// "Saudi Arabia 1" for guides from the online catalogue.
    private var catalogueName: (title: String, countryCode: String?)? { SettingsGuideFeedName.describe(feed.url) }

    private var title: String {
        if let catalogueName { return catalogueName.title }
        if let url = URL(string: feed.url) {
            if url.isFileURL { return url.lastPathComponent }
            if let host = url.host { return host }
        }
        return feed.url
    }

    @ViewBuilder
    private var status: some View {
        if let error = feed.lastError, !error.isEmpty {
            Text(error).foregroundStyle(.red).lineLimit(2)
        } else if let date = feed.lastFetchedAt {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Updated \(SettingsRelativeDate.describe(date, now: context.date)) · \(feed.programCount.formatted()) programs · \(feed.channelCount.formatted()) channels")
            }
            .foregroundStyle(.secondary)
        } else {
            Text(refreshing ? "Loading…" : "Not loaded yet").foregroundStyle(.secondary)
        }
    }
}
