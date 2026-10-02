import AppKit
import Foundation
import Network
import Observation
import TunerCore
import UserNotifications

/// Root application state and actions. Views read it via `@Environment(AppModel.self)`.
@MainActor
@Observable
final class AppModel {
    // MARK: Services
    let db: AppDatabase
    let sync: SyncService
    let resolver: StreamResolver
    let recorder: RecordingService
    /// Online movie/series metadata (artwork, logos, cast, ratings, episode stills).
    let metadata: MetadataService
    /// IMDb ratings for TV episodes (IMDb's datasets; see `IMDbRatingsService`).
    let imdbRatings: IMDbRatingsService
    /// Movies and episodes saved for offline viewing (one at a time; see `downloadItems`).
    let downloads: DownloadService
    let prefs: Preferences
    let player: PlayerManager

    // MARK: Navigation
    var sidebarSelection: SidebarItem? = .home {
        didSet {
            switch sidebarSelection {
            case .favorites: liveScope = .favorites
            case .recent: liveScope = .recent
            case .group(let id): liveScope = .group(id)
            case .liveTV:
                if [.favorites, .recent].contains(liveScope) || isGroupScope { liveScope = .all }
            default: break
            }
            if player.isFullWindow { exitFullWindow() }
        }
    }
    /// Channel list shown in the Live TV guide.
    var liveScope: ChannelScope = .all
    var searchQuery = ""
    var sourceEditor: SourceEditorRequest?
    var showShortcutHelp = false
    /// Trailer playing in the in-app trailer overlay (`TrailerOverlay`), if any.
    private(set) var trailer: TrailerRequest?
    /// Whether presenting the trailer paused the main player (so dismissing it resumes playback).
    @ObservationIgnored private var trailerPausedPlayback = false

    // MARK: Data
    private(set) var sources: [Source] = []
    private(set) var customGroups: [CustomGroup] = []
    private(set) var activeSyncs: [String: SyncEvent] = [:]
    /// Bumped (debounced) when channels/categories/VOD/sources change — views reload on change.
    private(set) var libraryRevision = 0
    /// Bumped when guide data changes.
    private(set) var guideRevision = 0
    /// Bumped when user state changes (favourites, hidden, progress, reminders, recordings, history).
    private(set) var userRevision = 0
    private(set) var banners: [Banner] = []
    private(set) var reminders: [Reminder] = []
    private(set) var recordings: [Recording] = []

    // MARK: Downloads & connectivity
    /// Every download, newest first. Refreshed about every second while something is queued or downloading,
    /// every 10 s otherwise, and right after each download action.
    private(set) var downloadItems: [DownloadItem] = []
    /// `downloadItems` keyed by movie/episode id.
    private(set) var downloadsById: [String: DownloadItem] = [:]
    /// Smoothed transfer rate in bytes per second of running downloads, by id.
    private(set) var downloadSpeeds: [String: Double] = [:]
    /// Queued, downloading or automatically paused downloads (the sidebar badge).
    private(set) var activeDownloadCount = 0
    /// True while downloads wait because the player streams from an account that allows a single connection.
    private(set) var downloadsSuspended = false
    /// No usable network path (NWPathMonitor). Downloads stay playable; streaming and lookups fail quietly.
    private(set) var isOffline = false
    /// The list the user is browsing; channel up/down walks it.
    var zapList: [Channel] = []
    /// Incremented on every channel change of the main player (overlays flash the channel banner).
    private(set) var channelChangeToken = 0
    private(set) var previousChannel: Channel?

    /// The main browsing window (keyboard shortcuts only act there).
    @ObservationIgnored weak var mainWindow: NSWindow?

    /// False until the first source list load; avoids flashing onboarding at launch.
    private(set) var sourcesLoaded = false
    /// True while sources are still loading, so views don't flash the Welcome screen.
    var hasSources: Bool { !sourcesLoaded || !sources.isEmpty }
    var isSyncing: Bool { !activeSyncs.isEmpty }
    var mpvAvailable: Bool { EngineFactory.mpvAvailable }

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var autoSwitched: Set<String> = []
    @ObservationIgnored private var guideHintShown: Set<String> = []
    @ObservationIgnored private var lastPlayedChannel: Channel?
    @ObservationIgnored private var downloadSamples: [String: (bytes: Int64, time: Date)] = [:]
    @ObservationIgnored private var downloadSuspensionTask: Task<Void, Never>?
    @ObservationIgnored private var downloadSuspensionBannerShown = false
    /// Episodes of a show finished while more of it is still downloading: one banner when the batch is done.
    @ObservationIgnored private var finishedEpisodesBySeries: [String: Int] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var offlineSince: Date?

    init(db: AppDatabase, prefs: Preferences, dataDirectory: URL) {
        self.db = db
        imdbRatings = IMDbRatingsService(db: db, directory: dataDirectory.appendingPathComponent("IMDb", isDirectory: true))
        self.prefs = prefs
        sync = SyncService(db: db)
        resolver = StreamResolver(db: db, sync: sync)
        recorder = RecordingService(db: db, resolver: resolver, directory: URL(fileURLWithPath: prefs.recordingsPath))
        downloads = DownloadService(db: db, resolver: resolver, directory: URL(fileURLWithPath: prefs.downloadsPath, isDirectory: true))
        metadata = MetadataService(db: db)
        player = PlayerManager(services: PlayerServices(db: db, resolver: resolver, prefs: prefs))
        for slot in player.slots { wire(slot) }
    }

