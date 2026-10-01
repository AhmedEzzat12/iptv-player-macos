import AppKit
import CMPV
import TunerCore

/// libmpv playback engine (fallback for streams AVFoundation can't open: raw MPEG-TS over HTTP,
/// MKV, unusual codecs, udp/rtmp). Renders through the libmpv OpenGL render API into
/// `MPVVideoLayer`; libmpv is loaded at runtime through the CMPV shim.
@MainActor
final class MPVEngine: PlaybackEngine {
    // MARK: Library loading

    nonisolated private static let libraryLock = NSLock()
    nonisolated(unsafe) private static var libraryLoaded: Bool?

    /// Loads libmpv via the CMPV shim (`cmpv_load`) once; thread-safe; returns cached result afterwards.
    nonisolated static func loadLibrary(candidates: [String]) -> Bool {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        if let libraryLoaded { return libraryLoaded }
        let copies = candidates.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let paths: [UnsafePointer<CChar>?] = copies.map { $0.map { UnsafePointer($0) } }
        let loaded = paths.withUnsafeBufferPointer { cmpv_load($0.baseAddress, Int32($0.count)) } == 1
        libraryLoaded = loaded
        return loaded
    }

    // MARK: State

    var name: String { "mpv" }
    let view: NSView
    var onEvent: ((EngineEvent) -> Void)?

    private let handle: OpaquePointer
    private let renderer: MPVRenderer
    private let pump: MPVEventPump
    /// Bumped by every load/stop; events from older generations are dropped.
    private var generation: UInt64 = 0
    private var isShutDown = false

    /// nil if libmpv isn't loaded or mpv_create/initialize fails.
    init?(prefs: Preferences) {
        guard cmpv_is_loaded() != 0 else { return nil }
        // libmpv refuses to start (mpv_create returns NULL) under a non-C numeric locale.
        setlocale(LC_NUMERIC, "C")
        let userOptions = prefs.parsedMPVOptions
        var created = MPVEngine.makeCore(prefs: prefs, userOptions: userOptions)
        if created == nil, !userOptions.isEmpty {
            // A bad line in the advanced options box shouldn't take mpv down entirely.
            NSLog("Tuner: mpv failed to initialize with the advanced options; retrying without them")
            created = MPVEngine.makeCore(prefs: prefs, userOptions: [])
        }
        guard let handle = created else { return nil }
        mpv_request_log_messages(handle, "warn")

        guard let renderer = MPVRenderer(handle: handle) else {
            mpv_terminate_destroy(handle)
            return nil
        }
        self.handle = handle
        self.renderer = renderer
        self.pump = MPVEventPump(handle: handle)
        self.view = MPVVideoView(videoLayer: MPVVideoLayer(renderer: renderer))
        pump.owner = self
        pump.start()
    }

    /// Creates and initializes an mpv core with Tuner's options (+ the user's advanced options).
    private static func makeCore(prefs: Preferences, userOptions: [(String, String)]) -> OpaquePointer? {
        guard let handle = mpv_create() else { return nil }
        func option(_ name: String, _ value: String) {
            let result = mpv_set_option_string(handle, name, value)
            if result < 0 {
                NSLog("Tuner: mpv option %@=%@ rejected: %s", name, value, mpv_error_string(result))
            }
        }
        option("vo", "libmpv")
        option("hwdec", prefs.hardwareDecoding ? "auto-safe" : "no")
        option("keep-open", "yes")
        option("idle", "yes")
        option("input-default-bindings", "no")
        option("input-vo-keyboard", "no")
        option("osc", "no")
        option("terminal", "no")
        option("config", "no")
        option("ytdl", "no")
        option("audio-client-name", "Tuner")
        option("cache", "yes")
        option("demuxer-max-bytes", "\(max(prefs.bufferMegabytes, 1))MiB")
        option("demuxer-max-back-bytes", "\(max(prefs.timeshiftMegabytes, 0))MiB")
        option("network-timeout", "15")
        option("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,reconnect_on_network_error=1")
        option("volume-max", "150")
        option("volume", format(min(max(prefs.volume, 0), 150)))
        for (name, value) in userOptions {
            option(name, value) // user-supplied; failures are logged and ignored
        }
        // Never let the advanced box replace the embedded video output or make the core quit when idle.
        option("vo", "libmpv")
        option("idle", "yes")

        let result = mpv_initialize(handle)
        guard result >= 0 else {
            NSLog("Tuner: mpv_initialize failed: %s", mpv_error_string(result))
            mpv_terminate_destroy(handle)
            return nil
        }
        return handle
    }

    deinit {
        // Normally `shutdown()` already ran; this keeps a dropped engine from leaking a playing core.
        MPVEngine.teardown(renderer: renderer, pump: pump)
    }

