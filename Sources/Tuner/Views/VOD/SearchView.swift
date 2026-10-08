import SwiftUI
import TunerCore

/// Search across channels, guide programmes, movies and shows (bound to `model.searchQuery`).
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var path: [VODRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            SearchContent()
                .vodDestinations()
        }
        // Back to the field from a movie or show page opened from the results.
        .onChange(of: model.searchFocusRequest) { path.removeAll() }
        .onChange(of: path.count) { old, new in
            // Opening a movie or show from the results.
            if new > old { model.prefs.rememberSearch(model.searchQuery) }
        }
    }
}

// MARK: - Content

private struct SearchContent: View {
    @Environment(AppModel.self) private var model
    @FocusState private var fieldFocused: Bool
    @ViewState private var results: SearchResults?
    @ViewState private var isSearching = false
    @ViewState private var showAllPrograms = false

    private var query: String { model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                searchField
                    .padding(.horizontal, VODMetrics.inset)
                    .padding(.top, 18)
                resultsBody
            }
            .padding(.bottom, 40)
        }
        .background(VODTheme.background)
        .navigationTitle("Search")
        #if os(macOS)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            fieldFocused = true
        }
        #else
        // Touch screens: the keyboard would cover the tab bar, so it only opens when the field is tapped and
        // scrolling the results puts it away. The page's own field replaces the navigation bar.
        .scrollDismissesKeyboard(.immediately)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onChange(of: model.searchFocusRequest) { fieldFocused = true }
        .task(id: SearchKey(query: query, library: model.libraryRevision, guide: model.guideRevision)) {
            await runSearch(query)
        }
        .onChange(of: query) { showAllPrograms = false }
        .onChange(of: model.player.main.item?.id) { _, id in
            // Playing a channel or programme from the results.
            if id != nil, results?.isEmpty == false { model.prefs.rememberSearch(query) }
        }
    }

    // MARK: Field

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Channels, programs, movies and shows", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .medium))
                .focused($fieldFocused)
                .focusEffectDisabled()
                .onSubmit {
                    fieldFocused = false
                    model.prefs.rememberSearch(model.searchQuery)
                }
            if isSearching {
                ProgressView().controlSize(.small)
            }
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Capsule().fill(Color.primary.opacity(fieldFocused ? 0.11 : 0.07)))
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: fieldFocused)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsBody: some View {
        if query.count < 2 {
            if query.isEmpty, !model.prefs.recentSearches.isEmpty {
                recentSearches
            } else {
                ContentUnavailableView {
                    Label("Search Tuner", systemImage: "magnifyingglass")
                } description: {
                    Text("Find channels, what's on TV, movies and shows across all your playlists.")
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            }
        } else if let results {
            if results.isEmpty {
                ContentUnavailableView.search(text: results.query)
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                sections(results)
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 360)
        }
    }

    /// Recent searches, newest first: tap to search again, long-press (right-click) to remove one.
    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "Recent Searches", subtitle: nil, actionTitle: "Clear", action: {
                withAnimation(.smooth(duration: 0.25)) { model.prefs.recentSearches = [] }
            })
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.prefs.recentSearches, id: \.self) { recent in
                    Button {
                        model.searchQuery = recent
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(recent)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.backward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.body)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove from Recent Searches", role: .destructive) {
                            withAnimation(.smooth(duration: 0.25)) { model.prefs.recentSearches.removeAll { $0 == recent } }
                        }
                    }
                    .accessibilityHint("Searches again")
                    if recent != model.prefs.recentSearches.last {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(.horizontal, VODMetrics.inset)
    }

    @ViewBuilder
    private func sections(_ results: SearchResults) -> some View {
        if !results.channels.isEmpty {
            VODShelf("Channels", subtitle: countText(results.channels.count, limit: SearchResults.channelLimit)) {
                ForEach(results.channels) { channel in
                    SearchChannelTile(channel: channel, program: results.nowPlaying[channel.id])
                }
            }
        }

        if !results.programs.isEmpty {
            let shown = showAllPrograms ? results.programs : Array(results.programs.prefix(8))
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(
                    title: "On TV",
                    subtitle: "\(results.programs.count)",
                    actionTitle: results.programs.count > 8 ? (showAllPrograms ? "Show Less" : "Show All") : nil,
                    action: { withAnimation(.smooth(duration: 0.3)) { showAllPrograms.toggle() } }
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(shown) { hit in
                        SearchProgramRow(hit: hit)
                    }
                }
            }
            .padding(.horizontal, VODMetrics.inset)
        }

        if !results.movies.isEmpty {
            VODShelf("Movies", subtitle: countText(results.movies.count, limit: SearchResults.vodLimit)) {
                ForEach(results.movies) { item in
                    posterLink(item, favorites: results.favoriteIds)
                }
            }
        }

        if !results.shows.isEmpty {
            VODShelf("TV Shows", subtitle: countText(results.shows.count, limit: SearchResults.vodLimit)) {
                ForEach(results.shows) { item in
                    posterLink(item, favorites: results.favoriteIds)
                }
            }
        }
    }

    private func posterLink(_ item: VODItem, favorites: Set<String>) -> some View {
        NavigationLink(value: item.route) {
            VODPosterCard(item: item)
        }
        .buttonStyle(.plain)
        .contextMenu {
            VODItemMenu(item: item, isFavorite: favorites.contains(item.mediaId))
        }
    }

    private func countText(_ count: Int, limit: Int) -> String {
        count >= limit ? "\(limit)+" : "\(count)"
    }

    // MARK: Search

    private func runSearch(_ q: String) async {
        guard q.count >= 2 else {
            results = nil
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        isSearching = true
        let found = await SearchResults.load(query: q, model: model)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { results = found }
        isSearching = false
    }
}

