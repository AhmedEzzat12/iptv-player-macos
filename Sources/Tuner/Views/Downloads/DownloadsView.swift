#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

/// Downloads, TV app style: storage header with Pause All / Resume All, then Movies, then TV Shows grouped by show
/// with their episodes in order. Every row shows its state (progress, speed, queued, paused, failed) and its actions;
/// completed ones play from this Mac, also offline. Movie and show pages open in place.
struct DownloadsView: View {
    @ViewState private var path: [VODRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            DownloadsContent { path.append($0) }
                .vodDestinations()
        }
    }
}

private struct DownloadsContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tunerCompact) private var compact
    let open: (VODRoute) -> Void

    /// Library records of the downloaded shows (artwork, and the show page), by series id.
    @ViewState private var shows: [String: Series] = [:]
    /// Library records of the downloaded movies (landscape artwork), by id.
    @ViewState private var movieRecords: [String: Movie] = [:]
    @ViewState private var freeSpace: Int64?
    @ViewState private var pendingRemoval: DownloadRemoval?

    private var items: [DownloadItem] { model.downloadItems }
    private var movies: [DownloadItem] { items.filter { $0.kind == .movie } }

    /// Shows, the most recently downloaded first; episodes in watch order.
    private var showGroups: [DownloadShowGroup] {
        let episodes = items.filter { $0.kind == .episode }
        let grouped = Dictionary(grouping: episodes) { $0.seriesId ?? "title:\($0.title)" }
        return grouped.map { key, list in
            DownloadShowGroup(
                id: key,
                seriesId: list.first?.seriesId,
                title: list.first?.title ?? "",
                episodes: list.sorted { ($0.season ?? 0, $0.episode ?? 0, $0.createdAt) < ($1.season ?? 0, $1.episode ?? 0, $1.createdAt) },
                latest: list.map(\.createdAt).max() ?? .distantPast
            )
        }
        .sorted { $0.latest > $1.latest }
    }

    private var totalOnDisk: Int64 { items.map(DownloadFormat.sizeOnDisk).reduce(0, +) }
    private var canPauseAll: Bool { items.contains(where: \.isPending) }
    private var canResumeAll: Bool { items.contains { $0.isPausedByUser || $0.state == .failed } }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if items.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: max(340, proxy.size.height - 220))
                    } else {
                        notice
                        if !movies.isEmpty { moviesSection }
                        let groups = showGroups
                        if !groups.isEmpty { showsSection(groups) }
                    }
                }
                .padding(.horizontal, VODMetrics.inset)
                .padding(.top, 14)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.smooth(duration: 0.3), value: items.map(\.id))
            }
        }
        .background(VODTheme.background)
        .navigationTitle("Downloads")
        .task(id: Set(items.map { $0.seriesId ?? $0.id })) { await loadRecords() }
        .task(id: model.prefs.downloadsPath) { await refreshFreeSpaceLoop() }
        .task { await model.refreshDownloads() }
        .confirmationDialog(pendingRemoval?.title ?? "", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: pendingRemoval) { removal in
            Button(removal.confirmTitle, role: .destructive) {
                for item in removal.items {
                    item.state == .completed ? model.deleteDownload(item.id) : model.cancelDownload(item.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if compact {
            // iPhone: the title and storage line get the full width; Pause All / Resume All go underneath.
            VStack(alignment: .leading, spacing: 12) {
                headerTitle
                if canPauseAll || canResumeAll {
                    HStack(spacing: 10) { headerButtons }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                headerTitle
                Spacer(minLength: 12)
                headerButtons
            }
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Downloads")
                .font(.system(size: 34, weight: .bold))
            if !items.isEmpty || freeSpace != nil {
                Label(storageLine, systemImage: "internaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var headerButtons: some View {
        Group {
            if canPauseAll {
                Button { model.pauseAllDownloads() } label: { Label("Pause All", systemImage: "pause.fill") }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
            if canResumeAll {
                Button { model.resumeAllDownloads() } label: { Label("Resume All", systemImage: "arrow.down") }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(model.isOffline)
            }
        }
        .controlSize(compact ? .regular : .large)
    }

    private var storageLine: String {
        var parts: [String] = []
        if !items.isEmpty { parts.append("\(DownloadFormat.bytes(totalOnDisk)) on this \(DownloadFormat.deviceName)") }
        if let freeSpace { parts.append("\(DownloadFormat.bytes(freeSpace)) available") }
        return parts.joined(separator: " · ")
    }

    /// Why nothing is moving: offline, or waiting for the player on a single-connection account.
    @ViewBuilder
    private var notice: some View {
        if model.isOffline {
            DownloadsNotice(symbol: "wifi.slash", tint: .orange, title: "You're offline",
                            message: "Downloaded movies and episodes play as usual. Unfinished downloads continue when you're back online.")
        } else if model.downloadsSuspended, canPauseAll {
            DownloadsNotice(symbol: "pause.circle.fill", tint: .accentColor, title: "Paused while you watch",
                            message: "Your account allows one stream at a time, so downloads wait and continue when you stop watching.")
        }
    }

    // MARK: Sections

    private var moviesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Movies", subtitle: countText(movies.count, "movie"))
            VStack(spacing: 0) {
                ForEach(Array(movies.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, rowDividerInset) }
                    row(item)
                }
            }
            .recordingsPlatter()
        }
    }

    private func showsSection(_ groups: [DownloadShowGroup]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "TV Shows", subtitle: countText(groups.count, "show"))
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    VStack(spacing: 0) {
                        showHeader(group)
                        ForEach(group.episodes) { item in
                            Divider().padding(.leading, rowDividerInset)
                            row(item)
                        }
                    }
                    .recordingsPlatter()
                }
            }
        }
    }

    /// Where row dividers start: under the text, past the thumbnail.
    private var rowDividerInset: CGFloat { compact ? 16 + DownloadRow.compactThumbnailWidth + 12 : 196 }

    private func showHeader(_ group: DownloadShowGroup) -> some View {
        let series = group.seriesId.flatMap { shows[$0] }
        let saved = group.episodes.filter { $0.state == .completed }
        let size = group.episodes.map(DownloadFormat.sizeOnDisk).reduce(0, +)
        return HStack(spacing: 14) {
            Color.clear
                .frame(width: 44, height: 66)
                .overlay {
                    RemoteImage(url: series?.coverURL?.nilIfEmpty ?? group.episodes.first?.artworkURL) {
                        VODArtworkPlaceholder(title: group.title, symbol: "tv")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .lineLimit(1)
                Text(showSummary(total: group.episodes.count, saved: saved.count, size: size))
                    .font(compact ? .subheadline : .callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            // iPhone: "Go to Show" lives in the "…" menu (and on the show's artwork) to leave room for the title.
            if let series, !compact {
                Button { open(.series(series)) } label: {
                    HStack(spacing: 4) {
                        Text("Go to Show")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                }
                .buttonStyle(.borderless)
                .help("Open \(group.title)")
            }
            Menu {
                if let series {
                    Button { open(.series(series)) } label: { Label("Go to Show", systemImage: "tv") }
                    Divider()
                }
                Button(role: .destructive) {
                    pendingRemoval = DownloadRemoval(items: group.episodes, name: group.title, isShow: true)
                } label: {
                    Label("Delete All Episodes…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(DownloadsIconButtonStyle())
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ item: DownloadItem) -> some View {
        DownloadRow(
            item: item,
            artwork: artwork(for: item),
            speed: model.downloadSpeeds[item.id],
            suspended: model.downloadsSuspended,
            offline: model.isOffline,
            onPlay: { Task { await model.playDownload(item) } },
            onPause: { model.pauseDownload(item.id) },
            onResume: { model.resumeDownload(item.id) },
            onRemove: { requestRemoval(item) },
            onReveal: { DownloadActions.reveal(item, model: model) },
            onOpen: { Task { await openDetail(item) } }
        )
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Downloads", systemImage: "arrow.down.circle")
        } description: {
            Text("Download movies and episodes to watch them without an internet connection.\nOn a movie's page, choose Download. On a show's page, right-click an episode and choose Download Episode, or use Download Season.")
        } actions: {
            HStack(spacing: 10) {
                Button("Browse Movies") { model.sidebarSelection = .movies }
                Button("Browse TV Shows") { model.sidebarSelection = .series }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    // MARK: Helpers

    private func countText(_ count: Int, _ noun: String) -> String? {
        count > 1 ? "\(count) \(noun)s" : nil
    }

    private func showSummary(total: Int, saved: Int, size: Int64) -> String {
        let episodes = total == 1 ? "1 episode" : "\(total) episodes"
        var parts = [saved == total ? episodes : "\(saved) of \(episodes) downloaded"]
        if size > 0 { parts.append(DownloadFormat.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    /// Unfinished downloads with nothing saved yet are removed without asking.
    private func requestRemoval(_ item: DownloadItem) {
        if item.state != .completed, item.receivedBytes == 0 {
            model.cancelDownload(item.id)
        } else {
            pendingRemoval = DownloadRemoval(items: [item], name: displayName(item), isShow: false)
        }
    }

    private func displayName(_ item: DownloadItem) -> String {
        guard item.kind == .episode, let subtitle = item.subtitle?.nilIfEmpty else { return item.title }
        return "\(item.title) · \(subtitle)"
    }

    private func openDetail(_ item: DownloadItem) async {
        switch item.kind {
        case .movie:
            if let movie = try? await model.db.movie(id: item.id) { open(.movie(movie)) }
        case .episode:
            guard let id = item.seriesId else { return }
            if let series = (try? await model.db.series(id: id)) ?? shows[id] { open(.series(series)) }
        }
    }

    /// Landscape artwork when there is some (movie backdrop, episode still, show backdrop); otherwise the poster.
    private func artwork(for item: DownloadItem) -> DownloadArtwork {
        switch item.kind {
        case .movie:
            let movie = movieRecords[item.id]
            return DownloadArtwork(landscapeURL: movie?.backdropURL?.nilIfEmpty, posterURL: item.artworkURL ?? movie?.posterURL)
        case .episode:
            let series = item.seriesId.flatMap { shows[$0] }
            let cover = series?.coverURL?.nilIfEmpty
            // The service falls back to the show's cover when an episode has no picture of its own.
            let still = item.artworkURL?.nilIfEmpty.flatMap { $0 == cover ? nil : $0 }
            return DownloadArtwork(landscapeURL: still ?? series?.backdropURL?.nilIfEmpty, posterURL: cover ?? item.artworkURL)
        }
    }

    private func loadRecords() async {
        var foundShows = shows
        for id in Set(items.compactMap(\.seriesId)) where foundShows[id] == nil {
            if let series = try? await model.db.series(id: id) { foundShows[id] = series }
        }
        var foundMovies = movieRecords
        for item in items where item.kind == .movie && foundMovies[item.id] == nil {
            if let movie = try? await model.db.movie(id: item.id) { foundMovies[item.id] = movie }
        }
        if foundShows != shows { shows = foundShows }
        if foundMovies != movieRecords { movieRecords = foundMovies }
    }

    private func refreshFreeSpaceLoop() async {
        while !Task.isCancelled {
            let path = model.prefs.downloadsPath
            let free = await Task.detached(priority: .utility) { DownloadActions.availableCapacity(at: path) }.value
            if free != freeSpace { freeSpace = free }
            try? await Task.sleep(for: .seconds(15))
        }
    }
}

// MARK: - Model

private struct DownloadArtwork {
    var landscapeURL: String?
    var posterURL: String?
}

private struct DownloadShowGroup: Identifiable {
    let id: String
    let seriesId: String?
    let title: String
    let episodes: [DownloadItem]
    let latest: Date
}

/// Downloads to remove after confirmation (one item, or all of a show's episodes).
private struct DownloadRemoval: Identifiable {
    let id = UUID()
    let items: [DownloadItem]
    let name: String
    let isShow: Bool

    private var hasUnfinished: Bool { items.contains { $0.state != .completed } }
    private var allUnfinished: Bool { items.allSatisfy { $0.state != .completed } }

    var title: String {
        if isShow { return "Delete all downloaded episodes of “\(name)”?" }
        return allUnfinished ? "Cancel downloading “\(name)”?" : "Delete the download of “\(name)”?"
    }

    var confirmTitle: String {
        if isShow { return items.count == 1 ? "Delete Episode" : "Delete \(items.count) Episodes" }
        return allUnfinished ? "Cancel Download" : "Delete Download"
    }

    var message: String {
        if allUnfinished { return "What's been downloaded so far is discarded." }
        return hasUnfinished
            ? "Saved files are removed from this Mac and unfinished downloads are cancelled. You can still stream them or download them again."
            : "The file is removed from this Mac. You can still stream it or download it again."
    }
}

// MARK: - Notice

private struct DownloadsNotice: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .recordingsPlatter()
    }
}

// MARK: - Row

/// One download: artwork, title and subtitle, its state (progress bar with size, speed and time left; queued; paused;
/// failed; downloaded), and Play / Pause / Resume / Cancel or Delete / Show in Finder.
private struct DownloadRow: View {
    let item: DownloadItem
    let artwork: DownloadArtwork
    let speed: Double?
    let suspended: Bool
    let offline: Bool
    let onPlay: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void
    let onOpen: () -> Void

    @ViewState private var hovering = false
    @Environment(\.tunerCompact) private var compact

    static let compactThumbnailWidth: CGFloat = 112

    private var isDone: Bool { item.state == .completed }

    /// Movies: the title. Episodes: "E3 · Pilot" (the show is the group's header).
    private var heading: String {
        guard item.kind == .episode else { return item.title }
        if let title = AppModel.episodeTitle(fromSubtitle: item.subtitle) {
            return item.episode.map { "E\($0) · \(title)" } ?? title
        }
        return item.subtitle ?? item.title
    }

    private var detail: String? {
        switch item.kind {
        case .movie: item.subtitle?.nilIfEmpty
        case .episode: item.season.map { $0 == 0 ? "Specials" : "Season \($0)" }
        }
    }

    var body: some View {
        HStack(spacing: compact ? 12 : 16) {
            Button(action: isDone ? onPlay : onOpen) { thumbnail }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(isDone ? "Play" : "Open")

            VStack(alignment: .leading, spacing: 5) {
                Text(heading)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(compact ? 2 : 1)
                if let detail {
                    Text(detail)
                        .font(compact ? .footnote : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if compact { compactActions } else { actions }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, compact ? 10 : 12)
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    // MARK: Artwork

    private var thumbnail: some View {
        Color.clear
            .frame(width: compact ? Self.compactThumbnailWidth : 164, height: compact ? 63 : 92)
            .overlay { picture }
            .overlay {
                if isDone, hovering {
                    ZStack {
                        Color.black.opacity(0.25)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, .white.opacity(0.92))
                            .shadow(color: .black.opacity(0.3), radius: 6)
                    }
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if !isDone {
                    DownloadStatusBadge(item: item, size: compact ? 18 : 22).padding(compact ? 4 : 6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .opacity(item.state == .failed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
    }

    /// The landscape picture, or the poster centred on a blurred copy of itself.
    @ViewBuilder
    private var picture: some View {
        let symbol = item.kind == .movie ? "film" : "tv"
        if let landscape = artwork.landscapeURL {
            RemoteImage(url: landscape) {
                posterPicture(symbol: symbol)
            }
        } else {
            posterPicture(symbol: symbol)
        }
    }

    @ViewBuilder
    private func posterPicture(symbol: String) -> some View {
        if let poster = artwork.posterURL {
            ZStack {
                RemoteImage(url: poster) { VODArtworkPlaceholder(title: item.title, symbol: symbol) }
                    .scaleEffect(1.4)
                    .blur(radius: 18, opaque: true)
                    .overlay(Color.black.opacity(0.2))
                RemoteImage(url: poster, contentMode: .fit) { Color.clear }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .padding(.vertical, 7)
            }
        } else {
            VODArtworkPlaceholder(title: item.title, symbol: symbol)
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .downloading:
            progressStack {
                progressBar(dimmed: false)
                Text(DownloadFormat.progressLine(item, speed: speed))
                    .lineLimit(1)
            }
            .font(compact ? .footnote : .callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        case .queued:
            Label(queuedText, systemImage: item.error == nil || suspended ? "clock" : "arrow.clockwise")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .paused:
            progressStack {
                if item.fraction != nil { progressBar(dimmed: true) }
                Text(pausedText)
                    .lineLimit(1)
            }
            .font(compact ? .footnote : .callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        case .completed:
            Label {
                Text("Downloaded · \(DownloadFormat.bytes(DownloadFormat.sizeOnDisk(item)))")
            } icon: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            }
            .font(compact ? .footnote : .callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        case .failed:
            Label(item.error?.nilIfEmpty ?? "The download didn't finish", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var queuedText: String {
        if suspended { return "Waiting — paused while you watch" }
        if offline { return "Waiting for a connection" }
        // A network problem: the service tries again after a short wait.
        return item.error?.nilIfEmpty ?? "Waiting to download"
    }

    private var pausedText: String {
        var parts = [item.pausedByUser ? "Paused" : (offline ? "Waiting for a connection" : "Paused while you watch")]
        if let total = item.totalBytes, total > 0 {
            parts.append("\(DownloadFormat.bytes(item.receivedBytes)) of \(DownloadFormat.bytes(total))")
        }
        return parts.joined(separator: " · ")
    }

    /// Progress bar and text side by side; on iPhone stacked, with the bar as wide as the column.
    @ViewBuilder
    private func progressStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 5) { content() }
        } else {
            HStack(spacing: 10) { content() }
        }
    }

    private func progressBar(dimmed: Bool) -> some View {
        ProgressCapsule(fraction: item.fraction ?? 0, height: 5, tint: dimmed ? Color.secondary : Color.accentColor)
            .frame(width: compact ? nil : 180)
            .frame(maxWidth: compact ? .infinity : nil)
    }

    /// iPhone: one round button (pause or resume while downloading, try again when it failed) and the "…" menu
    /// with everything else; a finished download plays from its thumbnail.
    private var compactActions: some View {
        HStack(spacing: 6) {
            switch item.state {
            case .queued, .downloading, .paused:
                if item.isPausedByUser {
                    Button(action: onResume) { Image(systemName: "arrow.down") }
                        .buttonStyle(DownloadsIconButtonStyle())
                        .accessibilityLabel("Resume")
                        .disabled(offline)
                } else {
                    Button(action: onPause) { Image(systemName: "pause.fill") }
                        .buttonStyle(DownloadsIconButtonStyle())
                        .accessibilityLabel("Pause")
                }
            case .failed:
                Button(action: onResume) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(DownloadsIconButtonStyle())
                    .accessibilityLabel("Try Again")
                    .disabled(offline)
            case .completed:
                EmptyView()
            }
            Menu { menu } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(DownloadsIconButtonStyle())
                .accessibilityLabel("More")
        }
        .fixedSize()
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch item.state {
            case .completed:
                Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(DownloadsCapsuleButtonStyle())
                Button(action: onReveal) { Image(systemName: "folder") }
                    .buttonStyle(DownloadsIconButtonStyle())
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
                Button(action: onRemove) { Image(systemName: "trash") }
                    .buttonStyle(DownloadsIconButtonStyle())
                    .help("Delete Download")
                    .accessibilityLabel("Delete Download")
            case .queued, .downloading, .paused:
                if item.isPausedByUser {
                    Button(action: onResume) { Image(systemName: "arrow.down") }
                        .buttonStyle(DownloadsIconButtonStyle())
                        .help("Resume")
                        .accessibilityLabel("Resume")
                        .disabled(offline)
                } else {
                    Button(action: onPause) { Image(systemName: "pause.fill") }
                        .buttonStyle(DownloadsIconButtonStyle())
                        .help("Pause")
                        .accessibilityLabel("Pause")
                }
                Button(action: onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(DownloadsIconButtonStyle())
                    .help("Cancel Download")
                    .accessibilityLabel("Cancel Download")
            case .failed:
                Button(action: onResume) { Label("Try Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(DownloadsCapsuleButtonStyle(prominent: false))
                    .disabled(offline)
                Button(action: onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(DownloadsIconButtonStyle())
                    .help("Remove")
                    .accessibilityLabel("Remove")
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var menu: some View {
        switch item.state {
        case .completed:
            Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
        case .queued, .downloading, .paused:
            if item.isPausedByUser {
                Button(action: onResume) { Label("Resume Download", systemImage: "arrow.down") }
            } else {
                Button(action: onPause) { Label("Pause Download", systemImage: "pause") }
            }
        case .failed:
            Button(action: onResume) { Label("Try Again", systemImage: "arrow.clockwise") }
        }
        Button(action: onOpen) {
            Label(item.kind == .movie ? "Go to Movie" : "Go to Show", systemImage: "info.circle")
        }
        #if os(macOS)
        Button(action: onReveal) { Label("Show in Finder", systemImage: "folder") }
        #else
        Button(action: onReveal) { Label("Show in Files", systemImage: "folder") }
        #endif
        Divider()
        Button(role: .destructive, action: onRemove) {
            Label(isDone ? "Delete Download…" : "Cancel Download", systemImage: isDone ? "trash" : "xmark")
        }
    }
}

// MARK: - Button styles

/// Round icon button on the list platters (adapts to light and dark).
struct DownloadsIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DownloadsIconButton(configuration: configuration)
    }

    private struct DownloadsIconButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.2 : (hovering ? 0.13 : 0.08))))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// TV app capsule ("Play"): solid in the primary colour, or a quiet tinted one.
struct DownloadsCapsuleButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .foregroundStyle(prominent ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background(Capsule().fill(prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.08))))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
