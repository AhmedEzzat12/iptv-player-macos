import AppKit
import Foundation
import Observation
import os
import TunerCore

/// Services a player slot needs from the app.
@MainActor
struct PlayerServices {
    let db: AppDatabase
    let resolver: StreamResolver
    let prefs: Preferences
}

/// One video player (the main player or a multiview cell).
///
/// Owns engine routing (AVFoundation first, libmpv fallback for formats AVFoundation can't open),
/// the live-stream watchdog (stall detection → failover to duplicate channels → reconnect with
/// backoff, after ynotv), and resume-progress saving for movies/episodes.
@MainActor
@Observable
final class PlayerSlot: Identifiable {
    enum Phase: Equatable {
        case idle
        case loading
        case playing
        case paused
        case buffering
        case ended
        case failed(String)

        var isActive: Bool {
            switch self {
            case .loading, .playing, .paused, .buffering: true
            default: false
            }
        }
    }

    enum EngineKind: Hashable {
        case av
        case mpv
    }

    let id: Int
    private static let log = Logger(subsystem: "app.tuner.macos", category: "PlayerSlot")

    private(set) var item: PlaybackItem?
    private(set) var stream: PlayableStream?
    private(set) var phase: Phase = .idle
    private(set) var snapshot = EngineSnapshot()
    /// Transient status ("Switching to backup…", "Reconnecting 2/10…").
    private(set) var statusMessage: String?
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    /// The active engine's view; changes when the slot switches engines.
    private(set) var activeView: NSView = NSView()
    /// Incremented whenever `activeView` changes (for representables to re-host).
    private(set) var viewToken = 0
    private(set) var engineName = ""
    /// Live: the programme airing now on `item.channel` (refreshed by AppModel).
    var currentProgram: Program?

    /// 0…`maxVolume`. Both engines map it through the same perceptual curve (see `AVEngine.setVolume`).
    var volume: Double { didSet { engine?.setVolume(volume) } }
    /// Full volume, no amplification: Apple's player can't boost, so neither engine does (same slider, same sound).
    static let maxVolume: Double = 100
    var isMuted = false { didSet { applyMute() } }
    /// Only the main slot plays audio in multiview.
    var hasAudioFocus = true { didSet { applyMute() } }
    var aspect: VideoAspect = .fit { didSet { engine?.setAspect(aspect) } }
    var rate: Double = 1 { didSet { engine?.setRate(rate) } }

    /// Called when the item changes (including automatic failover).
    @ObservationIgnored var onItemChange: ((PlaybackItem?) -> Void)?
    /// Called when finite media finishes (autoplay next episode).
    @ObservationIgnored var onEnded: ((PlaybackItem) -> Void)?

    @ObservationIgnored private let services: PlayerServices
    @ObservationIgnored private var avEngine: AVEngine?
    @ObservationIgnored private var mpvEngine: MPVEngine?
    @ObservationIgnored private(set) var engine: PlaybackEngine?
    @ObservationIgnored private var engineKind: EngineKind?
    @ObservationIgnored private var triedKinds: Set<EngineKind> = []
    @ObservationIgnored private var pendingStartAt: Double?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var engineLoaded = false
    @ObservationIgnored private var userPaused = false
    @ObservationIgnored private var loadStartedAt = Date()
    @ObservationIgnored private var lastProgressAt = Date()
    @ObservationIgnored private var lastPosition: Double?
    @ObservationIgnored private var lastBufferedEnd: Double?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var originalChannel: Channel?
    @ObservationIgnored private var failoverTried: Set<String> = []
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// One failure per load attempt: engines report `.httpError` and then `.failed` for the same problem.
    @ObservationIgnored private var failureHandled = false
    @ObservationIgnored private var serverErrorRetries = 0
    @ObservationIgnored private var lastHTTPStatus: Int?

    /// Channels/titles whose video AVFoundation couldn't decode this session (e.g. HEVC in MPEG-TS HLS).
    /// Shared by all slots so zapping back goes straight to mpv, and AirPlay uses the bridge for them.
    private static var nativeVideoUnsupported: Set<String> = []

