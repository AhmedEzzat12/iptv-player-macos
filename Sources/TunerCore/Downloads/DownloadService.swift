import Foundation
import os

/// A movie or episode saved to disk for offline viewing (one row per media id in the `download` table).
public struct DownloadItem: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case movie
        case episode
    }

    public enum State: String, Codable, Sendable {
        /// Waiting for its turn (downloads run one at a time: many accounts allow a single connection).
        case queued
        case downloading
        /// Paused by the user, or automatically while something streams from the same account.
        case paused
        case completed
        case failed
    }

    /// The movie's or episode's id (`Movie.id` / `Episode.id`), so progress, favourites etc. carry over.
    public var id: String
    public var kind: Kind
    public var sourceId: String
    /// The show, for episodes.
    public var seriesId: String?
    /// Movie name, or the show's name for episodes.
    public var title: String
    /// "S1, E3 · Title" for episodes; year/extra for movies.
    public var subtitle: String?
    public var season: Int?
    public var episode: Int?
    public var artworkURL: String?
    public var state: State
    public var receivedBytes: Int64
    /// Size reported by the server, when known.
    public var totalBytes: Int64?
    /// The saved file once completed (absolute path). Set as soon as the transfer starts, because that is where the
    /// data goes (as `<filePath>.part` until it's complete), but the file only exists there when `state == .completed`.
    public var filePath: String?
    /// User-facing reason when `state == .failed`. Also set on a `queued` download that waits to retry after a network
    /// problem ("The connection to your provider was lost…"); cleared when it starts again.
    public var error: String?
    /// True when the user paused it (an automatic pause, e.g. while streaming, resumes on its own).
    public var pausedByUser: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, kind: Kind, sourceId: String, seriesId: String? = nil, title: String, subtitle: String? = nil,
                season: Int? = nil, episode: Int? = nil, artworkURL: String? = nil, state: State = .queued,
                receivedBytes: Int64 = 0, totalBytes: Int64? = nil, filePath: String? = nil, error: String? = nil,
                pausedByUser: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.sourceId = sourceId
        self.seriesId = seriesId
        self.title = title
        self.subtitle = subtitle
        self.season = season
        self.episode = episode
        self.artworkURL = artworkURL
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.filePath = filePath
        self.error = error
        self.pausedByUser = pausedByUser
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 0…1 when the size is known.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