    private var isGroupScope: Bool {
        if case .group = liveScope { return true }
        return false
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await applyPreferences()
        await reloadUserData()
        sources = (try? await db.sources()) ?? []
        sourcesLoaded = true
        startNetworkMonitor()
        startDownloads()

        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await list in self.db.observeSources() { self.sources = list }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in await self.sync.events() { self.handle(event) }
        })
        observe(["channel", "category", "movie", "series", "episode", "source", "customGroup", "customGroupMember"]) { $0.libraryRevision += 1 }
        observe(["program", "epgChannel", "epgFeed"]) { $0.guideRevision += 1 }
        observe(["channelPref", "categoryPref", "watchProgress", "vodFavorite", "history", "reminder", "recording", "customGroup", "customGroupMember"]) { model in
            model.userRevision += 1
            Task { await model.reloadUserData() }
        }

        // Auto refresh (stale sources), shortly after launch then every 10 minutes.
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled, let self {
                await self.sync.syncDueSources(defaultLiveHours: self.prefs.liveRefreshHours, defaultVODHours: self.prefs.vodRefreshHours)
                try? await Task.sleep(for: .seconds(600))
            }
        })
        // Reminders + DVR scheduler.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.reminderTick()
                await self.recorder.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        })
        // Keep "now playing" programme info fresh.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refreshNowPlaying()
                try? await Task.sleep(for: .seconds(30))
            }
        })
    }

    func shutdown() {
        tasks.forEach { $0.cancel() }
        pathMonitor?.cancel()
        player.shutdown()
        Task { await recorder.stopAll() }
    }

    func applyPreferences() async {
        await resolver.setDefaultUserAgent(prefs.defaultUserAgent)
        await metadata.configure(prefs.metadataSettings)
        await recorder.configure(
            directory: URL(fileURLWithPath: prefs.recordingsPath),
            startPadding: TimeInterval(prefs.recordingStartPaddingMinutes * 60),
            endPadding: TimeInterval(prefs.recordingEndPaddingMinutes * 60)
        )
        await downloads.setDirectory(URL(fileURLWithPath: prefs.downloadsPath, isDirectory: true))
    }

    private func observe(_ tables: [String], _ bump: @escaping @MainActor (AppModel) -> Void) {
        tasks.append(Task { [weak self] in
            guard let stream = self?.db.changes(in: tables) else { return }
            var pending: Task<Void, Never>?
            for await _ in stream {
                pending?.cancel()
                pending = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled, let self else { return }
                    bump(self)
                }
            }
        })
    }

    private func reloadUserData() async {
        customGroups = (try? await db.customGroups()) ?? []
        reminders = (try? await db.reminders()) ?? []
        recordings = (try? await db.recordings()) ?? []
    }

    // MARK: - Sync

    private func handle(_ event: SyncEvent) {
        switch event.phase {
        case .finished:
            activeSyncs[event.sourceId] = nil
            let id = event.sourceId
            let name = event.sourceName
            Task { await hintIfNoGuide(sourceId: id, name: name) }
        case .failed:
            activeSyncs[event.sourceId] = nil
            notify(Banner(symbol: "exclamationmark.triangle.fill", title: "Couldn't refresh \(event.sourceName)", message: event.message, isError: true))
        case .guide where event.message != nil:
            activeSyncs[event.sourceId] = event
            notify(Banner(symbol: "calendar.badge.exclamationmark", title: "Guide problem for \(event.sourceName)", message: event.message, isError: true))
        default:
            activeSyncs[event.sourceId] = event
        }
    }

    /// Some providers publish no guide at all (empty xmltv.php, no per-channel EPG). Say so once, with the fix,
    /// rather than leaving every row reading "No guide information".
    private func hintIfNoGuide(sourceId: String, name: String) async {
        guard !guideHintShown.contains(sourceId),
              let coverage = try? await db.guideCoverage(sourceId: sourceId),
              coverage.channels > 0, coverage.withGuide == 0 else { return }
        guideHintShown.insert(sourceId)
        notify(Banner(symbol: "calendar.badge.exclamationmark", title: "\(name) doesn't include a TV guide",
                      message: "Add an XMLTV guide under Settings → Playlists → Global Guide Feeds; channels are matched by name."))
    }

    func syncAll() {
        for source in sources where source.enabled {
            let id = source.id
            Task { await sync.sync(sourceId: id) }
        }
        Task { _ = await sync.guide.refreshGlobalFeeds() }
    }

    func sync(_ sourceId: String, options: SyncOptions = .all) {
        Task { await sync.sync(sourceId: sourceId, options: options) }
    }

    // MARK: - Sources

    func addSource(_ source: Source) {
        var s = source
        s.sortIndex = (sources.map(\.sortIndex).max() ?? -1) + 1
        let saved = s
        Task {
            try? await db.save(saved)
            await sync.sync(sourceId: saved.id)
        }
        if sidebarSelection == nil || sidebarSelection == .home { sidebarSelection = .liveTV }
    }

    func updateSource(_ source: Source) {
        let old = sources.first { $0.id == source.id }
        Task {
            try? await db.save(source)
            let connectionChanged = old.map {
                $0.url != source.url || $0.username != source.username || $0.password != source.password || $0.mac != source.mac
                    || $0.epgURL != source.epgURL || $0.extraEPGURLs != source.extraEPGURLs || $0.epgTimeshiftHours != source.epgTimeshiftHours
                    || $0.includeLive != source.includeLive || $0.includeVOD != source.includeVOD || $0.autoLoadEPG != source.autoLoadEPG
                    || (!$0.enabled && source.enabled)
            } ?? true
            if connectionChanged, source.enabled { await sync.sync(sourceId: source.id) }
        }
    }

    func deleteSource(_ source: Source) {
        if let item = player.main.item, item.channel?.sourceId == source.id { player.main.stop() }
        Task { try? await db.deleteSource(id: source.id) }
    }

    func moveSources(from offsets: IndexSet, to destination: Int) {
        var list = sources
        list.move(fromOffsets: offsets, toOffset: destination)
        Task {
            for (i, var s) in list.enumerated() where s.sortIndex != i {
                s.sortIndex = i
                try? await db.save(s)
            }
        }
    }

    func testSource(_ source: Source) async throws -> String {
        try await sync.test(source)
    }

    /// Extended M3U of visible channels (all sources, or one).
    func exportM3U(sourceId: String?) async -> String {
        let scope: ChannelScope = sourceId.map { .source($0) } ?? .all
        let channels = (try? await db.channels(scope: scope, sort: prefs.channelSort)) ?? []
        let cats = (try? await db.categories(kind: .live)) ?? []
        let names = Dictionary(cats.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var urls: [String: String] = [:]
        // Stalker links are tokenised per play (create_link), so they can't be exported.
        for ch in channels where !ch.streamURL.hasPrefix("stalker:") {
            if let stream = try? await resolver.live(ch, format: .ts) {
                urls[ch.id] = stream.url.absoluteString
            }
        }
        return M3UExporter.export(channels, categoryNames: names) { urls[$0.id] }
    }

    // MARK: - Playback

    private func wire(_ slot: PlayerSlot) {
        slot.onNotice = { [weak self] title, message, isError in
            self?.notify(Banner(symbol: "airplayvideo", title: title, message: message, isError: isError))
        }
        slot.onItemChange = { [weak self, weak slot] item in
            guard let self, let slot else { return }
            if slot === self.player.main { self.mainItemChanged(item) }
            if let channel = item?.channel, item?.isLive == true {
                Task { slot.currentProgram = await self.currentProgram(for: channel) }
            }
        }
        slot.onEnded = { [weak self, weak slot] item in
            guard let self, let slot, slot === self.player.main else { return }
            if case .episode(let ep, let series) = item, self.prefs.autoplayNextEpisode, self.upNextCancelledFor != ep.id {
                // Offline, only a downloaded next episode can play.
                if self.isOffline, let next = self.adjacentEpisode(1), !self.isDownloaded(next.id) { return }
                Task { await self.playNextEpisode(after: ep, in: series) }
            }
        }
        slot.beforeLoad = { [weak self] item in
            await self?.freeConnectionForPlayback(item)
        }
    }

    private func mainItemChanged(_ item: PlaybackItem?) {
        loadEpisodeContext(for: item)
        guard let channel = item?.channel, item?.isLive == true else { return }
        if let last = lastPlayedChannel, last.id != channel.id { previousChannel = last }
        lastPlayedChannel = channel
        prefs.lastChannelId = channel.id
        channelChangeToken += 1
        Task { try? await db.recordWatched(channelId: channel.id) }
    }

    /// Plays a live channel in the main player (preview/mini unless `fullWindow`).
    func play(_ channel: Channel, fullWindow: Bool = false) {
        if player.main.item?.channel?.id == channel.id, player.main.item?.isLive == true, player.main.phase.isActive {
            if fullWindow { enterFullWindow() }
            return
        }
        player.play(.channel(channel))
        if fullWindow { enterFullWindow() }
    }

    func playCatchup(_ channel: Channel, program: Program) {
        player.play(.catchup(channel, program))
        enterFullWindow()
    }

    /// Plays a movie, resuming from saved progress when enabled.
    func play(movie: Movie, fromStart: Bool = false) async {
        var start: Double?
        if !fromStart, prefs.resumePlayback, let p = try? await db.progress(mediaId: movie.id), !p.completed, p.position > 10 {
            start = p.position
        }
        player.play(.movie(movie), startAt: start)
        enterFullWindow()
    }

    func play(episode: Episode, in series: Series, fromStart: Bool = false) async {
        var start: Double?
        if !fromStart, prefs.resumePlayback, let p = try? await db.progress(mediaId: episode.id), !p.completed, p.position > 10 {
            start = p.position
        }
        player.play(.episode(episode, series), startAt: start)
        enterFullWindow()
    }

    /// Resumes a "Continue Watching" entry.
    func resume(_ progress: WatchProgress) async {
        switch progress.kind {
        case .movie:
            if let m = try? await db.movie(id: progress.mediaId) { await play(movie: m) }
        case .episode:
            if let e = try? await db.episode(id: progress.mediaId), let sid = progress.seriesId, let s = try? await db.series(id: sid) {
                await play(episode: e, in: s)
            }
        case .channel:
            break
        }
    }

    func play(recording: Recording) {
        guard recording.filePath != nil else { return }
        player.play(.recording(recording))
        enterFullWindow()
    }

    /// Sends a channel to the next multiview cell (switching layout if needed).
    func playInMultiview(_ channel: Channel) {
        warnIfOverConnectionLimit(adding: channel)
        let count = max(player.layout.slotCount, 1)
        let free = (1..<4).first { $0 >= count ? false : player.slot(at: $0).item == nil }
        if let free {
            player.play(.channel(channel), at: free)
        } else if player.layout == .single {
            player.layout = .pictureInPicture
            player.play(.channel(channel), at: 1)
        } else {
            if player.layout != .grid2x2 && player.layout != .bigAndBottom { player.layout = .grid2x2 }
            let target = (1..<4).first { player.slot(at: $0).item == nil } ?? 3
            player.play(.channel(channel), at: target)
        }
    }

    /// Many accounts allow a single stream; a second simultaneous stream from the same playlist usually fails.
    private func warnIfOverConnectionLimit(adding channel: Channel) {
        guard let source = sources.first(where: { $0.id == channel.sourceId }), let max = source.maxConnections, max > 0 else { return }
        let inUse = player.slots.filter { $0.item?.channel?.sourceId == source.id && $0.phase.isActive }.count
        if inUse + 1 > max {
            notify(Banner(symbol: "exclamationmark.triangle.fill", title: "\(source.name) allows \(max) stream\(max == 1 ? "" : "s") at a time",
                          message: "Watching more channels from this playlist at once may fail or stop the other stream.", isError: true))
        }
    }

    func playNextEpisode(after episode: Episode, in series: Series) async {
        await playEpisode(EpisodeNavigation.neighbor(of: episode.id, in: await episodes(of: series), offset: 1), in: series)
    }

    func playPreviousEpisode(before episode: Episode, in series: Series) async {
        await playEpisode(EpisodeNavigation.neighbor(of: episode.id, in: await episodes(of: series), offset: -1), in: series)
    }

    private func playEpisode(_ episode: Episode?, in series: Series) async {
        guard let episode else { return }
        await play(episode: episode, in: series, fromStart: true)
    }

    // MARK: Episode context (player's previous/next, episode list, Up Next)

    /// The show and its episodes when the main player is playing an episode; nil otherwise.
    private(set) var episodeContext: EpisodeContext?
    /// The episode whose Up Next countdown the user dismissed: it then doesn't autoplay into the next one.
    private(set) var upNextCancelledFor: String?

    struct EpisodeContext: Equatable {
        let series: Series
        let episodes: [Episode]
    }

    /// The episode playing in the main player, with its show.
    var currentEpisode: (episode: Episode, series: Series)? {
        if case .episode(let episode, let series)? = player.main.item { return (episode, series) }
        return nil
    }

    func adjacentEpisode(_ offset: Int) -> Episode? {
        guard let current = currentEpisode, let context = episodeContext, context.series.id == current.series.id else { return nil }
        return EpisodeNavigation.neighbor(of: current.episode.id, in: context.episodes, offset: offset)
    }

    func playAdjacentEpisode(_ offset: Int) {
        guard let current = currentEpisode, let target = adjacentEpisode(offset) else { return }
        Task { await play(episode: target, in: current.series, fromStart: true) }
    }

    /// Marks episodes watched or unwatched in one write, keeping any existing progress records' details.
    func setWatched(_ episodes: [Episode], in series: Series, watched: Bool, existing: [String: WatchProgress]) async {
        let records = episodes.map { episode in
            existing[episode.id] ?? WatchProgress(
                mediaId: episode.id, kind: .episode, sourceId: episode.sourceId, seriesId: series.id, title: series.name,
                subtitle: "S\(episode.season), E\(episode.number) · \(episode.title)",
                posterURL: episode.imageURL ?? series.backdropURL ?? series.coverURL,
                position: 0, duration: Double(episode.durationSeconds ?? 1)
            )
        }
        try? await db.markWatched(records, watched: watched)
    }

    /// Hides the Up Next card for the current episode and stops it from rolling into the next one.
    func cancelUpNext() {
        upNextCancelledFor = currentEpisode?.episode.id
    }

    /// IMDb ratings of a show's episodes, keyed by `EpisodeRatingKey`. Empty until the IMDb service knows the show.
    func episodeRatings(for series: Series) async -> [EpisodeRatingKey: Double] {
        // The show's IMDb id comes from its online metadata (cached after the first lookup). Offline, only the cache.
        let info = isOffline ? await metadata.cachedMetadata(mediaId: series.id) : await metadata.metadata(for: series)
        guard let imdbId = info?.imdbId else { return [:] }
        // With online lookups turned off (or no network), show what's cached but don't download IMDb's data sets.
        let ratings = await metadata.settings.enabled && !isOffline
            ? await imdbRatings.ratings(seriesIMDbId: imdbId)
            : await imdbRatings.cachedRatings(seriesIMDbId: imdbId)
        return Dictionary(ratings.map { (EpisodeRatingKey(season: $0.season, episode: $0.episode), $0.rating) },
                          uniquingKeysWith: { first, _ in first })
    }

    private func episodes(of series: Series) async -> [Episode] {
        if let context = episodeContext, context.series.id == series.id { return context.episodes }
        return (try? await db.episodes(seriesId: series.id)) ?? []
    }

    private func loadEpisodeContext(for item: PlaybackItem?) {
        upNextCancelledFor = nil
        guard case .episode(_, let series)? = item else {
            episodeContext = nil
            player.isEpisodeListOpen = false
            return
        }
        if episodeContext?.series.id == series.id { return }
        episodeContext = nil
        Task {
            let episodes = (try? await db.episodes(seriesId: series.id)) ?? []
            guard case .episode(_, let current)? = player.main.item, current.id == series.id else { return }
            episodeContext = EpisodeContext(series: series, episodes: episodes)
            // Warm the ratings (and, the first time ever, IMDb's data sets) so the episode list opens with them.
            _ = await episodeRatings(for: series)
        }
    }

    func stopPlayback() {
        player.stopAll()
    }

    /// Shows a trailer inside the app, pausing whatever the main player is playing until it's dismissed.
    func presentTrailer(_ url: URL, title: String) {
        let main = player.main
        trailerPausedPlayback = trailer == nil && main.isPlaying
        if trailerPausedPlayback { main.togglePause() }
        trailer = TrailerRequest(url: url, title: title)
    }

    func dismissTrailer() {
        guard trailer != nil else { return }
        trailer = nil
        if trailerPausedPlayback, player.main.phase == .paused { player.main.togglePause() }
        trailerPausedPlayback = false
    }

    func enterFullWindow() {
        guard player.hasMedia else { return }
        player.isFullWindow = true
    }

    func exitFullWindow() {
        guard player.isFullWindow else { return }
        player.isFullWindow = false
        player.isEpisodeListOpen = false
        // Leaving finite media stops it (progress is saved), like the TV app; live keeps playing in the mini player.
        if let item = player.main.item, !item.isLive, player.layout == .single {
            player.main.stop()
        }
    }

    func toggleFullWindow() {
        player.isFullWindow ? exitFullWindow() : enterFullWindow()
    }

    func toggleWindowFullScreen() {
        (mainWindow ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    func channelUp() { zap(by: -1) }
    func channelDown() { zap(by: 1) }

    private func zap(by step: Int) {
        let list = zapList
        guard !list.isEmpty else { return }
        let currentId = player.main.item?.channel?.id
        let index = list.firstIndex { $0.id == currentId } ?? (step > 0 ? -1 : 0)
        let next = list[(index + step + list.count) % list.count]
        player.main.play(.channel(next))
    }

    /// "Q": back to the previously watched channel.
    func playPreviousChannel() {
        if let prev = previousChannel {
            player.main.play(.channel(prev))
        } else if let id = prefs.lastChannelId {
            Task { if let ch = try? await db.channel(id: id) { play(ch) } }
        }
    }

    private func refreshNowPlaying() async {
        for slot in player.slots {
            guard let channel = slot.item?.channel, slot.item?.isLive == true else { continue }
            let program = await currentProgram(for: channel)
            if slot.currentProgram != program { slot.currentProgram = program }
        }
    }

    // MARK: - Guide helpers

    func currentProgram(for channel: Channel, at date: Date = Date()) async -> Program? {
        guard let key = channel.epgKey else { return nil }
        let map = (try? await db.programs(epgKeys: [key], from: date, to: date.addingTimeInterval(1))) ?? [:]
        return map[key]?.first { $0.isLive(at: date) }
    }

    /// Programmes keyed by EPG key for the given channels.
    func programs(for channels: [Channel], from: Date, to: Date) async -> [String: [Program]] {
        let keys = channels.compactMap(\.epgKey)
        return (try? await db.programs(epgKeys: keys, from: from, to: to)) ?? [:]
    }

    // MARK: - Library actions

    func toggleFavorite(_ channel: Channel) {
        setFavorite(channel, !channel.isFavorite)
    }

    func setFavorite(_ channel: Channel, _ value: Bool) {
        Task { try? await db.setFavorite(channelId: channel.id, value) }
    }

    func setHidden(_ channel: Channel, hidden: Bool) {
        Task { try? await db.setHidden(channelId: channel.id, hidden) }
    }

    func rename(_ channel: Channel, to name: String?) {
        Task { try? await db.setAlias(channelId: channel.id, name) }
    }

    func setCategoryHidden(_ category: TunerCore.Category, hidden: Bool) {
        Task { try? await db.setCategoryHidden(categoryId: category.id, hidden) }
    }

    func renameCategory(_ category: TunerCore.Category, to name: String?) {
        Task { try? await db.setCategoryAlias(categoryId: category.id, name) }
    }

    /// Returns the new favourite state.
    @discardableResult
    func toggleVODFavorite(mediaId: String, kind: MediaKind) async -> Bool {
        let current = (try? await db.isVODFavorite(mediaId: mediaId)) ?? false
        try? await db.setVODFavorite(mediaId: mediaId, kind: kind, !current)
        return !current
    }

    func createGroup(named name: String, with channel: Channel? = nil) {
        Task {
            guard let group = try? await db.createGroup(name: name) else { return }
            if let channel { try? await db.addToGroup(groupId: group.id, channelId: channel.id) }
        }
    }

    func addToGroup(_ channel: Channel, groupId: String) {
        Task { try? await db.addToGroup(groupId: groupId, channelId: channel.id) }
    }

    func removeFromGroup(_ channel: Channel, groupId: String) {
        Task { try? await db.removeFromGroup(groupId: groupId, channelId: channel.id) }
    }

    func renameGroup(_ group: CustomGroup, to name: String) {
        Task { try? await db.renameGroup(id: group.id, name: name) }
    }

    func deleteGroup(_ group: CustomGroup) {
        if sidebarSelection == .group(group.id) { sidebarSelection = .liveTV }
        Task { try? await db.deleteGroup(id: group.id) }
    }

    // MARK: - Reminders

    func hasReminder(for program: Program) -> Bool {
        reminders.contains { $0.programKey == program.stableKey }
    }

    func toggleReminder(channel: Channel, program: Program, autoSwitch: Bool = false) {
        if hasReminder(for: program) {
            reminders.removeAll { $0.programKey == program.stableKey }
            Task { try? await db.deleteReminder(programKey: program.stableKey) }
            return
        }
        let reminder = Reminder(channelId: channel.id, channelName: channel.displayName, programKey: program.stableKey,
                                title: program.title, start: program.start, end: program.end, autoSwitch: autoSwitch)
        reminders.append(reminder)
        Task { try? await db.save(reminder) }
        requestNotificationPermission()
        notify(Banner(symbol: "bell.fill", title: "Reminder set", message: "\(program.title) · \(program.start.formatted(date: .omitted, time: .shortened))"))
    }

    private func reminderTick() async {
        let now = Date()
        let lead = TimeInterval(prefs.reminderLeadMinutes * 60)
        for var r in reminders {
            if !r.notified, now >= r.start.addingTimeInterval(-lead), now < r.end {
                r.notified = true
                try? await db.save(r)
                let channelId = r.channelId
                notify(Banner(symbol: "bell.badge.fill", title: "\(r.title) \(now >= r.start ? "is on now" : "starts soon")",
                              message: r.channelName, actionTitle: "Watch") { [weak self] in
                    guard let self else { return }
                    Task { if let ch = try? await self.db.channel(id: channelId) { self.play(ch, fullWindow: true) } }
                })
                postSystemNotification(title: r.title, body: "\(r.channelName) · \(r.start.formatted(date: .omitted, time: .shortened))")
            }
            if r.autoSwitch, !autoSwitched.contains(r.id), now >= r.start, now < r.start.addingTimeInterval(120) {
                autoSwitched.insert(r.id)
                if let ch = try? await db.channel(id: r.channelId) { play(ch, fullWindow: true) }
            }
        }
        if reminders.contains(where: { $0.end < now }) {
            try? await db.deleteExpiredReminders(before: now)
        }
    }

    /// UNUserNotificationCenter aborts in processes that aren't a real .app bundle (e.g. `swift run`).
    private var canUseSystemNotifications: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func requestNotificationPermission() {
        guard canUseSystemNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postSystemNotification(title: String, body: String) {
        guard canUseSystemNotifications, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Recordings

    func record(_ channel: Channel, program: Program) {
        Task {
            do {
                _ = try await recorder.schedule(channel: channel, program: program)
                notify(Banner(symbol: "record.circle", title: "Recording scheduled", message: "\(program.title) on \(channel.displayName)"))
            } catch {
                notify(Banner(symbol: "exclamationmark.triangle.fill", title: "Couldn't schedule recording", message: error.localizedDescription, isError: true))
            }
        }
    }

    /// Records the channel now until the current programme ends (or 1 hour).
    func recordNow(_ channel: Channel) {
        Task {
            let program = await currentProgram(for: channel)
            let end = program?.end ?? Date().addingTimeInterval(3600)
            do {
                _ = try await recorder.recordNow(channel: channel, title: program?.title ?? channel.displayName, end: end)
                notify(Banner(symbol: "record.circle.fill", title: "Recording \(channel.displayName)", message: "Until \(end.formatted(date: .omitted, time: .shortened))"))
            } catch {
                notify(Banner(symbol: "exclamationmark.triangle.fill", title: "Couldn't start recording", message: error.localizedDescription, isError: true))
            }
        }
    }

    func isRecording(_ channel: Channel) -> Bool {
        recordings.contains { $0.channelId == channel.id && $0.status == .recording }
    }

    func isScheduled(_ program: Program, on channel: Channel) -> Bool {
        recordings.contains { $0.channelId == channel.id && ($0.status == .scheduled || $0.status == .recording)
            && $0.start <= program.start.addingTimeInterval(60) && $0.end >= program.end.addingTimeInterval(-60) }
    }

    func cancelRecording(_ recording: Recording) {
        Task { await recorder.cancel(id: recording.id) }
    }

    func deleteRecording(_ recording: Recording, deleteFile: Bool) {
        Task {
            await recorder.cancel(id: recording.id)
            if deleteFile, let path = recording.filePath { try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
            try? await db.deleteRecording(id: recording.id)
        }
    }

    // MARK: - Downloads

    private func startDownloads() {
        tasks.append(Task { [weak self] in
            await self?.downloads.start()
            var idleSeconds = 10
            while !Task.isCancelled, let self {
                // Every second while something moves; otherwise every 10 s (engine-side changes such as an automatic
                // resume). Actions refresh right away on their own.
                if self.downloadItems.contains(where: { $0.state == .queued || $0.state == .downloading }) || idleSeconds >= 10 {
                    idleSeconds = 0
                    await self.refreshDownloads()
                } else {
                    idleSeconds += 1
                }
                try? await Task.sleep(for: .seconds(1))
            }
        })
        trackDownloadSuspension()
    }

    /// Reloads the download list from the service (cheap: one actor call).
    func refreshDownloads() async {
        applyDownloads(await downloads.items())
    }

    private func applyDownloads(_ items: [DownloadItem]) {
        let now = Date()
        let previous = downloadsById

        // Transfer rate from consecutive samples, smoothed so the label doesn't flicker.
        var speeds: [String: Double] = [:]
        var samples: [String: (bytes: Int64, time: Date)] = [:]
        for item in items where item.state == .downloading {
            if let sample = downloadSamples[item.id] {
                let elapsed = now.timeIntervalSince(sample.time)
                if elapsed >= 0.5 {
                    let instant = max(0, Double(item.receivedBytes - sample.bytes) / elapsed)
                    speeds[item.id] = downloadSpeeds[item.id].map { $0 * 0.6 + instant * 0.4 } ?? instant
                    samples[item.id] = (item.receivedBytes, now)
                } else {
                    speeds[item.id] = downloadSpeeds[item.id]
                    samples[item.id] = sample
                }
            } else {
                samples[item.id] = (item.receivedBytes, now)
            }
        }
        downloadSamples = samples
        if speeds != downloadSpeeds { downloadSpeeds = speeds }

        if items != downloadItems {
            downloadItems = items
            downloadsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let active = items.filter(\.isPending).count
        if active != activeDownloadCount { activeDownloadCount = active }

        for item in items {
            guard let old = previous[item.id], old.state != item.state else { continue }
            switch item.state {
            case .completed: announceDownloaded(item)
            case .failed: announceDownloadFailed(item)
            default: break
            }
        }
    }

    private func announceDownloaded(_ item: DownloadItem) {
        // A season downloads episode by episode: announce the batch once, when the show has nothing left in the queue.
        if item.kind == .episode, let seriesId = item.seriesId {
            if downloadItems.contains(where: { $0.seriesId == seriesId && $0.isPending }) {
                finishedEpisodesBySeries[seriesId, default: 0] += 1
                return
            }
            let count = (finishedEpisodesBySeries.removeValue(forKey: seriesId) ?? 0) + 1
            if count > 1 {
                notify(Banner(symbol: "arrow.down.circle.fill", title: "Downloaded \(count) episodes of “\(item.title)”",
                              message: "Ready to watch, even offline.", actionTitle: "Show") { [weak self] in
                    self?.sidebarSelection = .downloads
                })
                return
            }
        }
        notify(Banner(symbol: "arrow.down.circle.fill", title: "Downloaded “\(item.title)”",
                      message: item.kind == .episode ? item.subtitle : "Ready to watch, even offline.",
                      actionTitle: "Play") { [weak self] in
            guard let self else { return }
            Task { await self.playDownload(item) }
        })
    }

    private func announceDownloadFailed(_ item: DownloadItem) {
        let what = [item.title, item.kind == .episode ? item.subtitle : nil].compactMap { $0 }.joined(separator: " · ")
        notify(Banner(symbol: "exclamationmark.triangle.fill", title: "Couldn't download “\(item.title)”",
                      message: item.error?.nilIfEmpty ?? what, actionTitle: "Try Again", action: { [weak self] in
            self?.resumeDownload(item.id)
        }, isError: true))
    }

    /// Whether a movie/episode is saved on this Mac.
    func isDownloaded(_ mediaId: String) -> Bool {
        downloadsById[mediaId]?.state == .completed
    }

    func download(movie: Movie) {
        Task {
            do {
                try await downloads.enqueue(movie: movie)
                await refreshDownloads()
                announceQueuedWhileSuspended()
            } catch {
                notify(Banner(symbol: "exclamationmark.triangle.fill", title: "Couldn't download “\(movie.name)”",
                              message: error.localizedDescription, isError: true))
            }
        }
    }

    /// Queues episodes in watch order (already queued or downloaded ones are skipped by the service).
    func download(episodes: [Episode], of series: Series) {
        guard !episodes.isEmpty else { return }
        let ordered = episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        Task {
            do {
                try await downloads.enqueue(episodes: ordered, of: series)
                await refreshDownloads()
                announceQueuedWhileSuspended()
            } catch {
                notify(Banner(symbol: "exclamationmark.triangle.fill", title: "Couldn't download \(series.name)",
                              message: error.localizedDescription, isError: true))
            }
        }
    }

    func pauseDownload(_ id: String) {
        Task {
            await downloads.pause(id: id)
            await refreshDownloads()
        }
    }

    /// Resumes a paused download, or retries a failed one.
    func resumeDownload(_ id: String) {
        Task {
            await downloads.resume(id: id)
            await refreshDownloads()
        }
    }

    /// Stops an unfinished download and discards what was saved so far.
    func cancelDownload(_ id: String) {
        Task {
            await downloads.cancel(id: id)
            await refreshDownloads()
        }
    }

    /// Removes a download and its file.
    func deleteDownload(_ id: String) {
        stopIfPlayingDownload(ids: [id])
        Task {
            await downloads.delete(id: id)
            await refreshDownloads()
        }
    }

    func pauseAllDownloads() {
        let ids = downloadItems.filter(\.isPending).map(\.id)
        Task {
            for id in ids { await downloads.pause(id: id) }
            await refreshDownloads()
        }
    }

    /// Resumes user-paused downloads and retries failed ones.
    func resumeAllDownloads() {
        let ids = downloadItems.filter { $0.isPausedByUser || $0.state == .failed }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.id)
        Task {
            for id in ids { await downloads.resume(id: id) }
            await refreshDownloads()
        }
    }

    /// Deletes every download and its file (unfinished ones are cancelled).
    func deleteAllDownloads() {
        let items = downloadItems
        stopIfPlayingDownload(ids: Set(items.map(\.id)))
        Task {
            for item in items {
                if item.state == .completed { await downloads.delete(id: item.id) } else { await downloads.cancel(id: item.id) }
            }
            await refreshDownloads()
        }
    }

    /// The file being deleted can't keep playing.
    private func stopIfPlayingDownload(ids: Set<String>) {
        for slot in player.slots {
            if let key = slot.item?.progressKey, ids.contains(key), slot.stream?.url.isFileURL == true { slot.stop() }
        }
    }

    /// Plays a download, preferring the library's current records (progress, artwork) and falling back to what the
    /// download remembers when the playlist no longer lists the title.
    func playDownload(_ item: DownloadItem) async {
        switch item.kind {
        case .movie:
            var movie = (try? await db.movie(id: item.id)) ?? Movie(id: item.id, sourceId: item.sourceId, categoryId: nil,
                                                                     name: item.title, providerId: "", providerOrder: 0)
            if movie.posterURL == nil { movie.posterURL = item.artworkURL }
            await play(movie: movie)
        case .episode:
            let seriesId = item.seriesId ?? ""
            var episode = (try? await db.episode(id: item.id)) ?? Episode(
                id: item.id, seriesId: seriesId, sourceId: item.sourceId, season: item.season ?? 1, number: item.episode ?? 1,
                title: Self.episodeTitle(fromSubtitle: item.subtitle) ?? item.title, providerId: "")
            if episode.imageURL == nil { episode.imageURL = item.artworkURL }
            var series = (try? await db.series(id: seriesId)) ?? Series(id: seriesId, sourceId: item.sourceId, categoryId: nil,
                                                                       name: item.title, providerId: seriesId, providerOrder: 0)
            if series.coverURL == nil { series.coverURL = item.artworkURL }
            await play(episode: episode, in: series)
        }
    }

    /// "S1, E3 · Pilot" → "Pilot".
    static func episodeTitle(fromSubtitle subtitle: String?) -> String? {
        guard let subtitle, let range = subtitle.range(of: " · ") else { return nil }
        return String(subtitle[range.upperBound...]).nilIfEmpty
    }

    /// Changes the folder for new downloads.
    func setDownloadsFolder(_ url: URL) {
        prefs.downloadsPath = url.path
        Task { await downloads.setDirectory(url) }
    }

    // MARK: Single-connection accounts

    /// The account a slot streams from over the network; nil when it's idle or playing a file on this Mac.
    private func networkSourceId(of slot: PlayerSlot) -> String? {
        guard let item = slot.item, slot.phase.isActive else { return nil }
        let isLocal: Bool
        if slot.phase != .loading, let stream = slot.stream {
            isLocal = stream.url.isFileURL
        } else if case .recording = item {
            isLocal = true
        } else {
            // While loading, `stream` may still be the previous item's: a completed download plays from its file.
            isLocal = item.progressKey.map(isDownloaded) ?? false
        }
        return isLocal ? nil : item.sourceId
    }

    /// Downloads wait while the player streams from an account that allows only one connection (the provider would
    /// otherwise refuse the stream or cut the download).
    private var downloadsShouldSuspend: Bool {
        let streaming = Set(player.slots.compactMap(networkSourceId))
        guard !streaming.isEmpty else { return false }
        return sources.contains { streaming.contains($0.id) && $0.maxConnections == 1 }
    }

    /// Re-evaluates `downloadsShouldSuspend` whenever anything it reads changes (players, sources, downloads).
    private func trackDownloadSuspension() {
        let shouldSuspend = withObservationTracking {
            downloadsShouldSuspend
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackDownloadSuspension() }
        }
        setDownloadsSuspended(shouldSuspend)
    }

    private func setDownloadsSuspended(_ suspended: Bool) {
        guard suspended != downloadsSuspended else { return }
        downloadsSuspended = suspended
        let service = downloads
        let previous = downloadSuspensionTask
        downloadSuspensionTask = Task { [weak self] in
            await previous?.value
            if suspended { await service.suspend() } else { await service.unsuspend() }
            await self?.refreshDownloads()
        }
        if suspended { announceQueuedWhileSuspended() }
    }

    /// "Downloads paused while you watch", once per launch and only when a download is actually waiting.
    private func announceQueuedWhileSuspended() {
        guard downloadsSuspended, !downloadSuspensionBannerShown,
              downloadItems.contains(where: \.isPending)
        else { return }
        downloadSuspensionBannerShown = true
        notify(Banner(symbol: "pause.circle.fill", title: "Downloads paused while you watch",
                      message: "Your account allows one stream at a time. Downloads continue when you stop watching."))
    }

    /// Runs before a player slot resolves and opens a stream: on a single-connection account the download has to let go
    /// of the connection first, or the provider refuses the stream.
    private func freeConnectionForPlayback(_ item: PlaybackItem) async {
        guard let sourceId = item.sourceId, sources.first(where: { $0.id == sourceId })?.maxConnections == 1,
              !downloadItems.isEmpty else { return }
        if let key = item.progressKey, await downloads.localFile(mediaId: key) != nil { return }
        setDownloadsSuspended(true)
        guard let pending = downloadSuspensionTask else { return }
        // Don't hold playback hostage if the service is slow to pause.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pending.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Connectivity

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in self?.setOffline(offline) }
        }
        monitor.start(queue: DispatchQueue(label: "app.tuner.macos.network", qos: .utility))
        pathMonitor = monitor
    }

    private func setOffline(_ offline: Bool) {
        guard offline != isOffline else { return }
        isOffline = offline
        if offline {
            offlineSince = Date()
            return
        }
        // Back online: retry now what's waiting out a network backoff, and what failed while the network was gone.
        let since = (offlineSince ?? Date()).addingTimeInterval(-30)
        offlineSince = nil
        let retry = downloadItems.filter {
            ($0.state == .queued && $0.error != nil) || ($0.state == .failed && $0.updatedAt >= since)
        }.map(\.id)
        Task {
            for id in retry { await downloads.resume(id: id) }
            await refreshDownloads()
        }
    }

    // MARK: - Banners

    func notify(_ banner: Banner) {
        banners.append(banner)
        if banners.count > 3 { banners.removeFirst(banners.count - 3) }
        let id = banner.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(banner.action == nil ? 5 : 10))
            self?.dismissBanner(id)
        }
    }

    func dismissBanner(_ id: UUID) {
        banners.removeAll { $0.id == id }
    }
}

/// A trailer to play in the in-app trailer overlay (a YouTube link/id or a direct video URL).
struct TrailerRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String
}

/// Season and episode number, for looking up per-episode data such as IMDb ratings.
struct EpisodeRatingKey: Hashable {
    let season: Int
    let episode: Int
}