    /// Live and catch-up share the channel's encoding, so they share one key.
    private static func videoKey(_ item: PlaybackItem) -> String {
        item.channel.map { "ch:\($0.id)" } ?? item.id
    }

    init(id: Int, services: PlayerServices) {
        self.id = id
        self.services = services
        self.volume = min(max(services.prefs.volume, 0), Self.maxVolume)
    }

    var isPlaying: Bool { phase == .playing || phase == .buffering }
    var canSeek: Bool { item.map { !$0.isLive } ?? false || snapshot.isSeekable }
    var avEngineIfActive: AVEngine? { engineKind == .av ? avEngine : nil }

    // MARK: - Playback

    func play(_ item: PlaybackItem, startAt: Double? = nil) {
        start(item, startAt: startAt, isAutomatic: false)
    }

    func stop() {
        saveProgress(force: true)
        endBridge()
        generation += 1
        loadTask?.cancel()
        retryTask?.cancel()
        stopPolling()
        engine?.stop()
        item = nil
        stream = nil
        phase = .idle
        statusMessage = nil
        snapshot = EngineSnapshot()
        audioTracks = []
        subtitleTracks = []
        currentProgram = nil
        onItemChange?(nil)
    }

    /// Reloads the current item (e.g. after a failure).
    func retry() {
        guard let item else { return }
        retryCount = 0
        failoverTried = []
        let resume = item.isLive ? nil : snapshot.position
        start(originalChannel.map { .channel($0) } ?? item, startAt: resume, isAutomatic: false)
    }

    func togglePause() {
        guard let engine, item != nil else { return }
        if phase == .ended, let item {
            play(item, startAt: 0)
            return
        }
        userPaused = !(phase == .paused)
        engine.setPaused(userPaused)
        phase = userPaused ? .paused : .playing
        if !userPaused { lastProgressAt = Date() }
    }

    func setPaused(_ paused: Bool) {
        guard (phase == .paused) != paused else { return }
        togglePause()
    }

    func seek(by delta: Double) {
        if isBridged, item?.isLive == false {
            seek(to: max(0, (snapshot.position ?? 0) + delta))
            return
        }
        engine?.seek(by: delta)
        lastProgressAt = Date()
    }

    func seek(to seconds: Double) {
        lastProgressAt = Date()
        if isBridged, let item, !item.isLive {
            // Inside what the bridge has already re-wrapped: seek locally; beyond it: restart there.
            let relative = seconds - bridgeOffset
            if relative >= 0, relative <= bridge.generatedSeconds() - 2 {
                engine?.seek(to: relative)
            } else {
                startAirPlayBridge(item: item, at: seconds)
            }
            return
        }
        engine?.seek(to: seconds)
    }

    func selectAudioTrack(_ id: Int) {
        engine?.selectAudioTrack(id)
        refreshTracks()
    }

    func selectSubtitleTrack(_ id: Int?) {
        engine?.selectSubtitleTrack(id)
        refreshTracks()
    }

    func cycleAudioTrack() -> MediaTrack? {
        guard audioTracks.count > 1 else { return audioTracks.first }
        let current = audioTracks.firstIndex { $0.isSelected } ?? -1
        let next = audioTracks[(current + 1) % audioTracks.count]
        selectAudioTrack(next.id)
        return next
    }

    /// Cycles off → track 1 → track 2 … → off. Returns the new track (nil = off).
    func cycleSubtitleTrack() -> MediaTrack? {
        guard !subtitleTracks.isEmpty else { return nil }
        let current = subtitleTracks.firstIndex { $0.isSelected }
        let nextIndex = current.map { $0 + 1 } ?? 0
        if nextIndex >= subtitleTracks.count {
            selectSubtitleTrack(nil)
            return nil
        }
        selectSubtitleTrack(subtitleTracks[nextIndex].id)
        return subtitleTracks[nextIndex]
    }

    /// Observable PiP state (AVFoundation engine only), refreshed by the poll and the engine's PiP callback.
    private(set) var isPictureInPicturePossible = false
    private(set) var isPictureInPictureActive = false