private struct SearchKey: Hashable {
    let query: String
    let library: Int
    let guide: Int
}

// MARK: - Results model

private struct SearchProgramHit: Identifiable, Hashable {
    let program: Program
    let channel: Channel
    var id: String { "\(program.stableKey)#\(channel.id)" }
}

private struct SearchResults {
    static let channelLimit = 40
    static let vodLimit = 40

    var query: String
    var channels: [Channel] = []
    /// Current programme by channel id.
    var nowPlaying: [String: Program] = [:]
    var programs: [SearchProgramHit] = []
    var movies: [VODItem] = []
    var shows: [VODItem] = []
    var favoriteIds: Set<String> = []

    var isEmpty: Bool { channels.isEmpty && programs.isEmpty && movies.isEmpty && shows.isEmpty }

    @MainActor
    static func load(query q: String, model: AppModel) async -> SearchResults {
        let db = model.db
        let now = Date()
        let hideAdult = model.prefs.hideAdultContent
        // Past programmes are only useful with catchup; look back up to 3 days.
        let lookBack: TimeInterval = 3 * 86_400

        async let channelsQuery = db.channels(scope: .all, search: q, sort: .provider, limit: channelLimit)
        async let moviesQuery = db.movies(search: q, sort: .name, limit: 200)
        async let seriesQuery = db.series(search: q, sort: .name, limit: 200)
        async let programsQuery = db.searchPrograms(q, from: now.addingTimeInterval(-lookBack), hours: 72 + lookBack / 3600, limit: 300)
        async let favoriteMoviesQuery = db.favoriteMovies()
        async let favoriteSeriesQuery = db.favoriteSeries()

        var result = SearchResults(query: q)

        var channels = (try? await channelsQuery) ?? []
        if hideAdult { channels.removeAll { $0.isAdult } }
        result.channels = channels
        let nowMap = await model.programs(for: channels, from: now, to: now.addingTimeInterval(60))
        for channel in channels {
            if let key = channel.epgKey, let p = nowMap[key]?.first(where: { $0.isLive(at: now) }) {
                result.nowPlaying[channel.id] = p
            }
        }

        result.movies = Array(rank((try? await moviesQuery) ?? [], query: q, name: \.name).prefix(vodLimit)).map(VODItem.movie)
        result.shows = Array(rank((try? await seriesQuery) ?? [], query: q, name: \.name).prefix(vodLimit)).map(VODItem.series)
        let favMovies = (try? await favoriteMoviesQuery) ?? []
        let favSeries = (try? await favoriteSeriesQuery) ?? []
        result.favoriteIds = Set(favMovies.map(\.id) + favSeries.map(\.id))

        let programs = (try? await programsQuery) ?? []
        if !programs.isEmpty {
            var guideChannels = (try? await db.channels(epgKeys: Array(Set(programs.map(\.epgKey))))) ?? []
            if hideAdult { guideChannels.removeAll { $0.isAdult } }
            var byKey: [String: [Channel]] = [:]
            for channel in guideChannels {
                if let key = channel.epgKey { byKey[key, default: []].append(channel) }
            }
            var hits: [SearchProgramHit] = []
            var seen = Set<String>()
            for program in programs {
                guard let candidates = byKey[program.epgKey], !candidates.isEmpty else { continue }
                let isPast = program.end <= now
                let channel: Channel?
                if isPast {
                    channel = candidates.first { $0.hasCatchup && program.start >= now.addingTimeInterval(-Double($0.catchupDays ?? 3) * 86_400) }
                } else {
                    channel = candidates.first { $0.isFavorite } ?? candidates.first
                }
                guard let channel, seen.insert(program.stableKey).inserted else { continue }
                hits.append(SearchProgramHit(program: program, channel: channel))
            }
            // Airing now, then upcoming, then catchup (most recent first).
            let live = hits.filter { $0.program.isLive(at: now) }
            let upcoming = hits.filter { $0.program.start > now }
            let past = hits.filter { $0.program.end <= now }.sorted { $0.program.start > $1.program.start }
            result.programs = Array((live + upcoming + past).prefix(60))
        }
        return result
    }

