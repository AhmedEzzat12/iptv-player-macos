import Foundation

public struct SyncEvent: Sendable, Hashable {
    public enum Phase: String, Sendable {
        case started
        case channels
        case vod
        case guide
        case finished
        case failed
    }

    public var sourceId: String
    public var sourceName: String
    public var phase: Phase
    public var message: String?
}

public struct SyncOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let live = SyncOptions(rawValue: 1)
    public static let vod = SyncOptions(rawValue: 2)
    public static let guide = SyncOptions(rawValue: 4)
    public static let all: SyncOptions = [.live, .vod, .guide]
}

/// Orchestrates provider sync: fetch → replace rows → guide → status. One sync per source at a time.
public actor SyncService {
    public let db: AppDatabase
    public let guide: GuideService
    private var running: Set<String> = []
    private var stalkerClients: [String: StalkerClient] = [:]
    private var continuations: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]
    private var loadedStalkerCategories: [String: Date] = [:]

    public init(db: AppDatabase) {
        self.db = db
        self.guide = GuideService(db: db)
    }

    /// Subscribe to sync progress.
    public func events() -> AsyncStream<SyncEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in Task { await self.removeContinuation(id) } }
        }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func emit(_ source: Source, _ phase: SyncEvent.Phase, _ message: String? = nil) {
        let event = SyncEvent(sourceId: source.id, sourceName: source.name, phase: phase, message: message)
        for c in continuations.values { c.yield(event) }
    }

    public var activeSourceIds: Set<String> { running }

    public func stalkerClient(for source: Source) -> StalkerClient {
        let key = "\(source.id)|\(source.url)|\(source.mac ?? "")"
        if let c = stalkerClients[key] { return c }
        let c = StalkerClient(source: source)
        stalkerClients[key] = c
        return c
    }

    // MARK: - Sync

    public func sync(sourceId: String, options: SyncOptions = .all) async {
        guard !running.contains(sourceId), let source = try? await db.source(id: sourceId), source.enabled else { return }
        running.insert(sourceId)
        defer { running.remove(sourceId) }
        emit(source, .started)

        var discovered: [String] = []
        var errors: [String] = []
        var current = source
        var liveOK = false
        var vodOK = false

        if options.contains(.live) {
            emit(source, .channels)
            do {
                let (used, urls) = try await withBackups(source) { try await self.syncLive($0) }
                discovered = urls
                current = used
                liveOK = true
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        // VOD is attempted even if channels failed (and vice versa): a bad live response must not hide movies.
        if options.contains(.vod), current.includeVOD, current.kind != .m3u {
            emit(source, .vod)
            do {
                let (used, _) = try await withBackups(current) { s -> [String] in
                    try await self.syncVOD(s)
                    return []
                }
                current = used
                vodOK = true
            } catch {
                errors.append("Movies & series: \(error.localizedDescription)")
            }
        }

        if options.contains(.guide), current.includeLive, liveOK || !options.contains(.live) {
            emit(source, .guide)
            let client = current.kind == .stalker ? stalkerClient(for: current) : nil
            if let guideError = await guide.refresh(source: current, discovered: discovered, stalker: client) {
                // Guide problems are reported but don't mark the playlist as failed.
                emit(source, .guide, guideError)
            }
        }

        let failed = !errors.isEmpty
        let message = errors.joined(separator: "\n")
        let stampLive = liveOK
        let stampVOD = vodOK
        try? await db.updateSyncStatus(sourceId: sourceId) { s in
            s.lastError = failed ? message : nil
            // Stamp each part on its own success so a failed part is retried without redoing the rest.
            if stampLive { s.lastSyncedAt = Date() }
            if stampVOD { s.lastVODSyncedAt = Date() }
        }
        emit(source, failed ? .failed : .finished, failed ? message : nil)
    }

    /// Runs `body` against the primary URL, then each backup URL. A working backup is promoted to primary.
    private func withBackups<T>(_ source: Source, _ body: (Source) async throws -> T) async throws -> (Source, T) {
        do {
            return (source, try await body(source))
        } catch {
            var lastError = error
            for (index, backup) in source.backupURLs.enumerated() where !backup.isEmpty {
                var alt = source
                alt.url = backup
                do {
                    let value = try await body(alt)
                    var reordered = source.backupURLs
                    reordered.remove(at: index)
                    reordered.insert(source.url, at: 0)
                    let promoted = reordered
                    let newURL = backup
                    try? await db.updateSyncStatus(sourceId: source.id) { s in
                        s.url = newURL
                        s.backupURLs = promoted
                    }
                    alt.backupURLs = promoted
                    return (alt, value)
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    /// Returns discovered EPG URLs.
    private func syncLive(_ source: Source) async throws -> [String] {
        switch source.kind {
        case .m3u:
            let data = try await loadPlaylistData(source)
            let playlist = M3UParser.parse(data, sourceId: source.id)
            guard !playlist.channels.isEmpty || !playlist.movies.isEmpty || !playlist.episodes.isEmpty else {
                throw HTTPError.authFailed("The playlist has no channels")
            }
            try await db.replaceLive(sourceId: source.id, categories: source.includeLive ? playlist.categories : [], channels: source.includeLive ? playlist.channels : [])
            if source.includeVOD {
                try await db.replaceVOD(sourceId: source.id, movieCategories: playlist.movieCategories, movies: playlist.movies,
                                        seriesCategories: playlist.seriesCategories, series: playlist.series)
                // M3U series come with their episodes inline.
                let grouped = Dictionary(grouping: playlist.episodes, by: \.seriesId)
                for (seriesId, episodes) in grouped { try await db.replaceEpisodes(seriesId: seriesId, episodes: episodes) }
            }
            let channelCount = playlist.channels.count
            let movieCount = playlist.movies.count
            let seriesCount = playlist.series.count
            try await db.updateSyncStatus(sourceId: source.id) { s in
                s.channelCount = channelCount
                s.movieCount = movieCount
                s.seriesCount = seriesCount
            }
            return playlist.epgURLs

        case .xtream:
            let client = XtreamClient(source: source)
            let account = try await client.authenticate()
            var channelCount = 0
            if source.includeLive {
                async let cats = client.liveCategories(sourceId: source.id)
                async let streams = client.liveStreams(sourceId: source.id)
                let (c, s) = try await (cats, streams)
                try await db.replaceLive(sourceId: source.id, categories: c, channels: s)
                channelCount = s.count
            }
            let count = channelCount
            try await db.updateSyncStatus(sourceId: source.id) { s in
                s.channelCount = count
                s.expiresAt = account.expiresAt
                s.activeConnections = account.activeConnections
                s.maxConnections = account.maxConnections
            }
            return account.epgURLCandidates

        case .stalker:
            let client = stalkerClient(for: source)
            var channelCount = 0
            if source.includeLive {
                let cats = try await client.liveCategories(sourceId: source.id)
                let channels = try await client.channels(sourceId: source.id)
                try await db.replaceLive(sourceId: source.id, categories: cats, channels: channels)
                channelCount = channels.count
            }
            let expiry = await client.expiryDate()
            let count = channelCount
            try await db.updateSyncStatus(sourceId: source.id) { s in
                s.channelCount = count
                if let expiry { s.expiresAt = expiry }
            }
            return []
        }
    }

    private func syncVOD(_ source: Source) async throws {
        switch source.kind {
        case .m3u:
            return
        case .xtream:
            // Movies and series are fetched and stored independently: one failing doesn't discard the other.
            // Each pair runs concurrently (categories + items) but the two big downloads run one after the other,
            // which is gentler on panels that limit concurrent API calls.
            let client = XtreamClient(source: source)
            var failures: [String] = []
            do {
                async let cats = client.vodCategories(sourceId: source.id)
                async let items = client.vodStreams(sourceId: source.id)
                let (c, m) = try await (cats, items)
                try await db.replaceMovies(sourceId: source.id, categories: c, movies: m)
                try await db.updateSyncStatus(sourceId: source.id) { $0.movieCount = m.count }
            } catch {
                failures.append("movies — \(error.localizedDescription)")
            }
            do {
                async let cats = client.seriesCategories(sourceId: source.id)
                async let items = client.series(sourceId: source.id)
                let (c, s) = try await (cats, items)
                try await db.replaceSeries(sourceId: source.id, categories: c, series: s)
                try await db.updateSyncStatus(sourceId: source.id) { $0.seriesCount = s.count }
            } catch {
                failures.append("series — \(error.localizedDescription)")
            }
            if !failures.isEmpty { throw HTTPError.authFailed(failures.joined(separator: "; ")) }
        case .stalker:
            // Portals page items 14 at a time; only categories are synced, items load when opened.
            let client = stalkerClient(for: source)
            let movieCats = (try? await client.vodCategories(sourceId: source.id, kind: .movie)) ?? []
            let seriesCats = (try? await client.vodCategories(sourceId: source.id, kind: .series)) ?? []
            try await db.replaceVOD(sourceId: source.id, movieCategories: movieCats, movies: [], seriesCategories: seriesCats, series: [])
            loadedStalkerCategories = loadedStalkerCategories.filter { !$0.key.hasPrefix(source.id) }
        }
    }

    func loadPlaylistData(_ source: Source) async throws -> Data {
        let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let file: URL
        if url.hasPrefix("file://") || url.hasPrefix("/") {
            file = url.hasPrefix("file://") ? URL(string: url)! : URL(fileURLWithPath: url)
            let data = try Data(contentsOf: file)
            return Gzip.isGzipped(data) ? try Gzip.decompress(data) : data
        }
        let downloaded = try await HTTPClient(userAgent: source.userAgent, timeout: 120).download(from: url)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let data = try Data(contentsOf: downloaded)
        return Gzip.isGzipped(data) ? try Gzip.decompress(data) : data
    }

    // MARK: - Scheduled refresh

    /// Syncs sources whose data is older than their refresh interval (0 = manual only).
    public func syncDueSources(defaultLiveHours: Int, defaultVODHours: Int, now: Date = Date()) async {
        guard let sources = try? await db.sources() else { return }
        for source in sources where source.enabled {
            var options: SyncOptions = []
            let liveHours = source.refreshHours ?? defaultLiveHours
            if liveHours > 0, (source.lastSyncedAt.map { now.timeIntervalSince($0) > Double(liveHours) * 3600 } ?? true) {
                options.formUnion([.live, .guide])
            }
            if source.kind != .m3u, source.includeVOD, defaultVODHours > 0,
               source.lastVODSyncedAt.map({ now.timeIntervalSince($0) > Double(defaultVODHours) * 3600 }) ?? true {
                options.insert(.vod)
            }
            if !options.isEmpty { await sync(sourceId: source.id, options: options) }
        }
        if (try? await db.epgFeeds())?.contains(where: { $0.sourceId == nil && ($0.lastFetchedAt.map { now.timeIntervalSince($0) > Double(max(defaultLiveHours, 1)) * 3600 } ?? true) }) == true {
            _ = await guide.refreshGlobalFeeds()
        }
    }

    // MARK: - Lazy VOD details

    public func movieDetails(_ movie: Movie) async throws -> VODDetails {
        guard let source = try await db.source(id: movie.sourceId) else { return VODDetails() }
        guard source.kind == .xtream else { return VODDetails() }
        let details = try await XtreamClient(source: source).vodInfo(movie: movie)
        try await db.updateMovieDetails(id: movie.id, details)
        return details
    }

    /// Fetches (and stores) a series' episodes; returns what is in the database if the fetch fails.
    public func episodes(for series: Series) async throws -> [Episode] {
        guard let source = try await db.source(id: series.sourceId) else { return [] }
        do {
            switch source.kind {
            case .xtream:
                let details = try await XtreamClient(source: source).seriesInfo(series: series)
                try await db.updateSeriesDetails(id: series.id, details)
                try await db.replaceEpisodes(seriesId: series.id, episodes: details.episodes)
            case .stalker:
                let eps = try await stalkerClient(for: source).episodes(series: series)
                try await db.replaceEpisodes(seriesId: series.id, episodes: eps)
            case .m3u:
                break
            }
        } catch {
            let cached = try await db.episodes(seriesId: series.id)
            if cached.isEmpty { throw error }
            return cached
        }
        return try await db.episodes(seriesId: series.id)
    }

    /// Stalker: loads a VOD category's items on first open (cached for 30 minutes).
    public func loadCategoryIfNeeded(_ category: Category) async throws {
        guard let source = try await db.source(id: category.sourceId), source.kind == .stalker else { return }
        if let at = loadedStalkerCategories[category.id], Date().timeIntervalSince(at) < 1800 { return }
        let prefix = "\(source.id)_\(category.kind == .series ? "series" : "vod")_"
        let raw = category.id.hasPrefix(prefix) ? String(category.id.dropFirst(prefix.count)) : category.id
        let (movies, series) = try await stalkerClient(for: source).items(sourceId: source.id, kind: category.kind, categoryRawId: raw)
        try await db.replaceVODCategoryItems(categoryId: category.id, movies: category.kind == .movie ? movies : [], series: series)
        loadedStalkerCategories[category.id] = Date()
    }

    /// Validates credentials without writing anything (used by the source editor's Test button).
    public func test(_ source: Source) async throws -> String {
        switch source.kind {
        case .m3u:
            let data = try await loadPlaylistData(source)
            let p = M3UParser.parse(data, sourceId: "test")
            return "\(p.channels.count) channels, \(p.movies.count) movies, \(p.series.count) series" + (p.epgURLs.isEmpty ? "" : " · guide URL found")
        case .xtream:
            let account = try await XtreamClient(source: source).authenticate()
            var parts = ["Login OK"]
            if let exp = account.expiresAt { parts.append("expires \(exp.formatted(date: .abbreviated, time: .omitted))") }
            if let max = account.maxConnections { parts.append("\(account.activeConnections ?? 0)/\(max) connections") }
            return parts.joined(separator: " · ")
        case .stalker:
            let client = StalkerClient(source: source)
            let cats = try await client.liveCategories(sourceId: "test")
            return "Portal OK · \(cats.count) genres"
        }
    }
}
