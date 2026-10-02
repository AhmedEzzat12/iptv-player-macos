import Foundation
import os

/// An episode's IMDb user rating.
public struct EpisodeRating: Sendable, Hashable, Codable {
    public var season: Int
    public var episode: Int
    /// 0–10, e.g. 8.6.
    public var rating: Double
    public var votes: Int

    public init(season: Int, episode: Int, rating: Double, votes: Int) {
        self.season = season
        self.episode = episode
        self.rating = rating
        self.votes = votes
    }
}

/// The IMDb dataset files the ratings come from.
enum IMDbDataset: String, Sendable, CaseIterable {
    case episodes = "title.episode.tsv.gz"
    case ratings = "title.ratings.tsv.gz"

    var fileName: String { rawValue }
    var url: URL { URL(string: "https://datasets.imdbws.com/\(rawValue)")! }
}

/// IMDb episode ratings for TV series, from IMDb's non-commercial datasets (personal use). Online catalogues
/// miss many episode ratings; the datasets have every rated episode.
///
/// - Datasets: `title.episode.tsv.gz` (~55 MB) and `title.ratings.tsv.gz` (~9 MB) are kept in `directory` and
///   refreshed when older than 7 days (IMDb regenerates them daily). Downloads land in a temporary file that is
///   atomically renamed into place; concurrent callers share one download per file. When a refresh fails, the
///   previous copy keeps being used (and the refresh isn't retried for an hour).
/// - Scans: a stream-inflating byte scan of both files (`IMDbDatasetScanner`) off the actor: ~0.5 s per pass in a
///   release build on Apple silicon (~3.5 s unoptimised). One pass runs at a time; series requested meanwhile are
///   batched into the next pass, and concurrent requests for the same series share one lookup.
/// - Cache: per-series results in SQLite (`imdbEpisodeRating` + `imdbRatingScan`, so "no rated episodes" is cached
///   too), fresh for 7 days. When the datasets are unavailable nothing is cached and the stale result (or []) is
///   returned.
public actor IMDbRatingsService {
    typealias Download = @Sendable (_ from: URL, _ to: URL) async throws -> Void

    static let log = Logger(subsystem: "app.tuner.macos", category: "IMDb")
    /// Dataset files and cached scans are refreshed after this long.
    static let maxAge: TimeInterval = 7 * 86_400
    /// After a failed refresh of a file we still have, it isn't retried for this long.
    static let failedRefreshBackoff: TimeInterval = 3600

    let db: AppDatabase
    let directory: URL
    private let download: Download
    private let now: @Sendable () -> Date

    private var inFlight: [String: Task<[EpisodeRating], Never>] = [:]
    private var downloads: [IMDbDataset: Task<URL?, Never>] = [:]
    private var failedRefreshes: [IMDbDataset: Date] = [:]
    /// Series waiting for the next scan, and the task that will run it once `runningScan` finishes.
    private var nextScan: (seriesIds: Set<String>, task: Task<[String: [EpisodeRating]]?, Never>)?
    private var runningScan: Task<[String: [EpisodeRating]]?, Never>?
    /// Dataset scans started (for tests).
    private(set) var scanCount = 0

    /// `directory`: where the dataset files are kept (the app passes <Application Support>/Tuner/IMDb).
    public init(db: AppDatabase, directory: URL) {
        self.init(db: db, directory: directory, download: Self.liveDownload, now: { Date() })
    }

    /// Test seam: inject a downloader (`from` remote URL → `to` local file) and a clock.
    init(db: AppDatabase, directory: URL, download: @escaping @Sendable (URL, URL) async throws -> Void,
         now: @escaping @Sendable () -> Date) {
        self.db = db
        self.directory = directory
        self.download = download
        self.now = now
    }

    /// Cached ratings only (DB). Never downloads or scans. [] when unknown.
    public func cachedRatings(seriesIMDbId: String) async -> [EpisodeRating] {
        guard let id = Self.normalizedId(seriesIMDbId) else { return [] }
        return (try? await db.imdbEpisodeRatings(seriesId: id)) ?? []
    }

    /// Ratings for a series by IMDb id ("tt…"): fresh cache (< 7 days) if any, else downloads/refreshes the datasets
    /// when needed, scans them for this series, caches the result (including "no rated episodes") and returns it.
    /// Never throws; returns [] when the datasets are unavailable.
    public func ratings(seriesIMDbId: String) async -> [EpisodeRating] {
        guard let id = Self.normalizedId(seriesIMDbId) else { return [] }
        if let running = inFlight[id] { return await running.value }
        let cached = (try? await db.imdbRatingsCacheEntry(seriesId: id)) ?? nil
        if let cached, now().timeIntervalSince(cached.scannedAt) < Self.maxAge { return cached.ratings }
        // The cache read suspended: another caller may have started this lookup meanwhile.
        if let running = inFlight[id] { return await running.value }
        let task = Task { await self.lookup(id, stale: cached?.ratings) }
        inFlight[id] = task
        return await task.value
    }

    /// "tt0903747" (any case, surrounding spaces) → "tt0903747"; nil for anything that isn't an IMDb title id.
    static func normalizedId(_ id: String) -> String? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return IMDbDatasetScanner.titleNumber(id) != nil ? id : nil
    }

    // MARK: - Lookup

    private func lookup(_ id: String, stale: [EpisodeRating]?) async -> [EpisodeRating] {
        defer { inFlight[id] = nil }
        guard let ratings = await scan(for: id) else { return stale ?? [] }
        return ratings
    }

    /// Scans the datasets for `id` together with any other series requested before the scan starts.
    /// nil when the datasets are unavailable or unreadable.
    private func scan(for id: String) async -> [EpisodeRating]? {
        let task: Task<[String: [EpisodeRating]]?, Never>
        if var next = nextScan {
            next.seriesIds.insert(id)
            nextScan = next
            task = next.task
        } else {
            let previous = runningScan
            task = Task {
                _ = await previous?.value
                return await self.runNextScan()
            }
            nextScan = ([id], task)
        }
        return await task.value?[id]
    }

    private func runNextScan() async -> [String: [EpisodeRating]]? {
        guard let scan = nextScan else { return nil }
        nextScan = nil
        runningScan = scan.task
        defer { if runningScan == scan.task { runningScan = nil } }

        async let episodesFile = dataset(.episodes)
        async let ratingsFile = dataset(.ratings)
        guard let episodesURL = await episodesFile, let ratingsURL = await ratingsFile else {
            Self.log.error("IMDb datasets are unavailable; no episode ratings")
            return nil
        }

        scanCount += 1
        let seriesIds = scan.seriesIds
        let started = ContinuousClock.now
        let outcome = await Task.detached(priority: Task.currentPriority) {
            Result { try IMDbDatasetScanner.scan(episodesFile: episodesURL, ratingsFile: ratingsURL, seriesIds: seriesIds) }
        }.value
        switch outcome {
        case .success(let results):
            let rated = results.values.reduce(0) { $0 + $1.count }
            Self.log.info("Scanned IMDb datasets for \(seriesIds.count) series: \(rated) rated episodes in \(Self.seconds(since: started), privacy: .public)")
            do {
                try await db.saveIMDbRatings(results, scannedAt: now())
            } catch {
                Self.log.error("Saving IMDb ratings failed: \(error.localizedDescription, privacy: .public)")
            }
            return results
        case .failure(let error):
            Self.log.error("Scanning IMDb datasets failed: \(error.localizedDescription, privacy: .public)")
            // A damaged copy is downloaded again next time.
            if let error = error as? IMDbDatasetScanner.FileError, error.reason != .unreadable {
                try? FileManager.default.removeItem(at: error.file)
            }
            return nil
        }
    }

    // MARK: - Dataset files

    /// The local copy of a dataset, downloaded or refreshed when needed; nil when there is none.
    private func dataset(_ dataset: IMDbDataset) async -> URL? {
        let file = directory.appendingPathComponent(dataset.fileName)
        let modified = Self.modificationDate(of: file)
        if let modified, now().timeIntervalSince(modified) < Self.maxAge { return file }
        if modified != nil, let failedAt = failedRefreshes[dataset],
           now().timeIntervalSince(failedAt) < Self.failedRefreshBackoff {
            return file
        }
        if let running = downloads[dataset] { return await running.value }
        let task = Task { await self.fetch(dataset, to: file) }
        downloads[dataset] = task
        return await task.value
    }

    /// Downloads a dataset next to `file` and renames it into place. Returns `file` when it now exists (fresh, or
    /// the previous copy after a failed refresh).
    private func fetch(_ dataset: IMDbDataset, to file: URL) async -> URL? {
        defer { downloads[dataset] = nil }
        let fm = FileManager.default
        let partial = directory.appendingPathComponent(dataset.fileName + ".download")
        let started = ContinuousClock.now
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: partial)
            try await download(dataset.url, partial)
            guard Gzip.isGzipped(fileAt: partial) else { throw IMDbDatasetError.notGzip }
            // The file's date is its age (refreshed after 7 days), on the service's clock.
            try fm.setAttributes([.modificationDate: now()], ofItemAtPath: partial.path)
            // rename(2) replaces the old copy atomically; a scan still reading it keeps its open file.
            guard rename(partial.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            failedRefreshes[dataset] = nil
            let size = ((try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0
            Self.log.info("Downloaded \(dataset.fileName, privacy: .public) (\(size / 1_000_000) MB) in \(Self.seconds(since: started), privacy: .public)")
            return file
        } catch {
            try? fm.removeItem(at: partial)
            let hasCopy = Self.modificationDate(of: file) != nil
            if hasCopy { failedRefreshes[dataset] = now() }
            Self.log.error("Downloading \(dataset.fileName, privacy: .public) failed\(hasCopy ? "; using the previous copy" : "", privacy: .public): \(error.localizedDescription, privacy: .public)")
            return hasCopy ? file : nil
        }
    }

    private static func modificationDate(of file: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? Int ?? 0) > 0
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(format: "%.2f s", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    /// Live downloader: an ephemeral URLSession download (nothing cached), moved to `destination`.
    static let liveDownload: Download = { url, destination in
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(MetadataHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.status(http.statusCode, url: url.absoluteString)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: config)
    }()
}