    /// Exact title matches first, then prefix matches, then the rest (stable).
    private static func rank<T>(_ list: [T], query: String, name: KeyPath<T, String>) -> [T] {
        let q = query.lowercased()
        func score(_ item: T) -> Int {
            let n = item[keyPath: name].lowercased()
            if n == q { return 0 }
            if n.hasPrefix(q) { return 1 }
            if n.contains(" \(q)") { return 2 }
            return 3
        }
        return list.enumerated()
            .sorted { (score($0.element), $0.offset) < (score($1.element), $1.offset) }
            .map(\.element)
    }
}

// MARK: - Channel tile

private struct SearchChannelTile: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let program: Program?

    var body: some View {
        Button {
            model.play(channel, fullWindow: true)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: VODMetrics.landscapeCorner, style: .continuous)
                    .fill(VODPalette.gradient(for: channel.displayName, brightness: 0.3))
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        ChannelLogo(url: channel.logoURL, name: channel.displayName, size: 44)
                    }
                    .overlay(alignment: .topTrailing) {
                        if program != nil { VODLivePill().padding(8) }
                    }
                    .overlay(alignment: .bottom) {
                        if let program {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                ProgressCapsule(fraction: program.progress(at: context.date), height: 3, tint: .white)
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: VODMetrics.landscapeCorner, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                    .hoverLift()
                Text(channel.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(program?.title ?? "No guide information")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(channel.displayName)
        .contextMenu {
            Button {
                model.play(channel, fullWindow: true)
            } label: {
                Label("Watch", systemImage: "play.fill")
            }
            Divider()
            Button {
                model.toggleFavorite(channel)
            } label: {
                Label(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: channel.isFavorite ? "star.slash" : "star")
            }
        }
    }
}

// MARK: - Programme row

/// Guide hit: airing → watch, upcoming → toggle reminder, past with catchup → play from the archive.
private struct SearchProgramRow: View {
    @Environment(AppModel.self) private var model
    let hit: SearchProgramHit
    @ViewState private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let program = hit.program
        let channel = hit.channel
        let isLive = program.isLive(at: now)
        let isPast = program.end <= now
        let hasReminder = model.hasReminder(for: program)
        let actionable = !isPast || channel.hasCatchup

        return Button {
            perform(now: now)
        } label: {
            HStack(spacing: 12) {
                ChannelLogo(url: channel.logoURL, name: channel.displayName, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isLive { VODLivePill() }
                        Text(program.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Text("\(channel.displayName) · \(Fmt.day(program.start)), \(Fmt.timeRange(program.start, program.end))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let subtitle = program.subtitle?.nilIfEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if isLive {
                        ProgressCapsule(fraction: program.progress(at: now), height: 3)
                            .frame(maxWidth: 160)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                trailingIcon(isLive: isLive, isPast: isPast, hasReminder: hasReminder)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering && actionable ? 0.1 : 0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!actionable)
        .opacity(actionable ? 1 : 0.55)
        .onHover { hovering = $0 }
        .help(helpText(isLive: isLive, isPast: isPast, hasReminder: hasReminder))
        .contextMenu {
            Button {
                model.play(channel, fullWindow: true)
            } label: {
                Label("Watch \(channel.displayName)", systemImage: "play.fill")
            }
            if isPast, channel.hasCatchup {
                Button {
                    model.playCatchup(channel, program: program)
                } label: {
                    Label("Play from Archive", systemImage: "gobackward")
                }
            }
            if !isPast {
                if !isLive {
                    Button {
                        model.toggleReminder(channel: channel, program: program)
                    } label: {
                        Label(hasReminder ? "Remove Reminder" : "Remind Me", systemImage: hasReminder ? "bell.slash" : "bell")
                    }
                }
                if !model.isScheduled(program, on: channel) {
                    Button {
                        model.record(channel, program: program)
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trailingIcon(isLive: Bool, isPast: Bool, hasReminder: Bool) -> some View {
        Group {
            if isLive {
                Image(systemName: "play.circle.fill").foregroundStyle(Color.accentColor)
            } else if isPast {
                if hit.channel.hasCatchup { Image(systemName: "gobackward").foregroundStyle(.secondary) }
            } else {
                Image(systemName: hasReminder ? "bell.fill" : "bell").foregroundStyle(hasReminder ? Color.accentColor : .secondary)
            }
        }
        .font(.title3)
        .contentTransition(.symbolEffect(.replace))
    }

    private func helpText(isLive: Bool, isPast: Bool, hasReminder: Bool) -> String {
        if isLive { return "Watch now" }
        if isPast { return hit.channel.hasCatchup ? "Play from the archive" : "No catchup on this channel" }
        return hasReminder ? "Remove reminder" : "Remind me when it starts"
    }

    private func perform(now: Date) {
        let program = hit.program
        let channel = hit.channel
        if program.isLive(at: now) {
            model.play(channel, fullWindow: true)
        } else if program.start > now {
            model.toggleReminder(channel: channel, program: program)
        } else if channel.hasCatchup {
            model.playCatchup(channel, program: program)
        }
    }
}