    // MARK: - AirPlay

    enum AirPlayPreparation: Equatable {
        /// The native engine is active: the route picker can be used right away.
        case ready
        /// Reopening the stream with the native engine; pick a device once it's playing.
        case switching
        /// Re-wrapping the stream into HLS for AirPlay (MKV etc.); pick a device once it's playing.
        case bridging
        /// This format can't be sent to AirPlay devices (message explains why).
        case unsupported(String)
    }

    /// Video is currently being shown on an AirPlay device.
    private(set) var isAirPlayActive = false
    /// User-facing notices about AirPlay preparation (wired to the app's banners).
    @ObservationIgnored var onNotice: ((_ title: String, _ message: String, _ isError: Bool) -> Void)?
    @ObservationIgnored private var airPlaySwitchPending = false

    /// Whether the current stream can be played by AVFoundation (and therefore sent over AirPlay).
    var isAirPlayEligible: Bool {
        guard let item else { return false }
        if engineKind == .av { return true }
        // AVFoundation showed no picture for it before: only the bridge (re-wrap) can make it AirPlay-able.
        if Self.nativeVideoUnsupported.contains(Self.videoKey(item)) { return false }
        // Xtream live channels (incl. Xtream-panel M3U links) can be requested as HLS.
        if let channel = item.channel, item.isLive, channel.providerStreamId != nil || channel.streamURL.isEmpty { return true }
        guard let url = stream?.url else { return false }
        if url.absoluteString.lowercased().contains("m3u8") { return true }
        return ["m3u8", "mp4", "m4v", "mov", "m4a", "mp3", "aac"].contains(url.pathExtension.lowercased())
    }

    // Bridge (re-wrap to HLS for AirPlay) state.
    /// Playing through the AirPlay bridge (positions are offset into the original media).
    private(set) var isBridged = false
    @ObservationIgnored private var bridgeOffset: Double = 0
    @ObservationIgnored private var bridgeDuration: Double?
    @ObservationIgnored private var bridgeStorage: AirPlayBridge?
    private var bridge: AirPlayBridge {
        if let bridgeStorage { return bridgeStorage }
        let created = AirPlayBridge()
        bridgeStorage = created
        return created
    }

    /// A stream that isn't AirPlay-ready can still be re-wrapped on this Mac (needs ffmpeg).
    var canBridgeForAirPlay: Bool { stream != nil && RecordingService.ffmpegPath() != nil }

    private func endBridge() {
        guard isBridged || bridgeStorage?.isRunning == true else { return }
        bridgeStorage?.stop()
        isBridged = false
        bridgeOffset = 0
        bridgeDuration = nil
    }

