#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

/// Movie page: backdrop hero with poster, title (or title logo), metadata and Play/Resume, then the cast,
/// the synopsis and details. Provider details (plot, cast, backdrop, duration…) are fetched lazily and merged
/// in, and online metadata (Cinemeta / TMDB) fills what the provider lacks — it never blocks the page.
struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var movie: Movie
    @ViewState private var info: MediaMetadata?
    @ViewState private var category: TunerCore.Category?
    @ViewState private var progress: WatchProgress?
    @ViewState private var isFavorite = false
    @ViewState private var loadingDetails = false
    @ViewState private var viewHeight: CGFloat = 720

    init(movie: Movie) {
        _movie = ViewState(initialValue: movie)
    }

    private var canResume: Bool {
        guard let progress else { return false }
        return model.prefs.resumePlayback && !progress.completed && progress.position > 10
    }

    private var plot: String? { movie.plot?.nilIfEmpty ?? info?.overview?.nilIfEmpty }
    private var cast: [CastMember] { VODEnrichment.cast(provider: movie.cast, metadata: info) }
    private var trailerURL: URL? { VODEnrichment.trailerURL(provider: movie.trailer, metadata: info) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VODDetailHeader(
                    title: movie.name,
                    kindLabel: "Movie",
                    backdropURLs: [movie.backdropURL, info?.backdropURL],
                    posterURL: movie.posterURL?.nilIfEmpty ?? info?.posterURL?.nilIfEmpty,
                    logoURL: info?.logoURL,
                    origin: VODOrigin.text(playlist: VODOrigin.playlist(model, sourceId: movie.sourceId), category: category),
                    symbol: "film",
                    metadata: metadata,
                    rating: VODEnrichment.rating(provider: movie.rating, metadata: info),
                    genres: VODEnrichment.genres(provider: movie.genre, metadata: info),
                    plot: plot,
                    isLoading: loadingDetails,
                    height: VODMetrics.detailHeroHeight(for: viewHeight)
                ) {
                    ViewThatFits(in: .horizontal) {
                        actions(.full)
                        actions(.compact)
                        actions(.minimal)
                    }
                }

                VStack(alignment: .leading, spacing: 28) {
                    if canResume, let progress {
                        HStack(spacing: 10) {
                            ProgressCapsule(fraction: progress.fraction, height: 5)
                                .frame(width: 160)
                            Text(VODFormat.timeLeft(progress))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, VODMetrics.inset)
                    }
                    let cast = cast
                    if !cast.isEmpty {
                        VODCastShelf(cast: cast)
                            .transition(.opacity)
                    }
                    if model.prefs.aiRecommendations {
                        VODMoreLikeThisShelf(item: .movie(movie), metadata: info)
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
        .navigationTitle(movie.name)
        .task(id: MovieDetailLoadKey(id: movie.id, offline: model.isOffline)) { await loadDetails() }
        .task(id: VODMetadataTaskKey(id: movie.id, settings: model.prefs.metadataSettings)) { await loadMetadata() }
        .task(id: model.userRevision) { await loadUserState() }
        .task(id: movie.categoryId) {
            category = if let id = movie.categoryId { try? await model.db.category(id: id) } else { nil }
        }
    }

    // MARK: Content

    private var metadata: [String] {
        var parts: [String] = []
        if let year = VODEnrichment.year(movie.year, releaseDate: movie.releaseDate, metadata: info) { parts.append(year) }
        if let d = VODEnrichment.runtimeSeconds(provider: movie.durationSeconds, metadata: info) { parts.append(Fmt.duration(Double(d))) }
        if let ext = movie.containerExtension?.nilIfEmpty { parts.append(ext.uppercased()) }
        if progress?.completed == true { parts.append("Watched") }
        return parts
    }

    private var infoRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let original = VODEnrichment.originalTitle(info, shown: [movie.name, info?.title ?? ""]) { rows.append(("Original Title", original)) }
        if let v = VODEnrichment.people(provider: movie.director, metadata: info?.directors) {
            rows.append((v.contains(",") ? "Directors" : "Director", v))
        }
        if let v = VODEnrichment.people(provider: nil, metadata: info?.writers) {
            rows.append((v.contains(",") ? "Writers" : "Writer", v))
        }
        let genres = VODEnrichment.genres(provider: movie.genre, metadata: info)
        if !genres.isEmpty { rows.append((genres.count > 1 ? "Genres" : "Genre", genres.joined(separator: ", "))) }
        if let v = VODEnrichment.date(movie.releaseDate?.nilIfEmpty ?? info?.releaseDate) { rows.append(("Released", v)) }
        if let d = VODEnrichment.runtimeSeconds(provider: movie.durationSeconds, metadata: info) { rows.append(("Duration", Fmt.duration(Double(d)))) }
        if let v = info?.country?.nilIfEmpty { rows.append(("Country", v)) }
        if let ext = movie.containerExtension?.nilIfEmpty { rows.append(("Format", ext.uppercased())) }
        rows += VODOrigin.rows(playlist: VODOrigin.playlist(model, sourceId: movie.sourceId), category: category)
        return rows
    }

    private func actions(_ density: VODActionDensity) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.play(movie: movie) }
            } label: {
                if canResume, let progress {
                    Label(density == .minimal ? "Resume" : "Resume (\(VODFormat.timeLeft(progress)))", systemImage: "play.fill")
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .buttonStyle(PrimaryCapsuleButtonStyle())

            if canResume {
                VODSecondaryButton(title: "Play from Beginning", systemImage: "arrow.counterclockwise", iconOnly: density != .full) {
                    Task { await model.play(movie: movie, fromStart: true) }
                }
            }

            MovieDownloadButton(movie: movie, density: density)

            if let trailer = trailerURL {
                VODSecondaryButton(title: "Trailer", systemImage: "play.rectangle", iconOnly: density != .full) {
                    model.presentTrailer(trailer, title: movie.name)
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

            Menu {
                Button(progress?.completed == true ? "Mark as Unwatched" : "Mark as Watched") { toggleWatched() }
                if progress != nil, progress?.completed != true {
                    Button("Remove from Continue Watching") {
                        let id = movie.id
                        Task { try? await model.db.deleteProgress(mediaId: id) }
                    }
                }
                if let imdb = VODEnrichment.imdbURL(info) {
                    Divider()
                    Button("View on IMDb") { NSWorkspace.shared.open(imdb) }
                }
                Divider()
                Button("Copy Title") { VODActions.copyToPasteboard(movie.name) }
                Button("Copy Stream URL") { VODActions.copyStreamURL(movie, model: model) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(GlassButtonStyle(circle: true))
            .fixedSize()
            .help("More")
        }
    }

// MARK: Loading & actions

    private func loadDetails() async {
        if let fresh = try? await model.db.movie(id: movie.id) { movie = fresh }
        // Offline the page shows what the library has (downloads still play); details load next time.
        guard !model.isOffline else { return }
        loadingDetails = true
        defer { loadingDetails = false }
        guard let details = try? await model.sync.movieDetails(movie), !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) { movie = merged(movie, details) }
    }

    /// Online metadata (cached → instant); fades in whatever it adds.
    private func loadMetadata() async {
        let result = await model.metadata.metadata(for: movie)
        guard !Task.isCancelled, result != info else { return }
        withAnimation(.easeInOut(duration: 0.4)) { info = result }
    }

    private func merged(_ m: Movie, _ d: VODDetails) -> Movie {
        var m = m
        m.plot = d.plot?.nilIfEmpty ?? m.plot
        m.cast = d.cast?.nilIfEmpty ?? m.cast
        m.director = d.director?.nilIfEmpty ?? m.director
        m.genre = d.genre?.nilIfEmpty ?? m.genre
        m.releaseDate = d.releaseDate?.nilIfEmpty ?? m.releaseDate
        if let r = d.rating, r > 0 { m.rating = r }
        if let s = d.durationSeconds, s > 0 { m.durationSeconds = s }
        m.backdropURL = d.backdropURL?.nilIfEmpty ?? m.backdropURL
        m.posterURL = d.posterURL?.nilIfEmpty ?? m.posterURL
        m.trailer = d.trailer?.nilIfEmpty ?? m.trailer
        m.containerExtension = d.containerExtension?.nilIfEmpty ?? m.containerExtension
        m.tmdbId = d.tmdbId?.nilIfEmpty ?? m.tmdbId
        return m
    }

    private func loadUserState() async {
        let id = movie.id
        progress = try? await model.db.progress(mediaId: id)
        isFavorite = (try? await model.db.isVODFavorite(mediaId: id)) ?? false
    }

    private func toggleFavorite() {
        let id = movie.id
        Task {
            let value = await model.toggleVODFavorite(mediaId: id, kind: .movie)
            withAnimation(.snappy) { isFavorite = value }
        }
    }

    private func toggleWatched() {
        let base = progress ?? WatchProgress(
            mediaId: movie.id, kind: .movie, sourceId: movie.sourceId, title: movie.name, subtitle: movie.year,
            posterURL: movie.backdropURL?.nilIfEmpty ?? info?.backdropURL ?? movie.posterURL, position: 0, duration: Double(movie.durationSeconds ?? 1)
        )
        let watched = progress?.completed != true
        Task { try? await model.db.markWatched(base, watched: watched) }
    }
}

/// Reloads details when the movie changes or the Mac comes back online.
private struct MovieDetailLoadKey: Hashable {
    let id: String
    let offline: Bool
}

// MARK: - Shared detail pieces

/// Where a movie or show comes from: its playlist and the category in it (under the user's alias, if any).
@MainActor
enum VODOrigin {
    static func playlist(_ model: AppModel, sourceId: String) -> String? {
        model.sources.first(where: { $0.id == sourceId })?.name.nilIfEmpty
    }

    static func categoryName(_ category: TunerCore.Category?) -> String? {
        guard let category else { return nil }
        return category.alias?.nilIfEmpty ?? category.name.nilIfEmpty
    }

    /// "Playlist › Category", or whichever part is known.
    static func text(playlist: String?, category: TunerCore.Category?) -> String? {
        let parts = [playlist, categoryName(category)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " › ")
    }

    /// The About grid's Playlist and Category rows.
    static func rows(playlist: String?, category: TunerCore.Category?) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let playlist { rows.append(("Playlist", playlist)) }
        if let name = categoryName(category) { rows.append(("Category", name)) }
        return rows
    }
}

/// How much room the hero's button row has (`ViewThatFits` tries them in order).
enum VODActionDensity {
    case full
    case compact
    case minimal
}

/// Glass capsule with a label, or a glass circle with just the symbol (title becomes the tooltip).
struct VODSecondaryButton: View {
    let title: String
    let systemImage: String
    var iconOnly = false
    let action: () -> Void

    var body: some View {
        if iconOnly {
            Button(action: action) {
                Image(systemName: systemImage)
            }
            .buttonStyle(GlassButtonStyle(circle: true))
            .help(title)
            .accessibilityLabel(title)
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(GlassButtonStyle())
        }
    }
}

/// Full-bleed backdrop hero for movie and show pages, extending under the toolbar and sidebar.
struct VODDetailHeader<Actions: View>: View {
    let title: String
    let kindLabel: String
    /// Backdrops in order of preference (see `VODBackdropArtwork`).
    let backdropURLs: [String?]
    let posterURL: String?
    /// Transparent title artwork from online metadata, shown above the playlist's own title.
    var logoURL: String?
    /// Where the title comes from: "Playlist › Category" (`VODOrigin`).
    var origin: String?
    let symbol: String
    let metadata: [String]
    var rating: VODRating?
    var genres: [String] = []
    var plot: String?
    var isLoading = false
    let height: CGFloat
    @ViewBuilder var actions: () -> Actions
    @Environment(\.tunerCompact) private var compact

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VODBackdropArtwork(title: title, backdropURLs: backdropURLs, fallbackURL: posterURL, symbol: symbol)
                .vodBackgroundExtension()

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .black.opacity(0.35), location: 0.55),
                    .init(color: .black.opacity(0.92), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.7, y: 0.5))

            HStack(alignment: .bottom, spacing: 28) {
                // Narrow screens: no poster beside the text (the backdrop fills the hero, as in the TV app).
                if let posterURL, !compact {
                    Color.clear
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .overlay {
                            RemoteImage(url: posterURL) { VODArtworkPlaceholder(title: title, symbol: symbol) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        }
                        .frame(width: min(190, height * 0.42))
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(kindLabel.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.65))
                    VODTitleArtwork(
                        title: title,
                        logoURL: logoURL,
                        fontSize: compact ? 30 : 38,
                        maxLogoWidth: compact ? 300 : 420,
                        maxLogoHeight: min(120, max(70, height * 0.2)),
                        showsTitleUnderLogo: true
                    )
                    if let origin {
                        Label(origin, systemImage: "list.bullet.rectangle")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                            .help("Playlist and category this title comes from")
                    }
                    HStack(spacing: 8) {
                        if !metadata.isEmpty {
                            Text(metadata.joined(separator: " · "))
                                .lineLimit(1)
                        }
                        if let rating {
                            if !metadata.isEmpty { Text("·") }
                            VODRatingBadge(rating: rating)
                        }
                        if isLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    VODGenreChips(genres: genres)
                        .foregroundStyle(.white.opacity(0.9))
                    if let plot {
                        Text(plot)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(3)
                            .frame(maxWidth: 600, alignment: .leading)
                    }
                    actions()
                        // macOS gives the first button keyboard focus on appear and rings it in blue; the glass
                        // buttons have their own hover/press look (as in the TV app), so no focus ring here.
                        .focusEffectDisabled()
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, VODMetrics.inset)
            .padding(.bottom, 32)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) { VODTheme.heroBottomFade }
    }
}

/// "About" block: full synopsis plus a label/value grid (cast, director, genre…).
struct VODAboutSection: View {
    let plot: String?
    let rows: [(String, String)]

    var body: some View {
        if plot != nil || !rows.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("About").font(.title2.weight(.bold))
                if let plot {
                    Text(plot)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.85))
                        .frame(maxWidth: 760, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !rows.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
                        ForEach(rows, id: \.0) { row in
                            GridRow {
                                Text(row.0)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(row.1)
                                    .font(.callout)
                                    .frame(maxWidth: 640, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}