    /// Frees the render context (render queue, GL context current), then destroys the core off the
    /// main thread (event queue, so it can't race the event drain). Idempotent.
    nonisolated private static func teardown(renderer: MPVRenderer, pump: MPVEventPump) {
        guard pump.markTornDown() else { return }
        renderer.queue.async {
            renderer.destroy()
            pump.queue.async { pump.terminate() }
        }
    }

    fileprivate func receive(_ event: EngineEvent, generation eventGeneration: UInt64) {
        guard !isShutDown, eventGeneration == generation else { return }
        onEvent?(event)
    }

    // MARK: PlaybackEngine

    func load(_ stream: PlayableStream, startAt: Double?) {
        guard !isShutDown else { return }
        generation &+= 1
        let gen = generation
        pump.begin(generation: gen, startAt: startAt.flatMap { $0 > 0 ? $0 : nil })

        let userAgent = stream.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        command(["set", "user-agent", userAgent.isEmpty ? "libmpv" : userAgent])
        // change-list append takes the header verbatim (no list splitting on commas).
        command(["change-list", "http-header-fields", "clr", ""])
        if let referrer = stream.referrer?.trimmingCharacters(in: .whitespacesAndNewlines), !referrer.isEmpty {
            command(["change-list", "http-header-fields", "append", "Referer: \(referrer)"])
        }
        command(["set", "pause", "no"])
        let target = stream.url.isFileURL ? stream.url.path : stream.url.absoluteString
        let result = command(["loadfile", target, "replace"], replyID: gen)
        if result < 0 {
            let message = MPVEventPump.friendlyMessage(for: result, httpCode: nil)
            DispatchQueue.main.async { [weak self] in self?.receive(.failed(message), generation: gen) }
        }
    }

    func stop() {
        guard !isShutDown else { return }
        generation &+= 1
        pump.begin(generation: generation, startAt: nil)
        command(["stop"])
    }

    func setPaused(_ paused: Bool) {
        command(["set", "pause", paused ? "yes" : "no"])
    }

    func seek(to seconds: Double) {
        command(["seek", MPVEngine.format(max(seconds, 0)), "absolute"])
    }

    func seek(by delta: Double) {
        command(["seek", MPVEngine.format(delta), "relative"])
    }

    func setVolume(_ volume: Double) {
        command(["set", "volume", MPVEngine.format(min(max(volume, 0), 150))])
    }

    func setMuted(_ muted: Bool) {
        command(["set", "mute", muted ? "yes" : "no"])
    }

    func setRate(_ rate: Double) {
        command(["set", "speed", MPVEngine.format(min(max(rate, 0.01), 100))])
    }

    func setAspect(_ aspect: VideoAspect) {
        switch aspect {
        case .fit:
            command(["set", "keepaspect", "yes"])
            command(["set", "panscan", "0"])
            command(["set", "video-aspect-override", "no"])
        case .fill:
            command(["set", "keepaspect", "yes"])
            command(["set", "video-aspect-override", "no"])
            command(["set", "panscan", "1"])
        case .stretch:
            command(["set", "panscan", "0"])
            command(["set", "video-aspect-override", "no"])
            command(["set", "keepaspect", "no"])
        case .ratio16x9, .ratio4x3:
            command(["set", "keepaspect", "yes"])
            command(["set", "panscan", "0"])
            command(["set", "video-aspect-override", aspect == .ratio16x9 ? "16:9" : "4:3"])
        }
    }

    func snapshot() -> EngineSnapshot {
        var s = EngineSnapshot()
        guard !isShutDown else {
            s.isIdle = true
            return s
        }
        s.position = double("time-pos")
        s.duration = double("duration")
        s.isPaused = flag("pause") ?? false
        s.isBuffering = flag("paused-for-cache") ?? false
        s.isIdle = flag("idle-active") ?? false
        s.reachedEnd = flag("eof-reached") ?? false
        s.bufferedEnd = double("demuxer-cache-time")
        s.bufferedSeconds = double("demuxer-cache-duration")
        if let w = int("video-params/w"), let h = int("video-params/h"), w > 0, h > 0 {
            s.videoSize = CGSize(width: Double(w), height: Double(h))
        }
        s.videoCodec = string("video-format") ?? string("video-codec")
        s.audioCodec = string("audio-codec-name")
        s.fps = double("estimated-vf-fps") ?? double("container-fps")
        s.videoBitrate = double("video-bitrate")
        s.audioBitrate = double("audio-bitrate")
        if let hw = string("hwdec-current"), hw != "no" { s.hardwareDecoder = hw }
        s.droppedFrames = int("frame-drop-count").map { Int($0) }
        s.isSeekable = flag("seekable") ?? false
        return s
    }

    func audioTracks() -> [MediaTrack] { tracks(ofType: "audio") }

