import SwiftUI
import TunerCore

/// Apple TV–style Home: a rotating hero of recently added movies and shows, then shelves for
/// Continue Watching, On Now, recently added, top rated and favourites.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var path: [VODRoute] = []

    var body: some View {
        if !model.hasSources {
            WelcomeView()
        } else {
            NavigationStack(path: $path) {
                HomeContent { path.append($0) }
                    .vodDestinations()
            }
        }
    }
}

// MARK: - Content

private struct HomeContent: View {
    @Environment(AppModel.self) private var model
    /// Pushes a detail page (used by context menus).
    let open: (VODRoute) -> Void

    @ViewState private var library = HomeLibrary()
    @ViewState private var personal = HomePersonal()
    @ViewState private var onNow: [HomeLiveEntry] = []
    @ViewState private var onNowSubtitle: String?
    @ViewState private var loaded = false
    @ViewState private var enriched: Set<String> = []
    /// Online metadata for the hero items, keyed by `VODItem.id`.
    @ViewState private var heroMetadata: [String: MediaMetadata] = [:]
    @ViewState private var viewHeight: CGFloat = 800

    private var hasHero: Bool { !library.hero.isEmpty }

    private var isEmpty: Bool {
        library.hero.isEmpty && library.recentMovies.isEmpty && library.recentSeries.isEmpty && library.topRated.isEmpty
            && personal.continueWatching.isEmpty && personal.favorites.isEmpty && onNow.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if hasHero {
                    HomeHero(items: library.hero, metadata: heroMetadata, height: VODMetrics.homeHeroHeight(for: viewHeight))
                } else {
                    VODPageTitle(title: "Home")
                        .padding(.horizontal, VODMetrics.inset)
                        .padding(.top, 12)
                }

                if model.isOffline {
                    OfflineBanner()
                        .padding(.horizontal, VODMetrics.inset)
                }

                if !personal.continueWatching.isEmpty {
                    VODShelf("Continue Watching") {
                        ForEach(personal.continueWatching) { item in
                            switch item {
                            case .resume(let progress): continueCard(progress)
                            case .nextEpisode(let episode, let progress): nextEpisodeCard(episode, progress)
                            }
                        }
                    }
                }

                if !onNow.isEmpty {
                    VODShelf("On Now", subtitle: onNowSubtitle) {
                        ForEach(onNow) { entry in
                            onNowCard(entry)
                        }
                    }
                }

                posterShelf("Recently Added Movies", library.recentMovies)
                posterShelf("Recently Added Shows", library.recentSeries)
                posterShelf("Top Rated", library.topRated)
                posterShelf("Your Favorites", personal.favorites)

                if loaded, isEmpty {
                    emptyState
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: hasHero ? .top : [])
        .background(VODTheme.background)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewHeight = $0 }
        .navigationTitle("Home")
        .task(id: model.libraryRevision) { await loadLibrary() }
        .task(id: HomePersonalKey(user: model.userRevision, smart: smartRow, library: smartRow ? model.libraryRevision : 0)) {
            await loadPersonal()
        }
        .task(id: HomeHeroMetadataKey(ids: library.hero.map(\.id), settings: model.prefs.metadataSettings)) {
            await loadHeroMetadata()
        }
        .task(id: HomeOnNowKey(library: model.libraryRevision, user: model.userRevision, guide: model.guideRevision)) {
            await refreshOnNowLoop()
        }
    }

    // MARK: Shelves

    @ViewBuilder
    private func posterShelf(_ title: String, _ items: [VODItem]) -> some View {
        if !items.isEmpty {
            VODShelf(title) {
                ForEach(items) { item in
                    NavigationLink(value: item.route) {
                        VODPosterCard(item: item, progress: personal.movieProgress[item.mediaId])
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        VODItemMenu(item: item, isFavorite: personal.favoriteIds.contains(item.mediaId))
                    }
                }
            }
        }
    }

    private func continueCard(_ progress: WatchProgress) -> some View {
        Button {
            Task { await model.resume(progress) }
        } label: {
            VODLandscapeCard(
                title: progress.title,
                subtitle: progress.subtitle,
                caption: VODFormat.timeLeft(progress),
                imageURL: progress.posterURL,
                symbol: progress.kind == .movie ? "film" : "tv",
                progress: progress.fraction
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await model.resume(progress) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            Button {
                Task { await openDetail(for: progress) }
            } label: {
                Label(progress.kind == .movie ? "Go to Movie" : "Go to Show", systemImage: "info.circle")
            }
            Divider()
            Button {
                Task { try? await model.db.markWatched(progress, watched: true) }
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                let id = progress.mediaId
                // Smart row: an episode goes back to the start rather than away, so its show doesn't come back
                // as the next episode after the one before it.
                if smartRow, progress.kind == .episode {
                    Task { try? await model.db.markWatched(progress, watched: false) }
                } else {
                    Task { try? await model.db.deleteProgress(mediaId: id) }
                }
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
    }

    /// Smart Continue Watching: the episode after one just finished, played from the start.
    private func nextEpisodeCard(_ episode: Episode, _ progress: WatchProgress) -> some View {
        let item = ContinueWatchingItem.nextEpisode(episode, progress: progress)
        return Button {
            Task { await model.play(item) }
        } label: {
            VODLandscapeCard(
                title: progress.title,
                subtitle: "\(VODFormat.episodeCode(episode)) · Next Episode",
                caption: episode.title.nilIfEmpty,
                imageURL: progress.posterURL,
                symbol: "tv"
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await model.play(item) }
            } label: {
                Label("Play \(VODFormat.episodeCode(episode))", systemImage: "play.fill")
            }
            Button {
                Task { await openDetail(for: progress) }
            } label: {
                Label("Go to Show", systemImage: "info.circle")
            }
            Divider()
            Button {
                Task { try? await model.db.markWatched(progress, watched: true) }
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                // A not-started record of the episode is newer than the finished one, so the show leaves the row.
                Task { try? await model.db.markWatched(progress, watched: false) }
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
    }

    private func onNowCard(_ entry: HomeLiveEntry) -> some View {
        Button {
            model.play(entry.channel, fullWindow: true)
        } label: {
            VODOnNowCard(channel: entry.channel, program: entry.program)
        }
        .buttonStyle(.plain)
        .help(entry.program.map { "\($0.title) · \(Fmt.timeRange($0.start, $0.end))" } ?? entry.channel.displayName)
        .contextMenu {
            Button {
                model.play(entry.channel, fullWindow: true)
            } label: {
                Label("Watch", systemImage: "play.fill")
            }
            Divider()
            Button {
                model.toggleFavorite(entry.channel)
            } label: {
                Label(entry.channel.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: entry.channel.isFavorite ? "star.slash" : "star")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isSyncing {
            ContentUnavailableView {
                Label("Getting Your Library Ready", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("Channels, movies and shows appear here as your playlists finish loading.")
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            ContentUnavailableView {
                Label("Nothing Here Yet", systemImage: "sparkles.tv")
            } description: {
                Text("Favorite channels and start watching movies or shows to fill your Home.")
            } actions: {
                Button("Browse Live TV") { model.sidebarSelection = .liveTV }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        }
    }

    // MARK: Loading

    private func loadLibrary() async {
        let db = model.db
        async let recentMovies = db.movies(sort: .added, limit: 24)
        async let recentSeries = db.series(sort: .added, limit: 24)
        async let ratedMovies = db.movies(sort: .rating, limit: 20)
        async let ratedSeries = db.series(sort: .rating, limit: 20)
        let movies = ((try? await recentMovies) ?? []).map(VODItem.movie)
        let shows = ((try? await recentSeries) ?? []).map(VODItem.series)
        let rated = ((try? await ratedMovies) ?? []).map(VODItem.movie) + ((try? await ratedSeries) ?? []).map(VODItem.series)
        guard !Task.isCancelled else { return }

        var lib = HomeLibrary()
        lib.recentMovies = movies
        lib.recentSeries = shows
        lib.topRated = Array(rated.filter { $0.rating != nil }.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(20))
        lib.hero = Self.heroPicks(movies: movies, shows: shows)
        if lib != library { library = lib }
        loaded = true
        await enrichHero()
    }

    /// Up to six recently added items with artwork, alternating movies and shows (order stays stable
    /// as details arrive so the carousel doesn't jump).
    private static func heroPicks(movies: [VODItem], shows: [VODItem]) -> [VODItem] {
        var mixed: [VODItem] = []
        for i in 0..<max(movies.count, shows.count) {
            if i < movies.count { mixed.append(movies[i]) }
            if i < shows.count { mixed.append(shows[i]) }
        }
        return Array(mixed.filter { $0.backdropURL != nil || $0.posterURL != nil }.prefix(6))
    }

    /// Fetches provider details (backdrop, plot, genre) for hero movies that lack them — once per movie,
    /// since storing details bumps `libraryRevision` and reloads this page.
    private func enrichHero() async {
        for item in library.hero {
            guard case .movie(let movie) = item, movie.backdropURL?.nilIfEmpty == nil || movie.plot?.nilIfEmpty == nil,
                  !enriched.contains(movie.id) else { continue }
            enriched.insert(movie.id)
            guard let details = try? await model.sync.movieDetails(movie), !Task.isCancelled else { continue }
            var m = movie
            m.backdropURL = details.backdropURL?.nilIfEmpty ?? m.backdropURL
            m.posterURL = details.posterURL?.nilIfEmpty ?? m.posterURL
            m.plot = details.plot?.nilIfEmpty ?? m.plot
            m.genre = details.genre?.nilIfEmpty ?? m.genre
            if let r = details.rating, r > 0 { m.rating = r }
            m.releaseDate = details.releaseDate?.nilIfEmpty ?? m.releaseDate
            if let index = library.hero.firstIndex(where: { $0.id == item.id }) {
                library.hero[index] = .movie(m)
            }
        }
    }

    /// Online metadata (backdrop, title logo) for the hero items — cached after the first lookup, so cheap.
    /// Lookups run side by side; each item's artwork fades in as its result arrives.
    private func loadHeroMetadata() async {
        let items = library.hero
        guard !items.isEmpty else { return }
        let service = model.metadata
        await withTaskGroup(of: (String, MediaMetadata?).self) { group in
            for item in items {
                group.addTask {
                    switch item {
                    case .movie(let movie): (item.id, await service.metadata(for: movie))
                    case .series(let series): (item.id, await service.metadata(for: series))
                    }
                }
            }
            for await (id, result) in group {
                guard !Task.isCancelled else { return }
                if heroMetadata[id] != result {
                    withAnimation(.easeInOut(duration: 0.5)) { heroMetadata[id] = result }
                }
            }
        }
    }

    /// Settings › AI › Smart Continue Watching.
    private var smartRow: Bool { model.prefs.aiSmartContinueWatching }

    private func loadPersonal() async {
        let db = model.db
        let smart = smartRow
        async let continueWatching: [ContinueWatchingItem] = smart
            ? db.smartContinueWatching(limit: 20)
            : db.continueWatching(limit: 20).map(ContinueWatchingItem.resume)
        async let favoriteMovies = db.favoriteMovies()
        async let favoriteSeries = db.favoriteSeries()
        let cw = (try? await continueWatching) ?? []
        let fm = (try? await favoriteMovies) ?? []
        let fs = (try? await favoriteSeries) ?? []
        guard !Task.isCancelled else { return }

        var p = HomePersonal()
        p.continueWatching = cw
        p.favorites = Array((fm.map(VODItem.movie) + fs.map(VODItem.series)).prefix(40))
        p.favoriteIds = Set(fm.map(\.id) + fs.map(\.id))
        let resumed = cw.compactMap { item -> WatchProgress? in
            if case .resume(let progress) = item, progress.kind == .movie { return progress }
            return nil
        }
        p.movieProgress = Dictionary(resumed.map { ($0.mediaId, $0.fraction) }, uniquingKeysWith: { a, _ in a })
        if p != personal { personal = p }
        loaded = true
    }

    /// Favourite channels (else recently watched) with what's on now; refreshed every minute.
    private func refreshOnNowLoop() async {
        while !Task.isCancelled {
            var channels = (try? await model.db.channels(scope: .favorites, limit: 24)) ?? []
            var subtitle: String? = "Favorites"
            if channels.isEmpty {
                channels = (try? await model.db.channels(scope: .recent, limit: 24)) ?? []
                subtitle = "Recently Watched"
            }
            if model.prefs.hideAdultContent { channels.removeAll { $0.isAdult } }
            let now = Date()
            let programs = await model.programs(for: channels, from: now, to: now.addingTimeInterval(60))
            guard !Task.isCancelled else { return }
            let entries = channels.map { channel in
                HomeLiveEntry(channel: channel, program: channel.epgKey.flatMap { key in programs[key]?.first { $0.isLive(at: now) } })
            }
            if entries != onNow { onNow = entries }
            onNowSubtitle = entries.isEmpty ? nil : subtitle
            loaded = true
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func openDetail(for progress: WatchProgress) async {
        switch progress.kind {
        case .movie:
            if let movie = try? await model.db.movie(id: progress.mediaId) { open(.movie(movie)) }
        case .episode:
            if let id = progress.seriesId, let series = try? await model.db.series(id: id) { open(.series(series)) }
        case .channel:
            break
        }
    }
}

private struct HomeLibrary: Equatable {
    var hero: [VODItem] = []
    var recentMovies: [VODItem] = []
    var recentSeries: [VODItem] = []
    var topRated: [VODItem] = []
}

private struct HomePersonal: Equatable {
    var continueWatching: [ContinueWatchingItem] = []
    var favorites: [VODItem] = []
    var favoriteIds: Set<String> = []
    var movieProgress: [String: Double] = [:]
}

private struct HomeLiveEntry: Identifiable, Equatable {
    let channel: Channel
    let program: Program?
    var id: String { channel.id }
}

/// Reloads Home's personal shelves; with the smart row on, also when episodes get cached (they feed next episodes).
private struct HomePersonalKey: Hashable {
    let user: Int
    let smart: Bool
    let library: Int
}

private struct HomeHeroMetadataKey: Hashable {
    let ids: [String]
    let settings: MetadataSettings
}

private struct HomeOnNowKey: Hashable {
    let library: Int
    let user: Int
    let guide: Int
}

// MARK: - Hero

/// Edge-to-edge carousel (rotates every 8 s, paused on hover) with title, metadata, plot,
/// Play and More Info, and page dots. Online metadata, when present, supplies the backdrop and the title logo.
private struct HomeHero: View {
    @Environment(AppModel.self) private var model
    let items: [VODItem]
    /// Online metadata keyed by `VODItem.id`.
    let metadata: [String: MediaMetadata]
    let height: CGFloat

    @Environment(\.tunerCompact) private var compact
    @ViewState private var index = 0
    @ViewState private var hovering = false

    private var current: VODItem { items[min(index, items.count - 1)] }
    private var paused: Bool { hovering || model.player.isFullWindow }

    /// The metadata backdrop first (consistent, high-resolution fan art), then the provider's.
    private func backdrops(_ item: VODItem) -> [String?] {
        [metadata[item.id]?.backdropURL, item.backdropURL]
    }

    private func hasBackdrop(_ item: VODItem) -> Bool {
        backdrops(item).contains { $0?.nilIfEmpty != nil }
    }

    var body: some View {
        let item = current
        let info = metadata[item.id]
        ZStack(alignment: .bottomLeading) {
            ZStack {
                VODBackdropArtwork(
                    title: item.title,
                    backdropURLs: backdrops(item),
                    fallbackURL: item.posterURL ?? info?.posterURL?.nilIfEmpty,
                    symbol: item.placeholderSymbol
                )
                .id(item.id)
                .transition(.opacity)
            }
            .vodBackgroundExtension()

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.4), location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: .black.opacity(0.3), location: 0.55),
                    .init(color: .black.opacity(0.92), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.75, y: 0.5))

            details(item, info: info)
                .id(item.id)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            // Narrow screens skip it: it would cover the title, and it flashed up until the metadata backdrop arrived.
            if !compact, !hasBackdrop(item), let poster = item.posterURL ?? info?.posterURL?.nilIfEmpty {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay { RemoteImage(url: poster) { Color.clear } }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(height: height * 0.6)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .padding(.trailing, 56)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: compact ? .bottom : .bottomTrailing) {
            if items.count > 1 {
                // Narrow screens: centred under the buttons (beside them, they'd collide).
                dots.padding(.trailing, compact ? 0 : VODMetrics.inset).padding(.bottom, compact ? 12 : 40)
            }
        }
        .clipped()
        .simultaneousGesture(swipe, including: compact ? .all : .subviews)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) { VODTheme.heroBottomFade }
        .onHover { hovering = $0 }
        .onChange(of: items.count) { _, count in
            if index >= count { index = 0 }
        }
        .task(id: HomeHeroTick(index: index, paused: paused, count: items.count)) {
            guard items.count > 1, !paused else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) { index = (index + 1) % items.count }
        }
    }

    private func details(_ item: VODItem, info: MediaMetadata?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.kindLabel.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.65))
            VODTitleArtwork(
                title: item.title,
                logoURL: info?.logoURL,
                fontSize: 40,
                maxLogoWidth: 440,
                maxLogoHeight: min(130, max(70, height * 0.22))
            )
            let meta = item.metadataLine
            if !meta.isEmpty {
                Text(meta)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            if let plot = item.plot ?? info?.overview?.nilIfEmpty {
                Text(plot)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Button {
                    VODActions.play(item, model: model)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryCapsuleButtonStyle())

                NavigationLink(value: item.route) {
                    Label("More Info", systemImage: "info.circle")
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 480, alignment: .leading)
        .padding(.leading, VODMetrics.inset)
        .padding(.trailing, compact ? VODMetrics.inset : 0)
        .padding(.bottom, compact ? 52 : 40)
    }

    /// Touch screens: swipe the hero sideways to change the featured title.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard items.count > 1, abs(value.translation.width) > abs(value.translation.height) * 1.5,
                      abs(value.translation.width) > 50 else { return }
                let step = value.translation.width < 0 ? 1 : -1
                withAnimation(.easeInOut(duration: 0.6)) { index = (index + step + items.count) % items.count }
            }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(items.indices, id: \.self) { i in
                Button {
                    withAnimation(.easeInOut(duration: 0.6)) { index = i }
                } label: {
                    Capsule()
                        .fill(.white.opacity(i == index ? 0.95 : 0.35))
                        .frame(width: i == index ? 18 : 7, height: 7)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .help(items[i].title)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .tunerGlass(in: Capsule())
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
    }
}

private struct HomeHeroTick: Hashable {
    let index: Int
    let paused: Bool
    let count: Int
}