    /// Stops the current engine (freeing the provider connection for ffmpeg), re-wraps the stream from
    /// `position` and plays the bridged HLS in AVFoundation so the AirPlay picker can send it to a device.
    private func startAirPlayBridge(item: PlaybackItem, at position: Double) {
        guard let source = isBridged ? bridgeSource : stream else { return }
        let duration = isBridged ? bridgeDuration : snapshot.duration
        let videoCodec = isBridged ? bridgeVideoCodec : snapshot.videoCodec
        let audioCodec = isBridged ? bridgeAudioCodec : snapshot.audioCodec
        generation += 1
        let gen = generation
        loadTask?.cancel()
        retryTask?.cancel()
        stopPolling()
        engine?.stop()
        bridgeStorage?.stop()
        phase = .loading
        statusMessage = "Preparing for AirPlay…"
        bridgeSource = source
        bridgeVideoCodec = videoCodec
        bridgeAudioCodec = audioCodec

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.bridge.start(stream: source, startAt: position, isLive: item.isLive,
                                                          videoCodec: videoCodec, audioCodec: audioCodec)
                guard gen == self.generation else { return }
                self.isBridged = true
                self.bridgeOffset = session.offset
                self.bridgeDuration = duration
                self.statusMessage = nil
                self.activate(.av)
                self.triedKinds = [.av, .mpv] // a bridged stream doesn't fall back to another engine
                self.engineLoaded = false
                self.failureHandled = false
                self.lastHTTPStatus = nil
                self.airPlaySwitchPending = true
                self.loadStartedAt = Date()
                self.lastProgressAt = Date()
                self.lastPosition = nil
                self.lastBufferedEnd = nil
                self.engine?.setVolume(self.volume)
                self.applyMute()
                self.engine?.load(PlayableStream(url: session.url, userAgent: HTTPClient.defaultUserAgent,
                                                 kind: item.isLive ? .live : .vod), startAt: nil)
                self.startPolling()
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                self.statusMessage = nil
                Self.log.error("AirPlay bridge failed (video \(videoCodec ?? "?", privacy: .public), audio \(audioCodec ?? "?", privacy: .public)): \(error.localizedDescription, privacy: .public)")
                self.onNotice?("AirPlay isn't available", error.localizedDescription, true)
                // Carry on playing on this Mac where we were.
                self.start(item, startAt: item.isLive ? nil : position, isAutomatic: true)
            }
        }
    }

    @ObservationIgnored private var bridgeSource: PlayableStream?
    @ObservationIgnored private var bridgeVideoCodec: String?
    @ObservationIgnored private var bridgeAudioCodec: String?

    /// Prepares the current stream for AirPlay: the native engine is required for AirPlay video, so a stream
    /// playing in mpv is reopened in AVFoundation at the same position when its format allows it.
    func prepareForAirPlay() -> AirPlayPreparation {
        guard let item else { return .unsupported("Start playing something first.") }
        if engineKind == .av { return .ready }
        guard isAirPlayEligible else {
            // Not AirPlay-ready (e.g. MKV): re-wrap it into HLS on this Mac when ffmpeg is available.
            if canBridgeForAirPlay {
                startAirPlayBridge(item: item, at: item.isLive ? 0 : (snapshot.position ?? pendingStartAt ?? 0))
                return .bridging
            }
            let ext = stream?.url.pathExtension.uppercased() ?? ""
            let format = ext.isEmpty ? "This stream's format" : "This \(ext) stream"
            return .unsupported("\(format) needs converting for AirPlay, which requires ffmpeg (brew install ffmpeg). Audio still follows the Mac's sound output.")
        }
        airPlaySwitchPending = true
        start(item, startAt: item.isLive ? nil : snapshot.position, isAutomatic: true, forcedKind: .av)
        return .switching
    }

    func togglePictureInPicture() { avEngineIfActive?.togglePictureInPicture() }

    func shutdown() {
        saveProgress(force: true)
        endBridge()
        stopPolling()
        avEngine?.shutdown()
        mpvEngine?.shutdown()
    }

    // MARK: - Loading & routing

    private func start(_ item: PlaybackItem, startAt: Double?, isAutomatic: Bool, forcedKind: EngineKind? = nil) {
        if !isAutomatic { saveProgress(force: true) }
        generation += 1
        loadTask?.cancel()
        retryTask?.cancel()
        // Close the current stream before requesting the next one: single-connection accounts would
        // otherwise see two streams for a moment and the provider refuses the new one.
        engine?.stop()
        if !isAutomatic { serverErrorRetries = 0 }
        if !isAutomatic {
            originalChannel = item.channel
            failoverTried = []
            retryCount = 0
            statusMessage = nil
        }
        if let ch = item.channel, item.isLive { failoverTried.insert(ch.id) }
        triedKinds = []
        userPaused = false
        engineLoaded = false
        snapshot = EngineSnapshot()
        audioTracks = []
        subtitleTracks = []
        let changed = self.item != item
        self.item = item
        if changed || !isAutomatic { currentProgram = nil }
        phase = .loading
        pendingStartAt = startAt
        if changed { onItemChange?(item) }
        load(item, preferring: forcedKind)
    }

    private func load(_ item: PlaybackItem, preferring forced: EngineKind?) {
        endBridge()
        let gen = generation
        loadTask?.cancel()
        failureHandled = false
        lastHTTPStatus = nil
        let choice = services.prefs.engine
        let mpvOK = EngineFactory.mpvAvailable
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Native first: ask Xtream panels for HLS, which AVFoundation plays; fall back to TS for mpv.
                // Items whose video AVFoundation already failed to decode go straight to mpv.
                let knownBlind = choice == .automatic && mpvOK && Self.nativeVideoUnsupported.contains(Self.videoKey(item))
                let wantNative = forced.map { $0 == .av } ?? (!knownBlind && (choice != .mpv || !mpvOK))
                let stream = try await self.resolve(item, liveFormat: wantNative ? .m3u8 : .ts)
                guard gen == self.generation else { return }
                let kind = forced ?? (knownBlind ? .mpv : Self.route(stream.url, choice: choice, mpvAvailable: mpvOK))
                self.activate(kind)
                self.triedKinds.insert(kind)
                self.stream = stream
                self.loadStartedAt = Date()
                self.lastProgressAt = Date()
                self.lastPosition = nil
                self.lastBufferedEnd = nil
                self.engine?.setVolume(self.volume)
                self.applyMute()
                self.engine?.setAspect(self.aspect)
                self.engine?.load(stream, startAt: self.pendingStartAt)
                if self.rate != 1 { self.engine?.setRate(self.rate) }
                self.startPolling()
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                self.engineFailed(error.localizedDescription)
            }
        }
    }

    private func resolve(_ item: PlaybackItem, liveFormat: XtreamClient.LiveFormat) async throws -> PlayableStream {
        let r = services.resolver
        switch item {
        case .channel(let c):
            return try await r.live(c, format: liveFormat)
        case .catchup(let c, let p):
            let pad = TimeInterval(services.prefs.catchupPaddingMinutes * 60)
            return try await r.catchup(c, program: p, paddingBefore: pad, paddingAfter: pad)
        case .movie(let m):
            return try await r.movie(m)
        case .episode(let e, _):
            return try await r.episode(e)
        case .recording(let rec):
            guard let path = rec.filePath else { throw StreamError.invalidURL(rec.title) }
            return PlayableStream(url: URL(fileURLWithPath: path), userAgent: HTTPClient.defaultUserAgent, kind: .vod)
        }
    }

    /// AVFoundation for what it plays natively (HLS, MP4/MOV); mpv for raw TS, MKV, non-HTTP schemes.
    static func route(_ url: URL, choice: EngineChoice, mpvAvailable: Bool) -> EngineKind {
        guard mpvAvailable, choice != .avFoundation else { return .av }
        if choice == .mpv { return .mpv }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "file"].contains(scheme) else { return .mpv }
        let ext = url.pathExtension.lowercased()
        if ["m3u8", "mp4", "m4v", "mov", "m4a", "mp3", "aac"].contains(ext) { return .av }
        if url.absoluteString.lowercased().contains("m3u8") { return .av }
        return .mpv
    }

    private func activate(_ kind: EngineKind) {
        if engineKind == kind, engine != nil { return }
        engine?.stop()
        let newEngine: PlaybackEngine
        switch kind {
        case .av:
            if avEngine == nil { avEngine = AVEngine() }
            newEngine = avEngine!
        case .mpv:
            if mpvEngine == nil { mpvEngine = MPVEngine(prefs: services.prefs) }
            guard let mpv = mpvEngine else {
                activate(.av)
                return
            }
            newEngine = mpv
        }
        newEngine.onEvent = { [weak self, weak newEngine] event in
            guard let self, let newEngine, newEngine === self.engine else { return }
            self.handle(event)
        }
        if let av = newEngine as? AVEngine {
            av.onPictureInPictureChanged = { [weak self] active in self?.isPictureInPictureActive = active }
            av.onExternalPlaybackChanged = { [weak self] active in self?.isAirPlayActive = active }
            isAirPlayActive = av.isExternalPlaybackActive
        } else {
            isAirPlayActive = false
        }
        engine = newEngine
        engineKind = kind
        engineName = newEngine.name
        activeView = newEngine.view
        viewToken += 1
    }

    // MARK: - Engine events

    private func handle(_ event: EngineEvent) {
        switch event {
        case .loaded:
            engineLoaded = true
            if airPlaySwitchPending {
                airPlaySwitchPending = false
                if engineKind == .av {
                    onNotice?("Ready for AirPlay", "Click the AirPlay button and choose a device.", false)
                } else if canBridgeForAirPlay, let item {
                    // Apple's player couldn't show it directly: re-wrap it instead.
                    onNotice?("Preparing AirPlay…", "Re-wrapping this stream for AirPlay devices on your Mac (no quality loss). It takes a few seconds.", false)
                    bridgeOnceCodecKnown(item)
                } else {
                    onNotice?("AirPlay isn't available for this stream", "Apple's player couldn't open it, so it keeps playing on this Mac.", true)
                }
            }
            if phase == .loading || phase == .buffering { phase = .playing }
            lastProgressAt = Date()
            refreshTracks()
            // Tracks often appear a moment after load.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.refreshTracks()
            }
        case .ended:
            if item?.isLive == true {
                streamDied("Stream ended")
            } else {
                finish()
            }
        case .failed(let message):
            // Prefer the precise HTTP reason when the engine reported one just before.
            engineFailed(lastHTTPStatus.map { HTTPError.status($0, url: "").localizedDescription } ?? message)
        case .httpError(let code):
            // Recorded only; the `.failed` that follows triggers the (single) fallback.
            if !engineLoaded { lastHTTPStatus = code }
        case .videoUnsupported:
            videoUnsupported()
        }
    }

    /// AVFoundation plays the sound but can't decode the picture (black video with audio): reopen in mpv,
    /// which decodes it, and remember the item so the next tune skips AVFoundation.
    private func videoUnsupported() {
        guard let item else { return }
        Self.nativeVideoUnsupported.insert(Self.videoKey(item))
        let mayFallBack = services.prefs.engine == .automatic || airPlaySwitchPending
        if EngineFactory.mpvAvailable, !triedKinds.contains(.mpv), mayFallBack {
            engine?.stop()
            engineLoaded = false
            load(item, preferring: .mpv)
        } else if isBridged {
            onNotice?("No picture over AirPlay", "AirPlay devices can't decode this stream's video, so only the sound is sent.", true)
        } else {
            onNotice?("No picture for this stream", "Apple's player can't decode its video. Set “Playback engine” to Automatic in Settings → Playback to play it with mpv.", true)
        }
    }

    /// Starts the AirPlay bridge once the engine has reported the video codec (the bridge picks TS or
    /// fMP4 segments from it), at most a few seconds after load.
    private func bridgeOnceCodecKnown(_ item: PlaybackItem) {
        let gen = generation
        Task { [weak self] in
            for _ in 0..<24 {
                guard let self, gen == self.generation else { return }
                if self.snapshot.videoCodec != nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, gen == self.generation else { return }
            self.startAirPlayBridge(item: item, at: item.isLive ? 0 : (self.snapshot.position ?? self.pendingStartAt ?? 0))
        }
    }

    private func engineFailed(_ message: String) {
        guard let item, !failureHandled else { return }
        failureHandled = true
        // Silence the failed engine before anything else so it can't emit more events or keep a connection open.
        engine?.stop()
        // Try the other engine once (AVFoundation can't open raw TS/MKV; mpv may choke on odd HLS) —
        // but not for definitive HTTP client errors (401/403/404…): another decoder can't fix those, and
        // a second request wastes a connection on single-connection accounts.
        let definitiveHTTPError = lastHTTPStatus.map { (400..<500).contains($0) } ?? false
        if let current = engineKind, !definitiveHTTPError {
            let other: EngineKind = current == .av ? .mpv : .av
            let otherAvailable = other == .av || EngineFactory.mpvAvailable
            if otherAvailable, !triedKinds.contains(other), services.prefs.engine == .automatic || airPlaySwitchPending {
                engineLoaded = false
                load(item, preferring: other)
                return
            }
        }
        if item.isLive {
            streamDied(message)
        } else {
            // One automatic retry for transient provider errors (5xx), e.g. a connection hand-off race.
            if let status = lastHTTPStatus, (500..<600).contains(status), serverErrorRetries < 1 {
                serverErrorRetries += 1
                let resume = pendingStartAt ?? snapshot.position
                statusMessage = "Retrying…"
                let gen = generation
                retryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, gen == self.generation, !Task.isCancelled else { return }
                    self.statusMessage = nil
                    self.start(item, startAt: resume, isAutomatic: true)
                }
                return
            }
            stopPolling()
            phase = .failed(Self.describeFailure(status: lastHTTPStatus, fallback: message, item: item))
        }
    }

    /// Explains a failed stream in terms of what the provider did, not just the status code.
    static func describeFailure(status: Int?, fallback: String, item: PlaybackItem) -> String {
        let what: String = switch item {
        case .episode: "this episode"
        case .movie: "this movie"
        case .catchup: "this programme from the archive"
        default: "this stream"
        }
        guard let status else { return fallback }
        switch status {
        case 401, 403:
            return "Your provider refused \(what) (HTTP \(status)). Your subscription may not include it, or another device is using your connection."
        case 404, 410:
            return "Your provider no longer has \(what) on its server (HTTP \(status))."
        case 429, 458, 509:
            return "Your provider says too many streams are open (HTTP \(status)). Close other players using this account and try again."
        case 500..<600:
            return "Your provider couldn't deliver \(what) right now (HTTP \(status)). Other titles should still play — try this one again later."
        default:
            return fallback
        }
    }

    private func finish() {
        // Both the `.ended` event and the polled `reachedEnd` can report the end; act once.
        guard let item, phase != .ended else { return }
        saveProgress(force: true, completed: true)
        phase = .ended
        stopPolling()
        onEnded?(item)
    }

    // MARK: - Polling & watchdog

    private func startPolling() {
        stopPolling()
        ticks = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard let engine, item != nil else { return }
        ticks += 1
        var s = engine.snapshot()
        if isBridged {
            if let p = s.position { s.position = p + bridgeOffset }
            if let b = s.bufferedEnd { s.bufferedEnd = b + bridgeOffset }
            if let d = bridgeDuration { s.duration = d } // event playlists report no duration
            if item?.isLive == false { s.isSeekable = true }
        }
        if s != snapshot { snapshot = s }

        if case .failed = phase { return }
        if phase != .ended {
            if engineLoaded || (s.position ?? 0) > 0 {
                let newPhase: Phase = userPaused ? .paused : (s.isBuffering ? .buffering : .playing)
                if newPhase != phase { phase = newPhase }
            }
            if s.reachedEnd, item?.isLive == false, engineLoaded {
                finish()
                return
            }
        }
        let pipPossible = avEngineIfActive?.isPictureInPicturePossible ?? false
        if pipPossible != isPictureInPicturePossible { isPictureInPicturePossible = pipPossible }
        if ticks % 2 == 0 { watchdog() }
        if ticks % 6 == 0 { refreshTracks() }
        if ticks % 20 == 0 { saveProgress() }
    }

    private func watchdog() {
        guard let item, item.isLive, !userPaused else { return }
        let now = Date()
        let s = snapshot
        var progressed = false
        if let p = s.position, let lp = lastPosition, p - lp > 0.25 { progressed = true }
        if let b = s.bufferedEnd, let lb = lastBufferedEnd, b - lb > 0.25 { progressed = true }
        if let p = s.position { lastPosition = p }
        if let b = s.bufferedEnd { lastBufferedEnd = b }
        if progressed {
            lastProgressAt = now
            if retryCount > 0 || statusMessage != nil {
                retryCount = 0
                statusMessage = nil
            }
            failoverTried = item.channel.map { [$0.id] } ?? []
            return
        }
        let grace: TimeInterval = retryCount > 0 ? 10 : 6
        guard now.timeIntervalSince(loadStartedAt) > grace else { return }
        let stalled = now.timeIntervalSince(lastProgressAt)
        if s.reachedEnd || (s.isIdle && stalled > 4) || stalled > TimeInterval(services.prefs.stallTimeoutSeconds) {
            streamDied("Stream stopped responding")
        }
    }

    /// Live stream died: try a duplicate channel (same EPG/tvg-id/name), else reconnect with backoff.
    private func streamDied(_ reason: String) {
        guard let current = item?.channel ?? originalChannel else {
            phase = .failed(reason)
            return
        }
        stopPolling()
        engine?.stop()
        let gen = generation
        retryTask = Task { [weak self] in
            guard let self else { return }
            if self.services.prefs.autoFailover {
                let base = self.originalChannel ?? current
                let alternates = (try? await self.services.db.alternateChannels(for: base)) ?? []
                guard gen == self.generation else { return }
                let candidates = ([base] + alternates).filter { !self.failoverTried.contains($0.id) }
                if let next = candidates.first {
                    self.statusMessage = "Switching to \(next.displayName)…"
                    self.start(.channel(next), startAt: nil, isAutomatic: true)
                    return
                }
            }
            self.retryCount += 1
            let maxRetries = self.services.prefs.maxRetries
            guard self.retryCount <= maxRetries else {
                let detail = reason.hasSuffix(".") ? reason : reason + "."
                self.phase = .failed("This channel isn't responding. \(detail)")
                self.statusMessage = nil
                return
            }
            let delay = min(self.retryCount, 5)
            self.statusMessage = "Reconnecting (\(self.retryCount)/\(maxRetries))…"
            self.phase = .buffering
            try? await Task.sleep(for: .seconds(delay))
            guard gen == self.generation, !Task.isCancelled else { return }
            self.failoverTried = []
            self.start(.channel(self.originalChannel ?? current), startAt: nil, isAutomatic: true)
        }
    }

    // MARK: - Helpers

    private func applyMute() {
        engine?.setMuted(isMuted || !hasAudioFocus)
    }

    private func refreshTracks() {
        guard let engine else { return }
        let a = engine.audioTracks()
        let s = engine.subtitleTracks()
        if a != audioTracks { audioTracks = a }
        if s != subtitleTracks { subtitleTracks = s }
    }

    private func saveProgress(force: Bool = false, completed: Bool = false) {
        guard let item, let key = item.progressKey else { return }
        guard force || Date().timeIntervalSince(lastProgressSave) > 9 else { return }
        guard let duration = snapshot.duration, duration > 0 else { return }
        let position = completed ? duration : (snapshot.position ?? 0)
        guard position > 5 || completed else { return }
        lastProgressSave = Date()
        let progress: WatchProgress
        switch item {
        case .movie(let m):
            progress = WatchProgress(mediaId: key, kind: .movie, sourceId: m.sourceId, title: m.name, subtitle: m.year,
                                     posterURL: m.backdropURL ?? m.posterURL, position: position, duration: duration)
        case .episode(let e, let s):
            progress = WatchProgress(mediaId: key, kind: .episode, sourceId: e.sourceId, seriesId: s.id, title: s.name,
                                     subtitle: "S\(e.season), E\(e.number) · \(e.title)", posterURL: e.imageURL ?? s.backdropURL ?? s.coverURL,
                                     position: position, duration: duration)
        default:
            return
        }
        let db = services.db
        Task { try? await db.saveProgress(progress) }
    }
}

enum EngineFactory {
    /// libmpv search order: inside the app bundle, Homebrew (Apple silicon, Intel), MacPorts.
    static let libmpvCandidates: [String] = [
        Bundle.main.privateFrameworksPath.map { $0 + "/libmpv.2.dylib" },
        "/opt/homebrew/lib/libmpv.2.dylib", "/opt/homebrew/lib/libmpv.dylib",
        "/usr/local/lib/libmpv.2.dylib", "/usr/local/lib/libmpv.dylib",
        "/opt/local/lib/libmpv.2.dylib",
    ].compactMap { $0 }

    static let mpvAvailable: Bool = MPVEngine.loadLibrary(candidates: libmpvCandidates)
}