/// Downloads movies and episodes for offline viewing: a persistent queue (SQLite `download` table) that runs one
/// download at a time, resumes after pauses and app restarts when the server allows, and saves files under
/// `directory`. Completed downloads are what `StreamResolver` plays instead of streaming.
///
/// - Queue: one transfer at a time, first in first out (`createdAt`). Stream URLs are never stored (Xtream URLs carry
///   the password): each transfer resolves its URL through `StreamResolver` when it starts.
/// - Transfer: URLSession with the stream's User-Agent/Referer, redirects followed (VOD URLs 302 to a CDN). Data goes
///   to `<file>.part`, renamed into place when complete. A `.part` is resumed with `Range: bytes=<size>-` (206);
///   a 200 restarts from 0; a 416 either means the part is already complete (`*/<size>` matches) or starts over.
///   Free space is checked against Content-Length plus `freeSpaceMargin` before writing. Progress reaches the database
///   about once a second or every 1%.
/// - Failures: HTTP statuses become messages about what the provider did (a 503 means it lists the title but has no
///   playable copy: persistent, so no "try later"). Network loss, and "too many connections" statuses, re-queue the
///   download with exponential backoff instead of failing it.
/// - `suspend()` frees the connection while the app streams from a one-connection account; `unsuspend()` resumes.
public actor DownloadService {
    public private(set) var directory: URL

    static let log = Logger(subsystem: "app.tuner.macos", category: "Downloads")

    let db: AppDatabase
    let resolver: StreamResolver
    private let configuration: URLSessionConfiguration
    private let freeSpace: @Sendable (URL) -> Int64?
    private let freeSpaceMargin: Int64
    private let backoff: @Sendable (_ attempt: Int) -> Duration

    /// What a running transfer was stopped for, in increasing precedence.
    private enum Stop: Int, Comparable {
        case suspend, pause, remove
        static func < (a: Stop, b: Stop) -> Bool { a.rawValue < b.rawValue }
    }

    private struct Running {
        let id: String
        let task: Task<Void, Never>
        var stop: Stop?
    }

    private struct Retry {
        var attempt: Int
        var notBefore: ContinuousClock.Instant
    }

    /// Movies/episodes handed to `enqueue`, used if the library no longer has the row when the transfer starts.
    private enum Media {
        case movie(Movie)
        case episode(Episode)
    }

    private var recovered = false
    private var suspended = false
    private var pump: Task<Void, Never>?
    private var pumpAgain = false
    private var current: Running?
    private var retries: [String: Retry] = [:]
    private var wakeUp: Task<Void, Never>?
    private var media: [String: Media] = [:]

    public init(db: AppDatabase, resolver: StreamResolver, directory: URL) {
        self.init(db: db, resolver: resolver, directory: directory, configuration: Self.sessionConfiguration(),
                  freeSpace: { DownloadFiles.availableCapacity(at: $0) }, freeSpaceMargin: 500_000_000,
                  backoff: Self.defaultBackoff)
    }

    /// Test seam: the URLSession configuration (e.g. with a stub `URLProtocol`), the free-space probe and the margin
    /// kept free besides the file, and the delay before retry number `attempt` (1, 2, …) after a network problem.
    init(db: AppDatabase, resolver: StreamResolver, directory: URL, configuration: URLSessionConfiguration,
         freeSpace: @escaping @Sendable (URL) -> Int64?, freeSpaceMargin: Int64,
         backoff: @escaping @Sendable (_ attempt: Int) -> Duration) {
        self.db = db
        self.resolver = resolver
        self.directory = directory
        self.configuration = configuration
        self.freeSpace = freeSpace
        self.freeSpaceMargin = freeSpaceMargin
        self.backoff = backoff
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A stalled connection (no bytes for a minute) fails and is retried; the whole file may take hours.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 86_400
        config.httpMaximumConnectionsPerHost = 1
        return config
    }

    /// 5 s, 10 s, 20 s … capped at 5 minutes.
    static let defaultBackoff: @Sendable (Int) -> Duration = { attempt in
        .seconds(min(300, 5 << min(max(attempt - 1, 0), 6)))
    }

    /// Changes the folder for new downloads (existing files stay where they are).
    public func setDirectory(_ directory: URL) {
        self.directory = directory
    }

    /// Resumes the queue after launch (call once). Interrupted downloads continue where possible.
    public func start() async {
        if !recovered {
            recovered = true
            do {
                let requeued = try await db.requeueInterruptedDownloads(except: current?.id)
                if requeued > 0 { Self.log.info("Start: \(requeued, privacy: .public) interrupted download(s) queued again") }
                let missing = try await db.flagMissingDownloadFiles()
                if missing > 0 { Self.log.notice("Start: \(missing, privacy: .public) downloaded file(s) were moved or deleted") }
            } catch {
                Self.log.error("Start: couldn't restore the queue (\(Self.describe(error), privacy: .public))")
            }
        }
        kick()
    }

    /// Every download, newest first.
    public func items() async -> [DownloadItem] {
        (try? await db.downloads()) ?? []
    }

    /// The download for a movie/episode id, if any.
    public func item(id: String) async -> DownloadItem? {
        (try? await db.download(id: id)) ?? nil
    }

    /// Saved file for a movie/episode id when its download is complete (and the file still exists).
    public func localFile(mediaId: String) async -> URL? {
        await db.completedDownloadFile(mediaId: mediaId)
    }

    /// Queues a movie (no-op if already queued or downloaded).
    public func enqueue(movie: Movie) async throws {
        media[movie.id] = .movie(movie)
        let item = DownloadItem(id: movie.id, kind: .movie, sourceId: movie.sourceId, title: movie.name,
                                subtitle: DownloadFiles.year(movie.year, movie.releaseDate),
                                artworkURL: movie.posterURL ?? movie.backdropURL)
        await queued(try await db.enqueueDownloads([item]))
    }

    /// Queues episodes of a show in watch order (already queued/downloaded ones are skipped).
    public func enqueue(episodes: [Episode], of series: Series) async throws {
        var seen = Set<String>()
        let ordered = episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }.filter { seen.insert($0.id).inserted }
        let items = ordered.map { episode in
            media[episode.id] = .episode(episode)
            let title = DownloadFiles.episodeTitle(episode.title, season: episode.season, number: episode.number)
            return DownloadItem(id: episode.id, kind: .episode, sourceId: episode.sourceId, seriesId: series.id, title: series.name,
                                subtitle: "S\(episode.season), E\(episode.number)" + (title.map { " · \($0)" } ?? ""),
                                season: episode.season, episode: episode.number,
                                artworkURL: episode.imageURL ?? series.coverURL ?? series.backdropURL)
        }
        await queued(try await db.enqueueDownloads(items))
    }

    private func queued(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        for id in ids { retries[id] = nil }
        Self.log.info("Queued \(ids.count, privacy: .public): \(ids.joined(separator: ", "), privacy: .public)")
        kick()
    }

    public func pause(id: String) async {
        retries[id] = nil
        let paused = try? await db.updateDownload(id: id) { item in
            guard [.queued, .downloading, .paused].contains(item.state) else { return false }
            item.state = .paused
            item.pausedByUser = true
            return true
        }
        if paused != nil { Self.log.info("Paused \(id, privacy: .public)") }
        await stop(id, because: .pause)
    }

    /// Continues a paused download, retries a failed one, or retries a queued one now instead of after its backoff.
    public func resume(id: String) async {
        retries[id] = nil
        let resumed = try? await db.updateDownload(id: id) { item in
            if item.restoreIfFileReturned() { return true }
            if item.isMissingFile {
                // Its file is gone: download it again from the start, under a fresh name.
                item.filePath = nil
                item.receivedBytes = 0
                item.totalBytes = nil
            }
            switch item.state {
            case .paused, .failed:
                item.state = .queued
                item.pausedByUser = false
                item.error = nil
                return true
            case .queued:
                item.error = nil
                return true
            case .downloading, .completed:
                return false
            }
        }
        if resumed != nil { Self.log.info("Resumed \(id, privacy: .public)") }
        kick()
    }

    /// Stops and removes a download that isn't finished (partial data is deleted).
    public func cancel(id: String) async {
        guard let item = await item(id: id) else { return }
        guard item.state != .completed else {
            Self.log.info("Cancel ignored for completed \(id, privacy: .public) (use delete)")
            return
        }
        await discard(id)
        Self.log.info("Cancelled \(id, privacy: .public)")
    }

    /// Deletes a download and its file.
    public func delete(id: String) async {
        await discard(id)
        Self.log.info("Deleted \(id, privacy: .public)")
    }

    /// Pauses running downloads without marking them user-paused (e.g. while streaming on a 1-connection account).
    /// Returns once the connection is closed. Queued downloads wait until `unsuspend()`.
    public func suspend() async {
        suspended = true
        wakeUp?.cancel()
        wakeUp = nil
        guard let running = current else { return }
        current?.stop = max(running.stop ?? .suspend, .suspend)
        running.task.cancel()
        _ = try? await db.updateDownload(id: running.id) { item in
            guard item.state == .downloading else { return false }
            item.state = .paused
            item.pausedByUser = false
            return true
        }
        await running.task.value
        Self.log.info("Suspended (\(running.id, privacy: .public) paused)")
    }

    /// Undoes `suspend()`.
    public func unsuspend() async {
        suspended = false
        let requeued = (try? await db.requeueAutoPausedDownloads()) ?? 0
        Self.log.info("Unsuspended (\(requeued, privacy: .public) resumed)")
        kick()
    }

    // MARK: - Queue

    /// Starts the queue runner, or asks the running one to look again when it's done.
    private func kick() {
        if pump != nil {
            pumpAgain = true
            return
        }
        pump = Task { await self.drain() }
    }

    /// Runs due downloads one at a time until none is left (or the service is suspended).
    private func drain() async {
        repeat {
            pumpAgain = false
            while !suspended, let next = await nextDue() {
                // `current` is set before the next suspension point, so pause/cancel always find the transfer.
                guard !suspended else { break }
                let id = next.id
                let task = Task { await self.perform(id) }
                current = Running(id: id, task: task)
                await task.value
                current = nil
            }
        } while pumpAgain && !suspended
        pump = nil
        scheduleWakeUp()
    }

    /// The oldest queued download that isn't waiting out a retry backoff.
    private func nextDue() async -> DownloadItem? {
        guard let queued = try? await db.queuedDownloads() else { return nil }
        let now = ContinuousClock.now
        return queued.first { retries[$0.id].map { $0.notBefore <= now } ?? true }
    }

    /// Wakes the queue when the earliest retry backoff ends.
    private func scheduleWakeUp() {
        wakeUp?.cancel()
        wakeUp = nil
        let now = ContinuousClock.now
        guard !suspended, let due = retries.values.map(\.notBefore).filter({ $0 > now }).min() else { return }
        wakeUp = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.kick()
        }
    }

    /// Cancels the running transfer of `id` (if it is the one running) and waits until it has let go of the file and
    /// the connection.
    private func stop(_ id: String, because reason: Stop) async {
        guard let running = current, running.id == id else { return }
        current?.stop = max(running.stop ?? reason, reason)
        running.task.cancel()
        await running.task.value
    }

    /// Stops the download if it's running, then deletes the row, the file and any partial data (plus a deleted
    /// episode's now-empty folders).
    private func discard(_ id: String) async {
        retries[id] = nil
        media[id] = nil
        await stop(id, because: .remove)
        let item = (try? await db.takeDownload(id: id)) ?? nil
        // The queue may have started it while the row was read: without a row its transfer can't pick a file name,
        // and a transfer that already had one is in `item.filePath`, cleaned up below once it has stopped.
        await stop(id, because: .remove)
        guard let item, let path = item.filePath else { return }
        let fm = FileManager.default
        try? fm.removeItem(atPath: path + ".part")
        try? fm.removeItem(atPath: path)
        if item.kind == .episode {
            DownloadFiles.removeEmptyFolders(above: URL(fileURLWithPath: path), levels: 2)
        }
    }

    // MARK: - Transfer

    private enum Outcome {
        case completed(URL, size: Int64)
        /// Stopped on purpose (`Running.stop` says why). `received`: bytes in the `.part`, when known.
        case interrupted(received: Int64?)
        case failed(String, received: Int64?)
        /// A network problem: queued again after a backoff. `progressed`: data flowed before it happened.
        case retry(String, received: Int64?, progressed: Bool)
        /// No longer queued when its turn came.
        case skipped
    }

    private func perform(_ id: String) async {
        guard !Task.isCancelled else { return }
        let outcome: Outcome
        do {
            guard var item = try await db.claimDownload(id: id) else { return }
            Self.log.info("Starting \(id, privacy: .public) (\(item.receivedBytes, privacy: .public) bytes saved)")
            outcome = await transfer(&item)
        } catch {
            Self.log.error("Couldn't start \(id, privacy: .public): \(Self.describe(error), privacy: .public)")
            outcome = .retry("Couldn't start the download. Retrying…", received: nil, progressed: false)
        }
        await settle(id, outcome)
    }

    /// Writes the outcome of a transfer to the database.
    private func settle(_ id: String, _ outcome: Outcome) async {
        let stop = current?.id == id ? current?.stop : nil
        var outcome = outcome
        switch (outcome, stop) {
        case (.interrupted(let received), nil):
            // Cancelled without being asked to (shouldn't happen): queue it again, but not in a tight loop.
            outcome = .retry("The download was interrupted. It continues shortly.", received: received, progressed: false)
        case (.failed(_, let received), _?), (.retry(_, let received, _), _?):
            // Errors caused by stopping it on purpose (e.g. the cancelled connection) aren't failures.
            outcome = .interrupted(received: received)
        default:
            break
        }
        switch outcome {
        case .skipped:
            return
        case .completed(let file, let size):
            retries[id] = nil
            media[id] = nil
            _ = try? await db.updateDownload(id: id) { item in
                item.state = .completed
                item.filePath = file.path
                item.receivedBytes = size
                item.totalBytes = size
                item.error = nil
                item.pausedByUser = false
                return true
            }
            Self.log.info("Completed \(id, privacy: .public): \(size, privacy: .public) bytes")
        case .interrupted(let received):
            // Stopped on purpose. pause()/suspend() already wrote their state; this covers a transfer they stopped
            // between being claimed and that write, so nothing is left "downloading" with no transfer.
            _ = try? await db.updateDownload(id: id) { item in
                if let received { item.receivedBytes = received }
                if item.state == .downloading {
                    switch stop {
                    case .pause?: item.state = .paused; item.pausedByUser = true
                    case .suspend?: item.state = .paused; item.pausedByUser = false
                    case .remove?: break
                    case nil: item.state = .queued
                    }
                }
                return true
            }
            Self.log.info("Stopped \(id, privacy: .public) at \(received ?? -1, privacy: .public) bytes")
        case .failed(let message, let received):
            retries[id] = nil
            _ = try? await db.updateDownload(id: id) { item in
                if let received { item.receivedBytes = received }
                if item.state == .downloading {
                    item.state = .failed
                    item.error = message
                }
                return true
            }
            Self.log.error("Failed \(id, privacy: .public): \(message, privacy: .public)")
        case .retry(let message, let received, let progressed):
            let attempt = progressed ? 1 : (retries[id]?.attempt ?? 0) + 1
            let delay = backoff(attempt)
            retries[id] = Retry(attempt: attempt, notBefore: .now + delay)
            _ = try? await db.updateDownload(id: id) { item in
                if let received { item.receivedBytes = received }
                if item.state == .downloading {
                    item.state = .queued
                    item.error = message
                }
                return true
            }
            Self.log.notice("Retrying \(id, privacy: .public) in \(String(describing: delay), privacy: .public) (attempt \(attempt, privacy: .public)): \(message, privacy: .public)")
        }
    }

    /// Resolves the stream and downloads it into `item.filePath` (chosen on the first response).
    private func transfer(_ item: inout DownloadItem) async -> Outcome {
        let id = item.id
        let stream: PlayableStream
        let naming: DownloadFiles.Naming
        let declaredExtension: String?
        do {
            (stream, naming, declaredExtension) = try await resolve(item)
        } catch {
            return Task.isCancelled ? .interrupted(received: nil) : Self.outcome(for: error, received: nil, progressed: false)
        }

        var offset = item.filePath.flatMap { DownloadFiles.size(of: URL(fileURLWithPath: $0 + ".part")) } ?? 0

        // A second pass starts over from the beginning when the saved part can't be resumed.
        for _ in 0..<2 {
            let request = Self.request(for: stream, offset: offset)
            let transfer = FileTransfer(request: request, configuration: configuration)
            transfer.start()
            let response: URLResponse
            do {
                response = try await withTaskCancellationHandler {
                    try await transfer.response()
                } onCancel: {
                    transfer.cancel()
                }
            } catch {
                return Task.isCancelled ? .interrupted(received: offset) : Self.outcome(for: error, received: offset, progressed: false)
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let range = ContentRange(response: response)
            Self.log.info("\(id, privacy: .public): HTTP \(status, privacy: .public), length \(response.expectedContentLength, privacy: .public), resuming at \(offset, privacy: .public)")

            var start: Int64 = 0 // where this body begins in the file
            var total: Int64? = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            switch status {
            case 200..<300 where status != 206:
                if offset > 0 { Self.log.notice("\(id, privacy: .public): server ignored the range; starting over") }
            case 206:
                start = range.start ?? offset
                total = range.total ?? total.map { start + $0 }
                // A gap between what we have and what was sent, or a file whose size changed on the server since the
                // part was saved (appending would corrupt it): start over.
                let changed = offset > 0 && item.totalBytes != nil && total != nil && item.totalBytes != total
                guard start <= offset, !changed else {
                    let savedTotal = item.totalBytes ?? -1, rangeStart = start, rangeTotal = total ?? -1, saved = offset
                    Self.log.notice("\(id, privacy: .public): range from \(rangeStart, privacy: .public) of \(rangeTotal, privacy: .public) doesn't continue the saved \(saved, privacy: .public) of \(savedTotal, privacy: .public); starting over")
                    await transfer.drop()
                    offset = Self.discardPart(of: item)
                    continue
                }
            case 416 where offset > 0:
                await transfer.drop()
                if let path = item.filePath, (range.total ?? item.totalBytes) == offset {
                    // The part is already complete (e.g. the app quit just before renaming it).
                    return Self.finish(part: URL(fileURLWithPath: path + ".part"), destination: URL(fileURLWithPath: path), size: offset)
                }
                Self.log.notice("\(id, privacy: .public): saved part (\(offset, privacy: .public) bytes) doesn't fit the file on the server; starting over")
                offset = Self.discardPart(of: item)
                continue
            default:
                await transfer.drop()
                return Self.outcome(forStatus: status, received: offset)
            }

            if let mime = response.mimeType?.lowercased(), mime == "text/html" || mime == "application/json" {
                await transfer.drop()
                return .failed("Your provider sent a web page instead of the video. The title may have been removed.", received: offset)
            }

            // The file's name is chosen once, on the first response (the server tells the real container), and kept so
            // the part can be resumed after a relaunch.
            if item.filePath == nil {
                let ext = DownloadFiles.fileExtension(declared: declaredExtension, response: response, requested: request.url)
                do {
                    item.filePath = try await reserveDestination(naming: naming, ext: ext, id: id).path
                } catch DownloadError.removed {
                    await transfer.drop()
                    return .skipped
                } catch {
                    await transfer.drop()
                    return .failed("Couldn't create the download folder (\(error.localizedDescription)).", received: nil)
                }
            }
            guard let path = item.filePath else { return .skipped }
            let destination = URL(fileURLWithPath: path)
            let part = URL(fileURLWithPath: path + ".part")
            let folder = destination.deletingLastPathComponent()

            let needed = total.map { max(0, $0 - start) } ?? 0
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let free = freeSpace(folder), free < needed + freeSpaceMargin {
                await transfer.drop()
                Self.log.error("\(id, privacy: .public): needs \(needed, privacy: .public) bytes + margin, \(free, privacy: .public) free")
                return .failed(Self.diskSpaceMessage(needed: needed, free: free), received: offset)
            }

            let handle: FileHandle
            do {
                if !FileManager.default.fileExists(atPath: part.path) {
                    FileManager.default.createFile(atPath: part.path, contents: nil)
                }
                handle = try FileHandle(forWritingTo: part)
                try handle.truncate(atOffset: UInt64(start))
                try handle.seekToEnd()
            } catch {
                await transfer.drop()
                return .failed("Couldn't save the file (\(error.localizedDescription)).", received: offset)
            }
            let knownTotal = total, bodyStart = start
            _ = try? await db.updateDownload(id: id) { row in
                row.receivedBytes = bodyStart
                if let knownTotal { row.totalBytes = knownTotal }
                return true
            }

            let progress = Task { await self.reportProgress(id: id, transfer: transfer, start: start, total: total) }
            let result = await withTaskCancellationHandler {
                await transfer.receive(into: handle)
            } onCancel: {
                transfer.cancel()
            }
            progress.cancel()
            await progress.value
            try? handle.synchronize()
            try? handle.close()
            let size = DownloadFiles.size(of: part) ?? (start + transfer.bytesReceived)
            let progressed = transfer.bytesReceived > 0

            switch result {
            case .failure(let error):
                if Task.isCancelled { return .interrupted(received: size) }
                return Self.outcome(for: error, received: size, progressed: progressed)
            case .success:
                if let total, size < total {
                    // The server closed the connection early: keep the part and continue from there.
                    return .retry(Self.connectionLostMessage, received: size, progressed: progressed)
                }
                return Self.finish(part: part, destination: destination, size: size)
            }
        }
        return .failed("Your provider couldn't send this file (HTTP 416).", received: 0)
    }

    /// The stream to download, how to name the file, and the provider's declared container.
    private func resolve(_ item: DownloadItem) async throws -> (PlayableStream, DownloadFiles.Naming, String?) {
        switch item.kind {
        case .movie:
            let saved: Movie? = if case .movie(let m)? = media[item.id] { m } else { nil }
            guard let movie = try await db.movie(id: item.id) ?? saved else { throw DownloadError.notInLibrary }
            let stream = try await resolver.movie(movie)
            return (stream, .movie(title: movie.name, year: DownloadFiles.year(movie.year, movie.releaseDate)), movie.containerExtension)
        case .episode:
            let saved: Episode? = if case .episode(let e)? = media[item.id] { e } else { nil }
            guard let episode = try await db.episode(id: item.id) ?? saved else { throw DownloadError.notInLibrary }
            let stream = try await resolver.episode(episode)
            let title = DownloadFiles.episodeTitle(episode.title, season: episode.season, number: episode.number)
            return (stream, .episode(show: item.title, season: episode.season, number: episode.number, title: title),
                    episode.containerExtension)
        }
    }

    /// Picks a free file name for a new download (not on disk, not used by another download) and records it.
    private func reserveDestination(naming: DownloadFiles.Naming, ext: String, id: String) async throws -> URL {
        let (folders, name) = naming.location
        let folder = folders.reduce(directory) { $0.appendingPathComponent($1, isDirectory: true) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fm = FileManager.default
        for n in 1...999 {
            let file = folder.appendingPathComponent((n == 1 ? name : "\(name) (\(n))") + ".\(ext)")
            if fm.fileExists(atPath: file.path) || fm.fileExists(atPath: file.path + ".part") { continue }
            if try await db.downloadPathInUse(file.path, except: id) { continue }
            let reserved = try await db.updateDownload(id: id) { item in
                item.filePath = file.path
                return true
            }
            guard reserved != nil else { throw DownloadError.removed }
            return file
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Writes progress about once a second, or every 1% of the file, while the body arrives.
    private func reportProgress(id: String, transfer: FileTransfer, start: Int64, total: Int64?) async {
        var written = start
        var writtenAt = ContinuousClock.now - .seconds(60)
        let step = total.map { max(1, $0 / 100) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let received = start + transfer.bytesReceived
            guard received > written else { continue }
            let now = ContinuousClock.now
            guard now - writtenAt >= .seconds(1) || step.map({ received - written >= $0 }) == true else { continue }
            try? await db.updateDownloadProgress(id: id, receivedBytes: received)
            written = received
            writtenAt = now
        }
    }

    /// Deletes an unusable `.part`; returns the new resume offset (0).
    private static func discardPart(of item: DownloadItem) -> Int64 {
        if let path = item.filePath { try? FileManager.default.removeItem(atPath: path + ".part") }
        return 0
    }

    private static func finish(part: URL, destination: URL, size: Int64) -> Outcome {
        do {
            return .completed(try DownloadFiles.moveIntoPlace(part, to: destination), size: size)
        } catch {
            return .failed("Couldn't save the file (\(error.localizedDescription)).", received: size)
        }
    }

    static func request(for stream: PlayableStream, offset: Int64) -> URLRequest {
        var request = URLRequest(url: stream.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        for (field, value) in stream.headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // Byte offsets must match the file on the server: no transparent compression.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        return request
    }

    // MARK: - Messages

    static let connectionLostMessage = "The connection to your provider was lost. The download continues shortly."

    /// What the provider's answer means, in words. Statuses that clear up on their own are retried.
    private static func outcome(forStatus status: Int, received: Int64?) -> Outcome {
        switch status {
        case 401:
            return .failed("Your provider didn't accept this account's username or password (HTTP 401).", received: received)
        case 403:
            return .failed("Your provider refused this download (HTTP 403). Your subscription may not include it, or another device is using your connection.", received: received)
        case 404, 410:
            return .failed("Your provider no longer has this title on its server (HTTP \(status)).", received: received)
        case 429, 458, 509:
            return .retry("Your provider says too many streams are open on this account (HTTP \(status)). The download tries again shortly.", received: received, progressed: false)
        // Panels answer 503 themselves when they list a title but have no playable copy (storage gone, file taken
        // down). Seen lasting for days, so don't promise "later".
        case 503:
            return .failed("Your provider lists this title but has no playable copy of it (HTTP 503). This is on their side and usually lasts until they upload it again.", received: received)
        case 500..<600:
            return .failed("Your provider's server couldn't send this title (HTTP \(status)). Try again later.", received: received)
        default:
            return .failed("Your provider refused this download (HTTP \(status)).", received: received)
        }
    }

    private static func outcome(for error: any Error, received: Int64?, progressed: Bool) -> Outcome {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .interrupted(received: received)
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                return .retry("No internet connection. The download continues when you're back online.", received: received, progressed: progressed)
            case .networkConnectionLost, .timedOut:
                return .retry(connectionLostMessage, received: received, progressed: progressed)
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .resourceUnavailable:
                return .retry("Can't reach your provider's server. The download tries again shortly.", received: received, progressed: progressed)
            default:
                return .failed("The download failed: \(urlError.localizedDescription)", received: received)
            }
        }
        if DownloadFiles.isOutOfSpace(error) {
            return .failed("The disk is full. Free up some space, then try again.", received: received)
        }
        if let described = (error as? any LocalizedError)?.errorDescription {
            return .failed(described, received: received)
        }
        return .failed("The download failed (\(describe(error))).", received: received)
    }

    static func diskSpaceMessage(needed: Int64, free: Int64) -> String {
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return needed > 0
            ? "Not enough disk space: this download needs \(format(needed)) and \(format(free)) is free."
            : "Not enough disk space: only \(format(free)) is free."
    }

    /// Domain and code only: an error's full description can include the request URL, which carries credentials.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}

enum DownloadError: LocalizedError {
    case notInLibrary
    /// The download was cancelled or deleted while its transfer was starting.
    case removed

    var errorDescription: String? {
        switch self {
        case .notInLibrary: "This title is no longer in your playlist."
        case .removed: "The download was removed."
        }
    }
}