    func subtitleTracks() -> [MediaTrack] { tracks(ofType: "sub") }

    func selectAudioTrack(_ id: Int) {
        command(["set", "aid", String(id)])
    }

    func selectSubtitleTrack(_ id: Int?) {
        command(["set", "sid", id.map(String.init) ?? "no"])
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        generation &+= 1
        onEvent = nil
        pump.begin(generation: generation, startAt: nil)
        MPVEngine.teardown(renderer: renderer, pump: pump)
    }

    // MARK: - mpv helpers

    /// Queues a command asynchronously (never blocks the main thread on the mpv core).
    @discardableResult
    private func command(_ args: [String], replyID: UInt64 = 0) -> Int32 {
        guard !isShutDown else { return MPV_ERROR_UNINITIALIZED.rawValue }
        return args.withCStringArray { mpv_command_async(handle, replyID, $0) }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func double(_ name: String) -> Double? {
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 && value.isFinite ? value : nil
    }

    private func int(_ name: String) -> Int64? {
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    private func flag(_ name: String) -> Bool? {
        var value: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    private func string(_ name: String) -> String? {
        guard let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    private func tracks(ofType type: String) -> [MediaTrack] {
        guard !isShutDown else { return [] }
        var node = mpv_node()
        guard mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &node) >= 0 else { return [] }
        defer { mpv_free_node_contents(&node) }
        guard let list = MPVNode.decode(node) as? [Any] else { return [] }
        return list.compactMap { entry -> MediaTrack? in
            guard let track = entry as? [String: Any], track["type"] as? String == type,
                  let id = track["id"] as? Int64 else { return nil }
            return MediaTrack(
                id: Int(id),
                title: track["title"] as? String ?? "",
                language: track["lang"] as? String,
                codec: track["codec"] as? String,
                isSelected: track["selected"] as? Bool ?? false
            )
        }
    }
}

// MARK: - Event pump

/// Drains the mpv event queue on a private serial queue and forwards events for the current load
/// to the engine on the main thread. Passed to mpv as the wakeup callback context instead of the
/// main-actor engine.
final class MPVEventPump: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.tuner.mpv.events", qos: .userInitiated)
    /// Read and written on the main thread only.
    weak var owner: MPVEngine?

    private let handle: OpaquePointer

    // Guarded by `lock` (written on main, read on the event queue).
    private let lock = NSLock()
    private var latestGeneration: UInt64 = 0
    private var pendingStartAt: Double?
    private var tornDown = false

    // Event-queue only.
    private var terminated = false
    /// Generation whose `loadfile` the core accepted, and the playlist entry it created.
    private var acceptedGeneration: UInt64 = .max
    private var acceptedEntry: Int64?
    private var startedEntry: Int64?
    private var httpCode: Int?
    private var reportedHTTPError = false

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    func start() {
        mpv_set_wakeup_callback(handle, { ctx in
            // Called on arbitrary mpv threads: must not call into mpv here.
            guard let ctx else { return }
            let pump = Unmanaged<MPVEventPump>.fromOpaque(ctx).takeUnretainedValue()
            pump.queue.async { pump.drain() }
        }, Unmanaged.passUnretained(self).toOpaque())
        queue.async { self.drain() }
    }

    /// A new load (or stop) supersedes everything that came before it.
    func begin(generation: UInt64, startAt: Double?) {
        lock.lock()
        latestGeneration = generation
        pendingStartAt = startAt
        lock.unlock()
    }

    /// Returns true the first time only.
    func markTornDown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if tornDown { return false }
        tornDown = true
        return true
    }

    /// Destroys the core. Runs on `queue` after the render context was freed.
    func terminate() {
        guard !terminated else { return }
        terminated = true
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
    }

    private var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return latestGeneration
    }

