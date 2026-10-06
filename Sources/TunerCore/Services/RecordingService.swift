import Foundation

/// DVR: records streams to disk with `ffmpeg -c copy` and runs scheduled recordings.
public actor RecordingService {
    let db: AppDatabase
    let resolver: StreamResolver
    #if os(macOS)
    private var processes: [String: Process] = [:]
    #else
    /// iOS/tvOS can't launch child processes, so nothing is ever recording there.
    private var processes: [String: Never] = [:]
    #endif
    private var stopRequested: Set<String> = []

    public var directory: URL
    public var startPadding: TimeInterval = 60
    public var endPadding: TimeInterval = 300

    public init(db: AppDatabase, resolver: StreamResolver, directory: URL? = nil) {
        self.db = db
        self.resolver = resolver
        self.directory = directory ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tuner Recordings", isDirectory: true)
    }

    public func configure(directory: URL?, startPadding: TimeInterval, endPadding: TimeInterval) {
        if let directory { self.directory = directory }
        self.startPadding = startPadding
        self.endPadding = endPadding
    }

    /// Locates ffmpeg (Homebrew, MacPorts, /usr/local, or inside the app bundle).
    public nonisolated static func ffmpegPath() -> String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path,
            "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var activeIds: Set<String> { Set(processes.keys) }

    // MARK: Scheduling

    /// Records `channel` from now until `end` (or for `duration`).
    @discardableResult
    public func recordNow(channel: Channel, title: String, end: Date) async throws -> Recording {
        var rec = Recording(channelId: channel.id, channelName: channel.displayName, title: title, start: Date(), end: end)
        try await db.save(rec)
        try await start(&rec)
        return rec
    }

    /// Schedules a programme with padding.
    @discardableResult
    public func schedule(channel: Channel, program: Program) async throws -> Recording {
        let rec = Recording(channelId: channel.id, channelName: channel.displayName, title: program.title,
                            start: program.start.addingTimeInterval(-startPadding), end: program.end.addingTimeInterval(endPadding))
        try await db.save(rec)
        await tick()
        return rec
    }

    public func cancel(id: String) async {
        if processes[id] != nil {
            stop(id: id)
        } else if var rec = try? await db.recordings().first(where: { $0.id == id }), rec.status == .scheduled {
            rec.status = .cancelled
            try? await db.save(rec)
        }
    }

    /// Starts due recordings and stops finished ones. Call every ~15 s.
    public func tick(now: Date = Date()) async {
        guard let recordings = try? await db.recordings() else { return }
        for var rec in recordings {
            switch rec.status {
            case .scheduled where rec.start <= now && rec.end > now:
                do { try await start(&rec) } catch {
                    rec.status = .failed
                    rec.error = error.localizedDescription
                    try? await db.save(rec)
                }
            case .scheduled where rec.end <= now:
                rec.status = .failed
                rec.error = "Missed (the app was not running)"
                try? await db.save(rec)
            case .recording where processes[rec.id] == nil:
                // Process vanished (app restarted mid-recording).
                rec.status = rec.filePath.map { FileManager.default.fileExists(atPath: $0) } == true ? .completed : .failed
                if rec.status == .failed { rec.error = "Interrupted" }
                try? await db.save(rec)
            case .recording where rec.end <= now:
                stop(id: rec.id)
            default:
                break
            }
        }
    }

    // MARK: Process control

    func start(_ rec: inout Recording) async throws {
        #if os(macOS)
        guard let ffmpeg = Self.ffmpegPath() else {
            throw RecordingError.ffmpegMissing
        }
        guard let channel = try await db.channel(id: rec.channelId) else { throw StreamError.missingSource }
        let stream = try await resolver.live(channel, format: .ts)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueFile(for: rec)

        let duration = max(10, rec.end.timeIntervalSinceNow)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = Self.arguments(stream: stream, duration: duration, output: output.path)
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr

        let id = rec.id
        process.terminationHandler = { p in
            let status = p.terminationStatus
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            Task { await self.finished(id: id, status: status, stderr: errData) }
        }
        try process.run()
        processes[id] = process
        rec.status = .recording
        rec.filePath = output.path
        rec.error = nil
        try await db.save(rec)
        #else
        throw RecordingError.unavailableOnThisDevice
        #endif
    }

    public static func arguments(stream: PlayableStream, duration: TimeInterval, output: String) -> [String] {
        var args = ["-hide_banner", "-nostats", "-loglevel", "error", "-user_agent", stream.userAgent]
        if let referrer = stream.referrer { args += ["-headers", "Referer: \(referrer)\r\n"] }
        args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_on_network_error", "1", "-reconnect_delay_max", "5"]
        if stream.url.pathExtension.lowercased() == "m3u8" {
            args += ["-live_start_index", "-1"]
        }
        args += ["-rw_timeout", "30000000", "-i", stream.url.absoluteString,
                 "-map", "0:v?", "-map", "0:a?", "-c", "copy", "-f", "mpegts",
                 "-t", String(Int(duration.rounded(.up))), "-y", output]
        return args
    }

    func stop(id: String) {
        #if os(macOS)
        guard let process = processes[id], process.isRunning else { return }
        stopRequested.insert(id)
        // "q" asks ffmpeg to finish writing cleanly; terminate if it ignores us.
        if let pipe = process.standardInput as? Pipe {
            try? pipe.fileHandleForWriting.write(contentsOf: Data("q\n".utf8))
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if process.isRunning { process.terminate() }
        }
        #endif
    }

    func finished(id: String, status: Int32, stderr: Data) async {
        processes[id] = nil
        let requested = stopRequested.remove(id) != nil
        guard var rec = try? await db.recordings().first(where: { $0.id == id }) else { return }
        let size = rec.filePath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int } ?? 0
        // Record the real end so a recording stopped early shows its actual length.
        if Date() < rec.end { rec.end = max(rec.start, Date()) }
        if size > 0 && (status == 0 || requested || rec.end <= Date().addingTimeInterval(30)) {
            rec.status = .completed
            rec.error = nil
        } else if size > 0 {
            rec.status = .completed
            rec.error = "Stream ended early"
        } else {
            rec.status = .failed
            let message = String(decoding: stderr, as: UTF8.self).split(separator: "\n").last.map(String.init)
            rec.error = message ?? "ffmpeg exited with status \(status)"
            if let path = rec.filePath { try? FileManager.default.removeItem(atPath: path) }
        }
        try? await db.save(rec)
    }

    func uniqueFile(for rec: Recording) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        func clean(_ s: String, _ max: Int) -> String {
            String(s.components(separatedBy: unsafe).joined(separator: "_").prefix(max)).trimmingCharacters(in: .whitespaces)
        }
        let base = "\(f.string(from: rec.start)) \(clean(rec.channelName, 40)) - \(clean(rec.title, 60))"
        var url = directory.appendingPathComponent(base).appendingPathExtension("ts")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(n))").appendingPathExtension("ts")
            n += 1
        }
        return url
    }

    /// Stops all recordings (app quit).
    public func stopAll() {
        for id in processes.keys { stop(id: id) }
    }
}

public enum RecordingError: LocalizedError {
    case ffmpegMissing
    case unavailableOnThisDevice

    public var errorDescription: String? {
        switch self {
        case .ffmpegMissing: "Recording needs ffmpeg. Install it with: brew install ffmpeg"
        case .unavailableOnThisDevice: "Recording isn't available on this device yet."
        }
    }
}
