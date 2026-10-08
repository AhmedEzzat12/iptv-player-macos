#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreImage
import ImageIO
import SwiftUI
import TunerCore

/// Show page: hero with "Play S1, E1" / "Resume S2, E4", a season picker, the season's episodes as a
/// shelf of landscape cards with progress and watched marks, then the cast, synopsis and details.
/// Online metadata (Cinemeta / TMDB) fills what the provider lacks, including episode pictures and plots.
struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tunerCompact) private var compact
    @ViewState private var series: Series
    @ViewState private var info: MediaMetadata?
    @ViewState private var category: TunerCore.Category?
    @ViewState private var episodes: [Episode] = []
    @ViewState private var phase: SeriesEpisodesPhase = .loading
    /// Season chosen by the user; otherwise the page follows the next-up episode.
    @ViewState private var pickedSeason: Int?
    /// Asking whether to mark earlier unwatched episodes too (TV Time style).
    @ViewState private var earlierPrompt: EarlierEpisodesPrompt?
    /// Asking before a whole season is queued for download.
    @ViewState private var seasonDownloadPrompt: SeasonDownloadPrompt?
    /// Asking before a downloaded episode's file is deleted.
    @ViewState private var pendingDownloadDelete: DownloadItem?
    /// IMDb ratings per episode, filled in once known (the first lookup ever downloads IMDb's data sets).
    @ViewState private var episodeRatings: [EpisodeRatingKey: Double] = [:]
    @ViewState private var progress: [String: WatchProgress] = [:]
    @ViewState private var isFavorite = false
    @ViewState private var reloadToken = 0
    @ViewState private var viewHeight: CGFloat = 720

    init(series: Series) {
        _series = ViewState(initialValue: series)
    }

    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }

    private var selectedSeason: Int? {
        if let s = pickedSeason, seasons.contains(s) { return s }
        return upNext?.episode.season ?? seasons.first
    }

    private var seasonEpisodes: [Episode] {
        guard let s = selectedSeason else { return [] }
        return episodes.filter { $0.season == s }.sorted { $0.number < $1.number }
    }

    private var upNext: VODUpNext? { VODUpNext.find(episodes: episodes, progress: progress) }

    private var plot: String? { series.plot?.nilIfEmpty ?? info?.overview?.nilIfEmpty }

    /// Show artwork for episode cards without a picture of their own.
    private var episodeArtworkURL: String? {
        series.backdropURL?.nilIfEmpty ?? info?.backdropURL?.nilIfEmpty ?? series.coverURL?.nilIfEmpty ?? info?.posterURL?.nilIfEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VODDetailHeader(
                    title: series.name,
                    kindLabel: "TV Show",
                    backdropURLs: [series.backdropURL, info?.backdropURL],
                    posterURL: series.coverURL?.nilIfEmpty ?? info?.posterURL?.nilIfEmpty,
                    logoURL: info?.logoURL,
                    origin: VODOrigin.text(playlist: VODOrigin.playlist(model, sourceId: series.sourceId), category: category),
                    symbol: "tv",
                    metadata: metadata,
                    rating: VODEnrichment.rating(provider: series.rating, metadata: info),
                    genres: VODEnrichment.genres(provider: series.genre, metadata: info),
                    plot: plot,
                    isLoading: phase == .loading && !episodes.isEmpty,
                    height: VODMetrics.detailHeroHeight(for: viewHeight)
                ) {
                    ViewThatFits(in: .horizontal) {
                        actions(.full)
                        actions(.compact)
                        actions(.minimal)
                    }
                }

                VStack(alignment: .leading, spacing: 30) {
                    episodesSection
                    let cast = VODEnrichment.cast(provider: series.cast, metadata: info)
                    if !cast.isEmpty {
                        VODCastShelf(cast: cast)
                            .transition(.opacity)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        VODAboutSection(plot: plot, rows: infoRows)
                        if let info {
                            VODMetadataCredit(metadata: info)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, VODMetrics.inset)
                }
                .padding(.top, 22)
                .padding(.bottom, 48)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(VODTheme.background)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewHeight = $0 }
        .navigationTitle(series.name)
        .task(id: SeriesEpisodesLoadKey(token: reloadToken, offline: model.isOffline)) { await loadEpisodes() }
        .task(id: VODMetadataTaskKey(id: series.id, settings: model.prefs.metadataSettings)) { await loadMetadata() }
        .task(id: model.userRevision) { await loadUserState() }
        .task(id: series.categoryId) {
            category = if let id = series.categoryId { try? await model.db.category(id: id) } else { nil }
        }
        .confirmationDialog("Mark earlier episodes as watched too?",
                            isPresented: Binding(get: { earlierPrompt != nil }, set: { if !$0 { earlierPrompt = nil } }),
                            titleVisibility: .visible, presenting: earlierPrompt) { prompt in
            Button("Mark All \(prompt.earlier.count + 1) as Watched") { setWatched(prompt.earlier + [prompt.episode], watched: true) }
            Button("Only This Episode") { setWatched([prompt.episode], watched: true) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(Self.earlierMessage(prompt))
        }
        .confirmationDialog(seasonDownloadPrompt.map { "Download \(VODFormat.seasonTitle($0.season))?" } ?? "",
                            isPresented: Binding(get: { seasonDownloadPrompt != nil }, set: { if !$0 { seasonDownloadPrompt = nil } }),
                            titleVisibility: .visible, presenting: seasonDownloadPrompt) { prompt in
            Button(prompt.episodes.count == 1 ? "Download 1 Episode" : "Download \(prompt.episodes.count) Episodes") {
                model.download(episodes: prompt.episodes, of: series)
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(Self.seasonDownloadMessage(prompt, suspended: model.downloadsSuspended))
        }
        .confirmationDialog("Delete this download?",
                            isPresented: Binding(get: { pendingDownloadDelete != nil }, set: { if !$0 { pendingDownloadDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDownloadDelete) { item in
            Button("Delete Download", role: .destructive) { model.deleteDownload(item.id) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.subtitle ?? item.title) is removed from this Mac. You can still stream it or download it again.")
        }
        .task(id: VODMetadataTaskKey(id: series.id, settings: model.prefs.metadataSettings)) {
            let ratings = await model.episodeRatings(for: series)
            withAnimation(.easeOut(duration: 0.25)) { episodeRatings = ratings }
        }
    }

    // MARK: Hero

    private var metadata: [String] {
        var parts: [String] = []
        if let year = VODEnrichment.year(series.year, releaseDate: series.releaseDate, metadata: info) { parts.append(year) }
        if seasons.count > 1 {
            parts.append("\(seasons.count) Seasons")
        } else if !episodes.isEmpty {
            parts.append(episodes.count == 1 ? "1 Episode" : "\(episodes.count) Episodes")
        }
        return parts
    }

    private func actions(_ density: VODActionDensity) -> some View {
        HStack(spacing: 12) {
            Button {
                guard let next = upNext else { return }
                let s = series
                Task { await model.play(episode: next.episode, in: s) }
            } label: {
                if let next = upNext {
                    Label(density == .minimal ? (next.resume ? "Resume" : "Play") : next.label, systemImage: "play.fill")
                } else if phase == .loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.black)
                        Text("Play")
                    }
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .buttonStyle(PrimaryCapsuleButtonStyle())
            .disabled(upNext == nil)
            .opacity(upNext == nil && phase != .loading ? 0.6 : 1)

            if let next = upNext, next.resume {
                VODSecondaryButton(title: "Play from Beginning", systemImage: "arrow.counterclockwise", iconOnly: density != .full) {
                    let s = series
                    Task { await model.play(episode: next.episode, in: s, fromStart: true) }
                }
            }

            if let trailer = VODEnrichment.trailerURL(provider: series.trailer, metadata: info) {
                VODSecondaryButton(title: "Trailer", systemImage: "play.rectangle", iconOnly: density != .full) {
                    model.presentTrailer(trailer, title: series.name)
                }
            }

            if density != .minimal, let imdb = VODEnrichment.imdbURL(info) {
                VODIMDbButton(url: imdb)
                    .transition(.opacity)
            }

            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(GlassButtonStyle(circle: true))
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    private var infoRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let original = VODEnrichment.originalTitle(info, shown: [series.name, info?.title ?? ""]) { rows.append(("Original Title", original)) }
        if let v = VODEnrichment.people(provider: series.director, metadata: info?.directors) {
            rows.append((v.contains(",") ? "Directors" : "Director", v))
        }
        if let v = VODEnrichment.people(provider: nil, metadata: info?.writers) {
            rows.append((v.contains(",") ? "Writers" : "Writer", v))
        }
        let genres = VODEnrichment.genres(provider: series.genre, metadata: info)
        if !genres.isEmpty { rows.append((genres.count > 1 ? "Genres" : "Genre", genres.joined(separator: ", "))) }
        if let v = VODEnrichment.date(series.releaseDate?.nilIfEmpty ?? info?.releaseDate) { rows.append(("First Aired", v)) }
        if let v = info?.country?.nilIfEmpty { rows.append(("Country", v)) }
        rows += VODOrigin.rows(playlist: VODOrigin.playlist(model, sourceId: series.sourceId), category: category)
        return rows
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if compact {
                // Narrow screens: seasons on their own row, the count and Download below.
                VStack(alignment: .leading, spacing: 10) {
                    seasonPicker
                    if !seasonEpisodes.isEmpty {
                        HStack(spacing: 14) {
                            seasonCount
                            Spacer(minLength: 8)
                            seasonDownloadControl
                        }
                    }
                }
                .padding(.horizontal, VODMetrics.inset)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    seasonPicker
                    Spacer(minLength: 8)
                    if !seasonEpisodes.isEmpty {
                        seasonCount
                        seasonDownloadControl
                    }
                }
                .padding(.horizontal, VODMetrics.inset)
            }

            switch phase {
            case .failed(let message) where episodes.isEmpty:
                ContentUnavailableView {
                    Label("Couldn't Load Episodes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { reloadToken += 1 }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            case .loading where episodes.isEmpty:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading episodes…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            default:
                if episodes.isEmpty {
                    ContentUnavailableView("No Episodes", systemImage: "tv", description: Text("This show has no episodes available yet."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    VODShelf {
                        ForEach(seasonEpisodes) { episode in
                            SeriesEpisodeCard(
                                episode: episode,
                                series: series,
                                info: info?.episode(season: episode.season, number: episode.number),
                                artworkURL: episodeArtworkURL,
                                imdbURL: VODEnrichment.imdbEpisodesURL(info, season: episode.season),
                                progress: progress[episode.id],
                                isUpNext: upNext?.episode.id == episode.id,
                                imdbRating: episodeRatings[EpisodeRatingKey(season: episode.season, episode: episode.number)],
                                onSetWatched: { requestSetWatched(episode, watched: $0) },
                                onDeleteDownload: { pendingDownloadDelete = $0 }
                            )
                        }
                    }
                    .id(selectedSeason)
                    .transition(.opacity)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: selectedSeason)
    }

    private var seasonCount: some View {
        let watched = seasonEpisodes.filter { progress[$0.id]?.completed == true }.count
        return Text(watched > 0 ? "\(watched) of \(seasonEpisodes.count) watched" : (seasonEpisodes.count == 1 ? "1 episode" : "\(seasonEpisodes.count) episodes"))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var seasonPicker: some View {
        let list = seasons
        if list.count > 6 {
            seasonMenu(list)
        } else if list.count > 1 {
            if compact {
                // A fixed-size segmented control wider than the phone would widen the whole page; use the menu then.
                ViewThatFits(in: .horizontal) {
                    seasonSegments(list)
                    seasonMenu(list)
                }
            } else {
                seasonSegments(list)
            }
        } else {
            Text(list.first.map(VODFormat.seasonTitle) ?? "Episodes")
                .font(.title2.weight(.bold))
        }
    }

    private func seasonMenu(_ list: [Int]) -> some View {
        Menu {
            ForEach(list, id: \.self) { s in
                Button(VODFormat.seasonTitle(s)) { pickedSeason = s }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedSeason.map(VODFormat.seasonTitle) ?? "Episodes")
                    .font(.title2.weight(.bold))
                Image(systemName: "chevron.down")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func seasonSegments(_ list: [Int]) -> some View {
        Picker("Season", selection: Binding(get: { selectedSeason ?? list[0] }, set: { pickedSeason = $0 })) {
            ForEach(list, id: \.self) { s in
                Text(VODFormat.seasonTitle(s)).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: Downloads

    /// "Download Season" (asks first, with the episode count); "Downloading 3 of 10" while the season downloads;
    /// "Downloaded" once every episode is on this Mac.
    @ViewBuilder
    private var seasonDownloadControl: some View {
        let list = seasonEpisodes
        if let season = selectedSeason, !list.isEmpty {
            let downloads = list.map { model.downloadsById[$0.id] }
            let missing = zip(list, downloads).filter { $0.1 == nil || $0.1?.state == .failed }.map(\.0)
            let saved = downloads.filter { $0?.state == .completed }.count
            if missing.isEmpty {
                Button {
                    model.sidebarSelection = .downloads
                } label: {
                    Label(saved == list.count ? "Downloaded" : "Downloading \(saved) of \(list.count)",
                          systemImage: saved == list.count ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .monospacedDigit()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show in Downloads")
            } else {
                Button {
                    seasonDownloadPrompt = SeasonDownloadPrompt(season: season, episodes: missing, others: list.count - missing.count)
                } label: {
                    Label(missing.count == list.count ? "Download Season" : "Download \(missing.count) More", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(model.isOffline)
                .help(model.isOffline ? "You're offline" : "Download every episode of \(VODFormat.seasonTitle(season)) to watch offline")
            }
        }
    }

    static func seasonDownloadMessage(_ prompt: SeasonDownloadPrompt, suspended: Bool) -> String {
        let count = prompt.episodes.count
        var text = count == 1
            ? "1 episode will be saved to this Mac so you can watch it offline."
            : "\(count) episodes will be saved to this Mac, one at a time and in order, so you can watch them offline."
        if prompt.others > 0 {
            text += prompt.others == 1 ? " The other episode is already downloaded or on its way." : " The other \(prompt.others) are already downloaded or on their way."
        }
        if suspended { text += " Downloads start when you stop watching." }
        return text
    }

    // MARK: Loading

    private func loadEpisodes() async {
        phase = .loading
        let cached = (try? await model.db.episodes(seriesId: series.id)) ?? []
        if !cached.isEmpty, episodes.isEmpty {
            episodes = cached
        }
        // Offline the library's episodes are what there is (downloaded ones play); they refresh when back online.
        if model.isOffline, !episodes.isEmpty {
            phase = .loaded
            return
        }
        do {
            let fresh = try await model.sync.episodes(for: series)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) {
                episodes = fresh
                phase = .loaded
            }
            if let updated = try? await model.db.series(id: series.id) {
                withAnimation(.easeOut(duration: 0.25)) { series = updated }
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = episodes.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }

    /// Online metadata (cached → instant); fades in whatever it adds.
    private func loadMetadata() async {
        let result = await model.metadata.metadata(for: series)
        guard !Task.isCancelled, result != info else { return }
        withAnimation(.easeInOut(duration: 0.4)) { info = result }
    }

    // MARK: Watched

    /// Marking an episode watched while earlier ones aren't asks whether to mark those too (TV Time behaviour);
    /// marking unwatched only changes that episode.
    private func requestSetWatched(_ episode: Episode, watched: Bool) {
        guard watched else { return setWatched([episode], watched: false) }
        let done = Set(progress.values.filter(\.completed).map(\.mediaId))
        let earlier = EpisodeNavigation.unwatched(before: episode.id, in: episodes, watched: done)
        if earlier.isEmpty {
            setWatched([episode], watched: true)
        } else {
            earlierPrompt = EarlierEpisodesPrompt(episode: episode, earlier: earlier)
        }
    }

    private func setWatched(_ list: [Episode], watched: Bool) {
        let series = self.series
        let existing = progress
        Task { await model.setWatched(list, in: series, watched: watched, existing: existing) }
    }

    static func earlierMessage(_ prompt: EarlierEpisodesPrompt) -> String {
        let count = prompt.earlier.count
        let from = prompt.earlier.first.map { " (from \(VODFormat.episodeCode($0)))" } ?? ""
        return count == 1
            ? "1 earlier episode\(from) isn't marked as watched."
            : "\(count) earlier episodes\(from) aren't marked as watched."
    }

    private func loadUserState() async {
        let id = series.id
        progress = (try? await model.db.progress(seriesId: id)) ?? [:]
        isFavorite = (try? await model.db.isVODFavorite(mediaId: id)) ?? false
    }

    private func toggleFavorite() {
        let id = series.id
        Task {
            let value = await model.toggleVODFavorite(mediaId: id, kind: .episode)
            withAnimation(.snappy) { isFavorite = value }
        }
    }
}

private struct SeriesEpisodesLoadKey: Hashable {
    let token: Int
    let offline: Bool
}

/// A season's episodes to download (`others` are already downloaded or queued).
struct SeasonDownloadPrompt: Identifiable {
    let id = UUID()
    let season: Int
    let episodes: [Episode]
    let others: Int
}

private enum SeriesEpisodesPhase: Equatable {
    case loading
    case loaded
    case failed(String)
}

// MARK: - Episode card

/// 16:9 picture with "E3 · Title", duration and a two-line synopsis; progress bar and watched checkmark.
/// The picture follows Settings → Metadata → Episode pictures (show, blur unwatched, or hide).
private struct SeriesEpisodeCard: View {
    @Environment(AppModel.self) private var model
    let episode: Episode
    let series: Series
    /// Online metadata for this episode (title, overview, still).
    let info: EpisodeMetadata?
    /// Show artwork for episodes without a picture (and when pictures are turned off).
    let artworkURL: String?
    /// The season's episode list on IMDb.
    let imdbURL: URL?
    let progress: WatchProgress?
    let isUpNext: Bool
    /// The episode's IMDb rating (IMDb's data sets), when known.
    var imdbRating: Double?
    /// Mark as Watched/Unwatched; the show page decides whether to offer earlier episodes too.
    var onSetWatched: (Bool) -> Void = { _ in }
    /// Delete Download (the show page asks first).
    var onDeleteDownload: (DownloadItem) -> Void = { _ in }

    private let width: CGFloat = 280

    private var isWatched: Bool { progress?.completed == true }
    private var inProgress: Bool {
        guard let progress else { return false }
        return !progress.completed && progress.position > 10
    }

    private var style: EpisodeThumbnailStyle { model.prefs.episodeThumbnails }

    /// The provider's title, unless it's only a placeholder ("Episode 3", "Show S01E03") and the online
    /// catalogue has the real one.
    private var title: String {
        let own = episode.title.trimmingCharacters(in: .whitespaces)
        if Self.isPlaceholderTitle(own, episode: episode, series: series.name),
           let online = info?.title?.trimmingCharacters(in: .whitespaces).nilIfEmpty {
            return online
        }
        return own
    }

    private var heading: String {
        let title = self.title
        let prefix = episode.season == 0 ? "Special \(episode.number)" : "E\(episode.number)"
        if title.isEmpty || title.caseInsensitiveCompare("Episode \(episode.number)") == .orderedSame { return "Episode \(episode.number)" }
        return "\(prefix) · \(title)"
    }

    private var plot: String? { episode.plot?.nilIfEmpty ?? info?.overview?.nilIfEmpty }

    /// Candidate pictures, the provider's first. A provider "still" that is just the show's artwork is skipped.
    private var stillURLs: [String] {
        guard style != .hide else { return [] }
        let showArtwork = Set([series.coverURL, series.backdropURL].compactMap { $0?.nilIfEmpty })
        var urls: [String] = []
        if let own = episode.imageURL?.nilIfEmpty, !showArtwork.contains(own) { urls.append(own) }
        if let online = info?.stillURL?.nilIfEmpty, !urls.contains(online) { urls.append(online) }
        // Cinemeta lists stills its image host doesn't have for many later seasons; TVmaze's picture is next.
        if let fallback = info?.fallbackStillURL?.nilIfEmpty, !urls.contains(fallback) { urls.append(fallback) }
        return urls
    }

    var body: some View {
        Button {
            let s = series
            let e = episode
            Task { await model.play(episode: e, in: s) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                still
                    .padding(.bottom, 4)
                Text(heading)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let imdbRating { IMDbRatingBadge(rating: imdbRating) }
                    if isUpNext {
                        Text(inProgress ? "CONTINUE" : "UP NEXT")
                            .font(.caption2.weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(Color.accentColor)
                    }
                    if let d = episode.durationSeconds, d > 0 {
                        Text(Fmt.duration(Double(d)))
                    }
                    if let progress, inProgress {
                        Text(VODFormat.timeLeft(progress))
                    }
                    if let air = VODEnrichment.date(episode.airDate?.nilIfEmpty ?? info?.airDate) {
                        Text(air)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let plot {
                    Text(plot)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                let s = series
                let e = episode
                Task { await model.play(episode: e, in: s) }
            } label: {
                Label(inProgress ? "Resume" : "Play", systemImage: "play.fill")
            }
            if inProgress {
                Button {
                    let s = series
                    let e = episode
                    Task { await model.play(episode: e, in: s, fromStart: true) }
                } label: {
                    Label("Play from Beginning", systemImage: "arrow.counterclockwise")
                }
            }
            Divider()
            Button {
                onSetWatched(!isWatched)
            } label: {
                Label(isWatched ? "Mark as Unwatched" : "Mark as Watched", systemImage: isWatched ? "eye.slash" : "checkmark.circle")
            }
            Divider()
            EpisodeDownloadMenuItems(episode: episode, series: series, confirmDelete: onDeleteDownload)
            Divider()
            Button {
                VODActions.copyToPasteboard("\(series.name) – \(VODFormat.episodeCode(episode)) – \(title)")
            } label: {
                Label("Copy Title", systemImage: "doc.on.doc")
            }
            if let imdbURL {
                Button {
                    NSWorkspace.shared.open(imdbURL)
                } label: {
                    Label("View on IMDb", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private var still: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                SeriesEpisodePicture(
                    stillURLs: stillURLs,
                    artworkURL: artworkURL,
                    seriesName: series.name,
                    number: episode.season == 0 ? "SP\(episode.number)" : "E\(episode.number)",
                    blurred: style == .blurUnwatched && !isWatched
                )
            }
            .overlay {
                if isWatched {
                    Color.black.opacity(0.35)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress, inProgress {
                    ProgressCapsule(fraction: progress.fraction, height: 4, tint: .white)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                DownloadStatusBadge(item: model.downloadsById[episode.id], size: 22)
                    .padding(8)
                    .animation(.smooth(duration: 0.25), value: model.downloadsById[episode.id]?.state)
            }
            .clipShape(RoundedRectangle(cornerRadius: VODMetrics.landscapeCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VODMetrics.landscapeCorner, style: .continuous)
                    .strokeBorder(isUpNext ? Color.accentColor.opacity(0.8) : .white.opacity(0.08), lineWidth: isUpNext ? 2 : 1)
            }
            .hoverLift()
    }

    /// Titles that only restate the episode number or the show ("Episode 3", "Show S01E03", "1x03", "3").
    static func isPlaceholderTitle(_ title: String, episode: Episode, series: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.caseInsensitiveCompare(series.trimmingCharacters(in: .whitespaces)) == .orderedSame { return true }
        let patterns = [
            #"^(episode|episodio|épisode|folge|ep\.?|e)\s*\d+$"#,
            #"^\d+$"#,
            #"s\d{1,3}\s*[\.\-_ ]?\s*e\d{1,4}"#,
            #"\b\d{1,2}x\d{1,3}\b"#,
        ]
        return patterns.contains { t.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

}

/// An episode's picture: the first candidate still that loads and is landscape (providers sometimes send
/// the show's poster as the "still"), else the show's artwork with a large episode number. When unwatched
/// episodes are spoiler-protected, a heavily blurred copy (with an eye-slash glyph) is shown instead; the
/// sharp picture is never displayed for them, not even while loading.
struct SeriesEpisodePicture: View {
    let stillURLs: [String]
    let artworkURL: String?
    let seriesName: String
    let number: String
    let blurred: Bool

    @ViewState private var image: CGImage?
    /// Which candidate (and variant) `image` is, e.g. "blur|https://…".
    @ViewState private var imageKey: String?
    /// True once every candidate was tried (or there are none): show the episode number on the artwork.
    @ViewState private var resolved = false

    private var showsBlurred: Bool { imageKey?.hasPrefix(Self.blurPrefix) == true }
    private static let blurPrefix = "blur|"

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .overlay {
                        if showsBlurred {
                            ZStack {
                                Color.black.opacity(0.12)
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .shadow(color: .black.opacity(0.4), radius: 4)
                            }
                            .help("Blurred until you've watched it")
                        }
                    }
                    .transition(.opacity)
            } else {
                artwork
            }
        }
        .accessibilityHidden(true)
        .task(id: SeriesStillRequest(urls: stillURLs, blurred: blurred)) { await load() }
    }

    private var artwork: some View {
        Color.clear
            .overlay {
                RemoteImage(url: artworkURL) { VODArtworkPlaceholder(title: seriesName, symbol: "tv") }
            }
            .overlay(Color.black.opacity(resolved ? 0.45 : 0.15))
            .overlay {
                if resolved {
                    Text(number)
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.45), radius: 8)
                        .transition(.opacity)
                }
            }
            .transition(.opacity)
    }

    private func load() async {
        let blurred = blurred
        for url in stillURLs {
            let key = (blurred ? Self.blurPrefix : "") + url
            if key == imageKey, image != nil { return }
            if let loaded = await VODStillLoader.still(url, blurred: blurred) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    image = loaded
                    imageKey = key
                }
                return
            }
            if Task.isCancelled { return }
        }
        withAnimation(.easeOut(duration: 0.25)) {
            image = nil
            imageKey = nil
            resolved = true
        }
    }
}

private struct SeriesStillRequest: Hashable {
    let urls: [String]
    let blurred: Bool
}

/// Loads episode stills downsampled for cards, rejecting portrait images (posters sent as stills), and
/// makes the blurred spoiler-free variants. Results are kept in memory so switching seasons is instant.
enum VODStillLoader {
    private final class Entry {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 400
        return cache
    }()

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// The still for a card (sharp or heavily blurred), or nil when it can't be loaded or isn't landscape.
    static func still(_ urlString: String, blurred: Bool) async -> CGImage? {
        guard let sharp = await landscapeImage(urlString) else { return nil }
        guard blurred else { return sharp }
        let key = "blur|\(urlString)" as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        let soft = blur(sharp)
        cache.setObject(Entry(soft), forKey: key)
        return soft
    }

    /// A landscape image no larger than `maxPixel` on its long side, or nil.
    static func landscapeImage(_ urlString: String, maxPixel: Int = 720) async -> CGImage? {
        let key = urlString as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        guard let url = URL(string: urlString), url.scheme != nil,
              let (data, response) = try? await URLSession.shared.data(from: url)
        else { return nil }  // network failures aren't cached, so they're retried next time
        var image: CGImage?
        if (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
            image = decode(data, maxPixel: maxPixel)
        }
        cache.setObject(Entry(image), forKey: key)
        return image
    }

    private static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) / Double(height) >= 1.2
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Heavy Gaussian blur on a small copy (cheap, and nothing recognisable survives). Baked into the
    /// image rather than a live view filter, so a shelf of blurred cards costs nothing to scroll.
    private static func blur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let scale = min(1, 240 / CGFloat(max(image.width, 1)))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent.integral
        let output = small.clampedToExtent().applyingGaussianBlur(sigma: 9).cropped(to: extent)
        return ciContext.createCGImage(output, from: extent)
    }
}

/// An episode being marked watched and the earlier unwatched episodes to offer as well.
struct EarlierEpisodesPrompt: Identifiable {
    let id = UUID()
    let episode: Episode
    let earlier: [Episode]
}