    private func takeStartAt() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let value = pendingStartAt
        pendingStartAt = nil
        return value
    }

    /// The generation an event about `entry` belongs to, or nil if it's stale.
    private func liveGeneration(entry: Int64?) -> UInt64? {
        let latest = currentGeneration
        guard acceptedGeneration == latest else { return nil }
        if let acceptedEntry, let entry, acceptedEntry != entry { return nil }
        return latest
    }

    private func drain() {
        while !terminated {
            guard let event = mpv_wait_event(handle, 0) else { return }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { return }
            if id == MPV_EVENT_SHUTDOWN { return }
            process(event.pointee)
        }
    }

    private func process(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_COMMAND_REPLY:
            let gen = event.reply_userdata
            guard gen != 0, gen == currentGeneration else { return }
            if event.error < 0 {
                deliver(.failed(MPVEventPump.friendlyMessage(for: event.error, httpCode: nil)), gen)
                return
            }
            acceptedGeneration = gen
            acceptedEntry = nil
            startedEntry = nil
            httpCode = nil
            reportedHTTPError = false
            if let reply = event.data?.assumingMemoryBound(to: mpv_event_command.self).pointee,
               let result = MPVNode.decode(reply.result) as? [String: Any] {
                acceptedEntry = result["playlist_entry_id"] as? Int64
            }

        case MPV_EVENT_START_FILE:
            startedEntry = event.data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id

        case MPV_EVENT_FILE_LOADED:
            guard let gen = liveGeneration(entry: startedEntry) else { return }
            if let startAt = takeStartAt() {
                _ = ["seek", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), startAt), "absolute"]
                    .withCStringArray { mpv_command_async(handle, 0, $0) }
            }
            deliver(.loaded, gen)

        case MPV_EVENT_END_FILE:
            guard let info = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                  let gen = liveGeneration(entry: info.playlist_entry_id) else { return }
            switch info.reason {
            case MPV_END_FILE_REASON_ERROR:
                deliver(.failed(MPVEventPump.friendlyMessage(for: info.error, httpCode: httpCode)), gen)
            case MPV_END_FILE_REASON_EOF:
                deliver(.ended, gen)
            default:
                break // stop/quit/redirect: superseded by another load or teardown
            }

        case MPV_EVENT_LOG_MESSAGE:
            guard let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                  let text = message.text.map({ String(cString: $0) }),
                  let code = MPVEventPump.httpStatus(in: text),
                  let gen = liveGeneration(entry: nil) else { return }
            httpCode = code
            if !reportedHTTPError {
                reportedHTTPError = true
                deliver(.httpError(code), gen)
            }

        default:
            break
        }
    }

    private func deliver(_ event: EngineEvent, _ generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            self?.owner?.receive(event, generation: generation)
        }
    }

    /// Extracts an HTTP status from FFmpeg/mpv log lines such as "HTTP error 404 Not Found" or
    /// "Server returned 403 Forbidden (access denied)" / "Server returned 5XX Server Error reply".
    static func httpStatus(in text: String) -> Int? {
        for marker in ["HTTP error ", "Server returned "] {
            guard let range = text.range(of: marker, options: .caseInsensitive) else { continue }
            let code = text[range.upperBound...].prefix(3)
            if code.uppercased() == "5XX" { return 500 }
            if code.uppercased() == "4XX" { return 400 }
            if code.count == 3, let value = Int(code), (400..<600).contains(value) { return value }
        }
        return nil
    }

    static func friendlyMessage(for error: Int32, httpCode: Int?) -> String {
        if let httpCode {
            switch httpCode {
            case 401: return "The server requires authorization for this stream (HTTP 401)."
            case 403: return "The server refused access to this stream (HTTP 403)."
            case 404: return "The stream wasn't found on the server (HTTP 404)."
            case 500..<600: return "The server had a problem delivering this stream (HTTP \(httpCode))."
            default: return "The server rejected this stream (HTTP \(httpCode))."
            }
        }
        switch mpv_error(rawValue: error) {
        case MPV_ERROR_LOADING_FAILED: return "The stream couldn't be opened. It may be offline or unreachable."
        case MPV_ERROR_UNKNOWN_FORMAT: return "This stream's format isn't recognised."
        case MPV_ERROR_NOTHING_TO_PLAY: return "The stream contains no playable audio or video."
        case MPV_ERROR_UNSUPPORTED: return "This stream uses a format that isn't supported."
        case MPV_ERROR_AO_INIT_FAILED: return "Audio output couldn't be started."
        case MPV_ERROR_VO_INIT_FAILED: return "Video output couldn't be started."
        default:
            let detail = String(cString: mpv_error_string(error))
            return "Playback failed (\(detail))."
        }
    }
}

private extension Array where Element == String {
    func withCStringArray<R>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let copies = map { strdup($0) }
        defer { copies.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = copies.map { $0.map { UnsafePointer($0) } }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}

/// Converts an `mpv_node` tree into Swift values (String, Bool, Int64, Double, [Any], [String: Any]).
private enum MPVNode {
    static func decode(_ node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING, MPV_FORMAT_OSD_STRING:
            return node.u.string.map { String(cString: $0) }
        case MPV_FORMAT_FLAG:
            return node.u.flag != 0
        case MPV_FORMAT_INT64:
            return node.u.int64
        case MPV_FORMAT_DOUBLE:
            return node.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee, let values = list.values else { return [Any]() }
            return (0..<Int(list.num)).compactMap { decode(values[$0]) }
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee, let values = list.values, let keys = list.keys else {
                return [String: Any]()
            }
            var map: [String: Any] = [:]
            for i in 0..<Int(list.num) {
                guard let key = keys[i], let value = decode(values[i]) else { continue }
                map[String(cString: key)] = value
            }
            return map
        default:
            return nil
        }
    }
}
