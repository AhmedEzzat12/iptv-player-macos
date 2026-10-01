import Foundation
import os

/// Online metadata for movies and series (posters, backdrops, title logos, plot, cast, ratings, trailers,
/// episode stills). Cinemeta needs no key; TMDB is used when the user provides a key. Results (including
/// "not found") are cached in SQLite.
///
/// - Cache: matches are fresh for 30 days, "not found" for 7. A fresh entry is returned without network.
///   When online lookups are disabled, whatever is cached (even stale) is returned and nothing is fetched.
/// - Order: TMDB (if a key is set; the provider's `tmdbId` is used directly when present) → Cinemeta.
///   TMDB auth errors fall back to Cinemeta silently; network/server errors are never cached as "not found"
///   (the stale entry, if any, is returned and the item isn't retried for two minutes).
/// - Concurrency: concurrent requests for the same id share one lookup; at most three lookups hit the
///   network at once, newest request first (so the page the user just opened wins over older prefetches).
public actor MetadataService {
    let db: AppDatabase
    public private(set) var settings = MetadataSettings()

    static let log = Logger(subsystem: "app.tuner.macos", category: "Metadata")
    static let maxConcurrentLookups = 3
    /// After a failed lookup (offline, server error), the same item isn't retried for this long.
    static let failureBackoff: TimeInterval = 120

    let fetch: MetadataFetch
    private var configured = false
    /// Rows fetched before this are treated as stale (set when the TMDB key or language changes).
    private var staleBefore = Date.distantPast
    private var inFlight: [String: Task<MediaMetadata?, Never>] = [:]
    private var recentFailures: [String: Date] = [:]
    private var runningLookups = 0
    private var waitingLookups: [CheckedContinuation<Void, Never>] = []

    public init(db: AppDatabase) {
        self.init(db: db, fetch: MetadataHTTP.live())
    }

    /// Test seam: serve responses without the network.
    init(db: AppDatabase, fetch: @escaping MetadataFetch) {
        self.db = db
        self.fetch = fetch
    }

    /// Applies settings. Changing the TMDB key (or its language) marks the whole cache stale so items are
    /// refetched from the new provider when next opened; cached values stay visible meanwhile.
    public func configure(_ settings: MetadataSettings) {
        let old = self.settings
        self.settings = settings
        defer { configured = true }
        guard configured else { return }
        let oldKey = old.tmdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let newKey = settings.tmdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if oldKey != newKey || (newKey != nil && old.language != settings.language) {
            staleBefore = Date()
            recentFailures.removeAll()
            let db = self.db
            Task { try? await db.markMetadataStale() }
        } else if settings.enabled && !old.enabled {
            recentFailures.removeAll()
        }
    }

    /// Cached result, else an online lookup (when enabled). nil when nothing matched.
    public func metadata(for movie: Movie) async -> MediaMetadata? {
        await resolve(LookupRequest(mediaId: movie.id, kind: .movie, name: movie.name,
                                    year: movie.year ?? movie.releaseDate, tmdbId: movie.tmdbId))
    }

    /// Cached result, else an online lookup (when enabled). Includes `episodes` when available.
    public func metadata(for series: Series) async -> MediaMetadata? {
        await resolve(LookupRequest(mediaId: series.id, kind: .series, name: series.name,
                                    year: series.year ?? series.releaseDate, tmdbId: nil))
    }

    /// Cache only — never touches the network (for grids and shelves). Returns stale matches too.
    public func cachedMetadata(mediaId: String) async -> MediaMetadata? {
        ((try? await db.metadataCacheEntry(mediaId: mediaId)) ?? nil)?.metadata
    }

    /// Cache only, many ids in one query (grids and shelves). Ids without a cached match are absent.
    public func cachedMetadata(mediaIds: [String]) async -> [String: MediaMetadata] {
        (try? await db.cachedMetadata(mediaIds: mediaIds)) ?? [:]
    }

    /// Removes all cached metadata (positive and negative results).
    public func clearCache() async {
        recentFailures.removeAll()
        do {
            try await db.clearMetadataCache()
        } catch {
            Self.log.error("Clearing the metadata cache failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Validates a TMDB key/token; returns a user-facing error message, or nil when valid.
    public func validateTMDBKey(_ key: String) async -> String? {
        guard let client = TMDBClient(key: key, language: settings.language, fetch: fetch) else {
            return "Enter a TMDB API key or API read access token."
        }
        do {
            try await client.validate()
            return nil
        } catch HTTPError.status(let code, _) where code == 401 || code == 403 {
            return "TMDB rejected the key (\(code)). Paste the API Key or the API Read Access Token from themoviedb.org → Settings → API."
        } catch HTTPError.status(let code, _) {
            return "TMDB returned an error (\(code)). Try again later."
        } catch {
            return "Couldn't reach TMDB: \(error.localizedDescription)"
        }
    }

    // MARK: - Lookup pipeline

    private func resolve(_ request: LookupRequest) async -> MediaMetadata? {
        if let running = inFlight[request.mediaId] { return await running.value }
        let entry = (try? await db.metadataCacheEntry(mediaId: request.mediaId)) ?? nil
        if let entry, isFresh(entry) { return entry.metadata }
        guard settings.enabled else { return entry?.metadata }
        if let failedAt = recentFailures[request.mediaId], Date().timeIntervalSince(failedAt) < Self.failureBackoff {
            return entry?.metadata
        }
        // The cache read suspended: another caller may have started this lookup meanwhile.
        if let running = inFlight[request.mediaId] { return await running.value }
        let settings = self.settings
        let task = Task { await self.lookup(request, settings: settings, cached: entry) }
        inFlight[request.mediaId] = task
        return await task.value
    }

    private func isFresh(_ entry: MetadataCacheEntry) -> Bool {
        entry.fetchedAt >= staleBefore && entry.isFresh()
    }

    private func lookup(_ request: LookupRequest, settings: MetadataSettings, cached: MetadataCacheEntry?) async -> MediaMetadata? {
        defer { inFlight[request.mediaId] = nil }
        await acquireLookupSlot()
        defer { releaseLookupSlot() }

        // A duplicate lookup that started just as another finished: the cache now has the answer.
        if let entry = (try? await db.metadataCacheEntry(mediaId: request.mediaId)) ?? nil, isFresh(entry) {
            return entry.metadata
        }

        let started = Date()
        let outcome = await MetadataProviders(fetch: fetch).lookup(request, settings: settings, fetchedAt: started)
        switch outcome {
        case .found(let metadata):
            recentFailures[request.mediaId] = nil
            do {
                try await db.saveMetadata(metadata, mediaId: request.mediaId)
            } catch {
                Self.log.error("Saving metadata failed: \(error.localizedDescription, privacy: .public)")
            }
            return metadata
        case .notFound:
            recentFailures[request.mediaId] = nil
            // A refresh that finds nothing keeps an earlier match (more likely a catalogue hiccup than a fix).
            if let previous = cached?.metadata {
                try? await db.touchMetadata(mediaId: request.mediaId, at: started)
                return previous
            }
            try? await db.saveMetadataNotFound(mediaId: request.mediaId, kind: request.kind, at: started)
            return nil
        case .failed:
            recentFailures[request.mediaId] = Date()
            return cached?.metadata
        }
    }

    /// Counting semaphore with LIFO hand-off: the most recent request runs next.
    private func acquireLookupSlot() async {
        if runningLookups < Self.maxConcurrentLookups {
            runningLookups += 1
            return
        }
        await withCheckedContinuation { waitingLookups.append($0) }
    }

    private func releaseLookupSlot() {
        if let next = waitingLookups.popLast() {
            next.resume() // the slot passes straight to the waiter
        } else {
            runningLookups -= 1
        }
    }
}

/// What to look up: the provider item's id (cache key), kind, raw name, year and optional TMDB id.
struct LookupRequest: Sendable {
    var mediaId: String
    var kind: MediaMetadata.Kind
    var name: String
    var year: String?
    var tmdbId: String?
}

/// Provider fallback chain, run off the service actor.
struct MetadataProviders: Sendable {
    enum Outcome: Sendable {
        case found(MediaMetadata)
        /// Every provider answered and nothing matched well enough (cacheable).
        case notFound
        /// A provider couldn't be reached or errored (not cacheable).
        case failed
    }

    let fetch: MetadataFetch

    func lookup(_ request: LookupRequest, settings: MetadataSettings, fetchedAt: Date = Date()) async -> Outcome {
        guard let query = TitleMatcher.query(name: request.name, year: request.year, kind: request.kind) else {
            return .notFound
        }
        var transientFailure = false
        if let tmdb = TMDBClient(key: settings.tmdbAPIKey, language: settings.language, fetch: fetch) {
            do {
                if var metadata = try await tmdb.lookup(query, kind: request.kind, tmdbId: request.tmdbId) {
                    metadata.fetchedAt = fetchedAt
                    return .found(await withEpisodeFallbacks(metadata))
                }
            } catch {
                // Rejected keys fall back quietly; other errors make a Cinemeta miss inconclusive.
                if !MetadataHTTP.isAuthError(error) { transientFailure = true }
                MetadataService.log.error("TMDB lookup for '\(query.title, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            if var metadata = try await CinemetaClient(fetch: fetch).lookup(query, kind: request.kind) {
                metadata.fetchedAt = fetchedAt
                return .found(await withEpisodeFallbacks(metadata))
            }
            MetadataService.log.info("No match for '\(request.name, privacy: .public)' → '\(query.title, privacy: .public)' (\(query.year.map(String.init) ?? "-", privacy: .public))")
            return transientFailure ? .failed : .notFound
        } catch {
            MetadataService.log.error("Cinemeta lookup for '\(query.title, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// Series: adds TVmaze episode pictures as fallbacks for stills that don't exist. Best effort — a TVmaze
    /// failure never loses the match.
    func withEpisodeFallbacks(_ metadata: MediaMetadata) async -> MediaMetadata {
        guard metadata.kind == .series, !metadata.episodes.isEmpty, let imdbId = metadata.imdbId else { return metadata }
        do {
            let tvmaze = try await TVmazeClient(fetch: fetch).episodes(imdbId: imdbId)
            var enriched = metadata
            enriched.episodes = TVmazeClient.addFallbackStills(to: metadata.episodes, from: tvmaze)
            return enriched
        } catch {
            MetadataService.log.error("TVmaze episode pictures for \(imdbId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return metadata
        }
    }
}
