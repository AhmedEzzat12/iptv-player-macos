#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import AVKit
import CoreMedia
import os
import TunerCore

/// Native playback engine on AVFoundation/AVKit (`AVPlayer` rendering into an `AVPlayerLayer`).
///
/// Plays what AVFoundation opens natively — HLS (`.m3u8`), MP4/MOV/M4V, MP3/AAC, and finite MPEG-TS
/// files from servers that honour byte ranges — and reports everything else (live raw `.ts` streams,
/// MKV, servers without range support, HTTP errors) through `.failed`, normally within a fraction
/// of a second and at most after `loadTimeout`, so the caller can fall back to mpv.
/// Also provides native Picture in Picture (`togglePictureInPicture()`) and AirPlay (hand `player`
/// to an `AVRoutePickerView`). No AVKit chrome is shown; the app draws its own controls.
///
/// Event contract: at most one `.loaded` per `load`; on failure the item is torn down first (so it
/// can't keep playing behind a fallback engine), then `.httpError(code)` (when an HTTP status is
/// known) and `.failed(message)` are delivered. Nothing from an earlier `load` is delivered after
/// `load`/`stop` is called again.
@MainActor
final class AVEngine: NSObject, PlaybackEngine {
    /// How long `load` may take to reach `readyToPlay` before `.failed("Timed out")`.
    static let loadTimeout: TimeInterval = 15
    /// How long a ready item with audio but no video track is held before `.videoUnsupported`. Healthy
    /// streams list their video track by `readyToPlay` (measured: 0.2 s local, ~1 s before ready on IPTV HLS).
    static let videoGracePeriod: TimeInterval = 1.5

    let name = "AVFoundation"
    /// Exposed for AirPlay (`AVRoutePickerView.player`) and diagnostics. Drive playback through the
    /// `PlaybackEngine` methods so the engine's state stays consistent.
    let player: AVPlayer
    var view: NSView { videoView }
    var onEvent: ((EngineEvent) -> Void)?
    /// Called on the main thread when Picture in Picture starts (`true`) or stops (`false`).
    var onPictureInPictureChanged: ((Bool) -> Void)?
    /// Called on the main thread when AirPlay video starts (`true`) or stops (`false`).
    var onExternalPlaybackChanged: ((Bool) -> Void)?
    /// Video is currently being sent to an AirPlay device (the local layer shows nothing).
    var isExternalPlaybackActive: Bool { player.isExternalPlaybackActive }

    var isPictureInPictureActive: Bool { pipController?.isPictureInPictureActive ?? false }
    /// True once the player layer is in a window and has video to show.
    var isPictureInPicturePossible: Bool { pipController?.isPictureInPicturePossible ?? false }

    private let videoView: AVPlayerHostView
    private var pipController: AVPictureInPictureController?
    private var playerStatusObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private nonisolated static let log = Logger(subsystem: "app.tuner.macos", category: "AVEngine")

    // MARK: Per-item state (reset by `teardownItem`)

    /// Bumped on every load/stop/failure; callbacks carrying an older value are ignored.
    private var generation = 0
    private var item: AVPlayerItem?
    private var stream: PlayableStream?
    private var itemObservations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var timeoutWork: DispatchWorkItem?
    /// Pending "is there video?" decision: the item is ready with audio but no video track (see `awaitVideo`).
    private var videoCheckWork: DispatchWorkItem?
    private var didLoad = false
    private var reachedEnd = false
    /// Resume position applied once the item is ready.
    private var pendingStartAt: Double?
    /// Playback start is held back until the initial resume seek lands (avoids a flash of the start).
    private var deferredPlay = false
    /// Target of the in-flight seek; reported as the position and used as the base for `seek(by:)`.
    private var seekTarget: Double?
    private var seekSerial = 0
    private var mediaInfo = MediaInfo()
    private var frameRateSamples: [Double] = []
    private var mediaInfoTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?

    // MARK: User intent (survives item changes, except `userPaused` which `load` resets)

    private var userPaused = false
    private var rate: Float = 1

    override init() {
        player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
        player.appliesMediaSelectionCriteriaAutomatically = true
        // AirPlay: allow sending video to Apple TVs / AirPlay displays (picked via AVRoutePickerView).
        player.allowsExternalPlayback = true
        videoView = AVPlayerHostView(player: player)
        super.init()

        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Self.onMain { self?.onExternalPlaybackChanged?(active) }
        }

        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: videoView.playerLayer) {
            pip.delegate = self
            pipController = pip
            #if os(iOS)
            // Swiping home while full screen moves the video into Picture in Picture (the system decides when).
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            #endif
        }
        #if os(iOS)
        // In the background without PiP the host view detaches the layer so audio keeps playing.
        videoView.isPictureInPictureActive = { [weak self] in self?.isPictureInPictureActive ?? false }
        #endif
        // A failed AVPlayer (e.g. media services reset) cannot be reused for further items.
        playerStatusObservation = player.observe(\.status, options: [.new]) { [weak self] player, _ in
            guard player.status == .failed else { return }
            let error = player.error
            Self.onMain {
                guard let self else { return }
                self.fail(self.generation, error: error)
            }
        }
    }

    // MARK: - PlaybackEngine

    /// Starts playback (resets any earlier `setPaused(true)`); `startAt` > 0 seeks there before
    /// the first frame is shown.
    func load(_ stream: PlayableStream, startAt: Double?) {
        teardownItem()
        generation &+= 1
        let gen = generation

        userPaused = false
        if let startAt, startAt.isFinite, startAt > 0 {
            pendingStartAt = startAt
            deferredPlay = true
        }

        var options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": stream.headers,
            AVURLAssetHTTPUserAgentKey: stream.userAgent,
        ]
        // IPTV panels often serve playlists as text/plain or application/octet-stream, which
        // AVFoundation would otherwise refuse to treat as HLS.
        if stream.url.pathExtension.lowercased() == "m3u8" {
            options[AVURLAssetOverrideMIMETypeKey] = "application/vnd.apple.mpegurl"
        }
        let asset = AVURLAsset(url: stream.url, options: options)
        let item = AVPlayerItem(asset: asset)
        self.stream = stream
        if stream.kind == .live {
            // A few segments of headroom against jittery IPTV origins (stall waiting is on, see init).
            item.preferredForwardBufferDuration = 8
        }
        self.item = item

        observe(item, gen: gen)
        scheduleTimeout(gen: gen)
        player.replaceCurrentItem(with: item)
        player.defaultRate = rate
        if !deferredPlay {
            player.play()
        }
    }

    func stop() {
        generation &+= 1
        teardownItem()
    }

    func setPaused(_ paused: Bool) {
        userPaused = paused
        if paused {
            player.pause()
        } else if item != nil, !deferredPlay, videoCheckWork == nil {
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, let item else { return }
        guard didLoad else {
            // Not ready yet: becomes (or replaces) the resume position.
            pendingStartAt = max(0, seconds)
            deferredPlay = true
            player.pause()
            return
        }
        performSeek(to: seconds, item: item)
    }

    func seek(by delta: Double) {
        guard delta.isFinite, let item, didLoad else { return }
        let base = seekTarget ?? player.currentTime().seconds
        guard base.isFinite else { return }
        performSeek(to: base + delta, item: item)
    }

    /// `AVPlayer.volume` is linear amplitude, so most of the audible change would crowd into the bottom of the
    /// slider. mpv applies a cubic curve to its `volume` property (its 130 % maximum is "about double the normal
    /// level"); using the same curve here makes a given slider position sound the same in both engines.
    func setVolume(_ volume: Double) {
        let level = min(max(volume / 100, 0), 1)
        player.volume = Float(level * level * level)
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func setRate(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        self.rate = Float(rate)
        player.defaultRate = self.rate
        if player.rate != 0 {
            player.rate = self.rate
        }
    }

    func setAspect(_ aspect: VideoAspect) {
        videoView.setAspect(aspect)
    }

    func snapshot() -> EngineSnapshot {
        var s = EngineSnapshot()
        guard let item = player.currentItem, item === self.item else {
            s.isIdle = true
            s.isPaused = userPaused
            return s
        }

        let now = player.currentTime().seconds
        let current: Double? = now.isFinite ? now : nil
        s.position = seekTarget ?? current

        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { s.duration = duration }

        let status = player.timeControlStatus
        if deferredPlay {
            s.isPaused = userPaused
            s.isBuffering = !userPaused
        } else {
            s.isPaused = player.rate == 0 && status == .paused
            s.isBuffering = status == .waitingToPlayAtSpecifiedRate
        }
        s.reachedEnd = reachedEnd

        if let current {
            for value in item.loadedTimeRanges {
                let range = value.timeRangeValue
                let start = range.start.seconds, end = range.end.seconds
                guard start.isFinite, end.isFinite else { continue }
                if current >= start - 0.5, current <= end + 0.5 {
                    s.bufferedEnd = end
                    s.bufferedSeconds = max(0, end - current)
                    break
                }
            }
        }

        let size = item.presentationSize
        if size.width > 0, size.height > 0 { s.videoSize = size }
        s.videoCodec = mediaInfo.videoCodec
        s.audioCodec = mediaInfo.audioCodec
        s.fps = mediaInfo.fps ?? sampledFrameRate(status: status)

        var videoBitrate = mediaInfo.videoBitrate
        var audioBitrate = mediaInfo.audioBitrate
        if let events = item.accessLog()?.events, let last = events.last {
            if last.averageVideoBitrate > 0 {
                videoBitrate = last.averageVideoBitrate
            } else if last.indicatedBitrate > 0 {
                videoBitrate = last.indicatedBitrate
            } else if videoBitrate == nil, last.observedBitrate > 0 {
                videoBitrate = last.observedBitrate
            }
            if last.averageAudioBitrate > 0 { audioBitrate = last.averageAudioBitrate }
            var dropped = 0, known = false
            for event in events where event.numberOfDroppedVideoFrames >= 0 {
                dropped += event.numberOfDroppedVideoFrames
                known = true
            }
            if known { s.droppedFrames = dropped }
        }
        s.videoBitrate = videoBitrate
        s.audioBitrate = audioBitrate

        s.isSeekable = item.seekableTimeRanges.contains { $0.timeRangeValue.duration.seconds > 0 }
        if s.videoCodec != nil || s.videoSize != nil { s.hardwareDecoder = "VideoToolbox" }
        return s
    }

    func audioTracks() -> [MediaTrack] {
        guard let item else { return [] }
        if let group = audioGroup {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            return group.options.enumerated().map { index, option in
                Self.track(index, option, selected: option == selected)
            }
        }
        // No alternate-group metadata (typical single-language MP4): list the raw audio tracks.
        return mediaInfo.audioTracks.enumerated().map { index, entry in
            MediaTrack(id: index, title: entry.title, language: entry.language, codec: entry.codec,
                       isSelected: entry.track.isEnabled)
        }
    }

    func subtitleTracks() -> [MediaTrack] {
        guard let item, let group = legibleGroup else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { index, option in
            Self.track(index, option, selected: option == selected)
        }
    }

    func selectAudioTrack(_ id: Int) {
        guard let item else { return }
        if let group = audioGroup {
            guard group.options.indices.contains(id) else { return }
            item.select(group.options[id], in: group)
        } else if mediaInfo.audioTracks.indices.contains(id) {
            for (index, entry) in mediaInfo.audioTracks.enumerated() {
                entry.track.isEnabled = index == id
            }
        }
    }

    func selectSubtitleTrack(_ id: Int?) {
        guard let item, let group = legibleGroup else { return }
        if let id {
            guard group.options.indices.contains(id) else { return }
            item.select(group.options[id], in: group)
        } else if group.allowsEmptySelection {
            item.select(nil, in: group)
        }
    }

    func shutdown() {
        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        stop()
    }

    // MARK: - Picture in Picture

    func togglePictureInPicture() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    // MARK: - Item lifecycle

    private func observe(_ item: AVPlayerItem, gen: Int) {
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Self.onMain { self?.itemStatusChanged(gen: gen) }
            },
            item.observe(\.tracks, options: [.new]) { [weak self] _, _ in
                Self.onMain { self?.tracksChanged(gen: gen) }
            },
        ]
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil) { [weak self] _ in
                Self.onMain { self?.didPlayToEnd(gen: gen) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Self.onMain { self?.fail(gen, error: error) }
            },
        ]
    }

    private func teardownItem() {
        timeoutWork?.cancel()
        timeoutWork = nil
        videoCheckWork?.cancel()
        videoCheckWork = nil
        itemObservations.forEach { $0.invalidate() }
        itemObservations = []
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens = []
        mediaInfoTask?.cancel()
        mediaInfoTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        if let item {
            item.cancelPendingSeeks()
            item.asset.cancelLoading()
        }
        item = nil
        stream = nil
        audioGroup = nil
        legibleGroup = nil
        mediaInfo = MediaInfo()
        frameRateSamples = []
        didLoad = false
        reachedEnd = false
        pendingStartAt = nil
        deferredPlay = false
        seekTarget = nil
        if player.currentItem != nil {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private func scheduleTimeout(gen: Int) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, !self.didLoad else { return }
                self.fail(gen, error: nil, timedOut: true)
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: work)
    }

    private func itemStatusChanged(gen: Int) {
        guard gen == generation, let item else { return }
        switch item.status {
        case .readyToPlay:
            guard !didLoad else { return }
            if videoMissing(item) {
                if videoCheckWork == nil { awaitVideo(gen: gen) }
                return
            }
            finishLoading(item, gen: gen)
        case .failed:
            fail(gen, error: item.error)
        default:
            break
        }
    }

    private func finishLoading(_ item: AVPlayerItem, gen: Int) {
        let wasHeld = videoCheckWork != nil
        videoCheckWork?.cancel()
        videoCheckWork = nil
        didLoad = true
        timeoutWork?.cancel()
        timeoutWork = nil
        loadMediaSelection(gen: gen)
        refreshMediaInfo(gen: gen)
        if let start = pendingStartAt {
            pendingStartAt = nil
            performSeek(to: start, item: item)
        } else if deferredPlay {
            deferredPlay = false
            if !userPaused { player.play() }
        } else if wasHeld, !userPaused {
            player.play()
        }
        emit(.loaded)
    }

    /// Ready, playing audio, but no video track: AVFoundation drops video it can't decode without an error
    /// (HEVC in MPEG-TS HLS segments is common on IPTV panels), which looks like a black screen with sound.
    /// Audio-only media (by extension) and items without any tracks yet aren't judged.
    private func videoMissing(_ item: AVPlayerItem) -> Bool {
        let audioOnlyExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"]
        if let ext = stream?.url.pathExtension.lowercased(), audioOnlyExtensions.contains(ext) { return false }
        let types = item.tracks.compactMap { $0.assetTrack?.mediaType }
        return types.contains(.audio) && !types.contains(.video)
    }

    /// Holds playback for `videoGracePeriod` waiting for a video track (`tracksChanged` ends the wait early),
    /// then reports `.videoUnsupported` and — unless the receiver moved on — continues audio-only.
    private func awaitVideo(gen: Int) {
        player.pause() // no burst of audio-only playback if the slot switches engines
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, let item = self.item, !self.didLoad else { return }
                guard self.videoMissing(item) else {
                    self.finishLoading(item, gen: gen)
                    return
                }
                Self.log.notice("No decodable video in \(self.stream?.url.lastPathComponent ?? "?", privacy: .public); reporting videoUnsupported")
                self.emit(.videoUnsupported)
                // The receiver may have stopped or replaced the item (engine switch).
                guard gen == self.generation, let current = self.item else { return }
                self.finishLoading(current, gen: gen)
            }
        }
        videoCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.videoGracePeriod, execute: work)
    }

    private func tracksChanged(gen: Int) {
        guard gen == generation else { return }
        guard didLoad else {
            // Waiting for video and it just appeared: start now.
            if videoCheckWork != nil, let item, !videoMissing(item) { finishLoading(item, gen: gen) }
            return
        }
        refreshMediaInfo(gen: gen)
    }

    private func didPlayToEnd(gen: Int) {
        guard gen == generation else { return }
        reachedEnd = true
        emit(.ended)
    }

    /// Tears the item down (so nothing keeps playing behind the fallback engine) and reports the error.
    private func fail(_ gen: Int, error: Error?, timedOut: Bool = false) {
        guard gen == generation, item != nil else { return }
        let errorLog = item?.errorLog()
        // A continuous raw stream (live `.ts`) reaches AVFoundation as a progressive download the server
        // can't serve by byte range; that's a format limitation from the user's point of view.
        let continuous = stream.map { $0.kind == .live || $0.url.pathExtension.lowercased() == "ts" } ?? false
        var failure = Self.describe(error, errorLog: errorLog, continuousStream: continuous)
        if timedOut, failure.httpStatus == nil {
            failure = Failure(message: "Timed out", httpStatus: nil)
        }
        if let error {
            Self.log.error("Playback failed: \(String(describing: error), privacy: .public)")
        } else {
            Self.log.error("Playback failed: \(failure.message, privacy: .public)")
        }

        generation &+= 1
        teardownItem()
        let failedGen = generation
        if let status = failure.httpStatus {
            emit(.httpError(status))
            // The handler may already have moved on (load/stop); don't report a stale failure.
            guard failedGen == generation else { return }
        }
        emit(.failed(failure.message))
    }

    private func emit(_ event: EngineEvent) {
        onEvent?(event)
    }

    // MARK: - Seeking

    private func performSeek(to seconds: Double, item: AVPlayerItem) {
        let target = clampedSeekTarget(seconds, item: item)
        seekSerial &+= 1
        let serial = seekSerial, gen = generation
        let resumeAfter = reachedEnd && !userPaused
        seekTarget = target
        reachedEnd = false
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 1000)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1000),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Self.onMain { self?.seekFinished(serial: serial, gen: gen, resume: resumeAfter) }
        }
    }

    private func seekFinished(serial: Int, gen: Int, resume: Bool) {
        guard gen == generation, serial == seekSerial else { return }
        seekTarget = nil
        if deferredPlay {
            deferredPlay = false
            if !userPaused { player.play() }
        } else if resume, !userPaused {
            player.play()
        }
    }

    private func clampedSeekTarget(_ seconds: Double, item: AVPlayerItem) -> Double {
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        if let first = ranges.first, let last = ranges.last {
            let lower = first.start.seconds, upper = last.end.seconds
            if lower.isFinite, upper.isFinite, upper > lower {
                return min(max(seconds, lower), upper)
            }
        }
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { return min(max(seconds, 0), duration) }
        return max(seconds, 0)
    }

    // MARK: - Tracks and media info

    private func loadMediaSelection(gen: Int) {
        guard let asset = item?.asset else { return }
        selectionTask = Task { [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, gen == self.generation else { return }
            self.audioGroup = audible
            self.legibleGroup = legible
        }
    }

    /// Codec/frame-rate/bitrate details, loaded asynchronously and cached so `snapshot()` stays cheap.
    /// HLS assets expose no asset tracks; their details arrive through `AVPlayerItem.tracks` once
    /// segments are parsed, which re-runs this.
    private func refreshMediaInfo(gen: Int) {
        guard gen == generation, let item else { return }
        let itemTracks = item.tracks
        let asset = item.asset
        mediaInfoTask?.cancel()
        mediaInfoTask = Task { [weak self] in
            var pairs: [(AVPlayerItemTrack?, AVAssetTrack)] = itemTracks.compactMap { itemTrack in
                itemTrack.assetTrack.map { (itemTrack, $0) }
            }
            if pairs.isEmpty, let tracks = try? await asset.load(.tracks) {
                pairs = tracks.map { (nil, $0) }
            }
            var info = MediaInfo()
            for (itemTrack, track) in pairs {
                if Task.isCancelled { return }
                switch track.mediaType {
                case .video where info.videoCodec == nil:
                    guard let (descriptions, fps, minFrameDuration, dataRate) = try? await track.load(
                        .formatDescriptions, .nominalFrameRate, .minFrameDuration, .estimatedDataRate) else { continue }
                    info.videoCodec = descriptions.first.map { Self.codecName(CMFormatDescriptionGetMediaSubType($0)) }
                    if fps > 0 {
                        info.fps = Double(fps)
                    } else if minFrameDuration.isNumeric, minFrameDuration.seconds > 0 {
                        info.fps = Self.snapFrameRate(1 / minFrameDuration.seconds)
                    }
                    if dataRate > 0 { info.videoBitrate = Double(dataRate) }
                case .audio:
                    guard let (descriptions, dataRate, languageCode, languageTag) = try? await track.load(
                        .formatDescriptions, .estimatedDataRate, .languageCode, .extendedLanguageTag) else { continue }
                    let codec = descriptions.first.map { Self.codecName(CMFormatDescriptionGetMediaSubType($0)) }
                    if info.audioCodec == nil {
                        info.audioCodec = codec
                        if dataRate > 0 { info.audioBitrate = Double(dataRate) }
                    }
                    if let itemTrack {
                        let language = Self.normalizedLanguage(code: languageCode, tag: languageTag)
                        let index = info.audioTracks.count
                        info.audioTracks.append(.init(track: itemTrack, title: language == nil ? "Track \(index + 1)" : "",
                                                      language: language, codec: codec))
                    }
                default:
                    break
                }
            }
            // HLS: tracks carry no frame rate, but a master playlist's FRAME-RATE/CODECS attributes may.
            if info.fps == nil || info.videoCodec == nil, let urlAsset = asset as? AVURLAsset,
               let variants = try? await urlAsset.load(.variants) {
                let video = variants.compactMap(\.videoAttributes)
                let rates = Set(video.compactMap(\.nominalFrameRate).filter { $0 > 0 })
                if info.fps == nil, rates.count == 1 { info.fps = rates.first }
                let codecs = Set(video.flatMap(\.codecTypes))
                if info.videoCodec == nil, codecs.count == 1, let codec = codecs.first {
                    info.videoCodec = Self.codecName(codec)
                }
            }
            guard let self, gen == self.generation, !Task.isCancelled else { return }
            // Keep earlier details if this pass saw fewer tracks (HLS track lists churn while switching).
            if info.videoCodec == nil, info.audioCodec == nil, !pairs.isEmpty { return }
            if info.videoCodec == nil { info.videoCodec = self.mediaInfo.videoCodec }
            if info.fps == nil { info.fps = self.mediaInfo.fps }
            if info.audioCodec == nil { info.audioCodec = self.mediaInfo.audioCodec }
            info.videoItemTrack = itemTracks.first { $0.assetTrack?.mediaType == .video }
            self.mediaInfo = info
        }
    }

    /// Frame rate from the rendered-frame counter, for streams that declare none (plain HLS media
    /// playlists). Samples only during steady 1x playback and reports the median snapped to a
    /// standard rate, since single readings swing widely (and collapse while the window is hidden).
    private func sampledFrameRate(status: AVPlayer.TimeControlStatus) -> Double? {
        if status == .playing, player.rate == 1, let track = mediaInfo.videoItemTrack {
            let current = Double(track.currentVideoFrameRate)
            if current > 0 {
                frameRateSamples.append(current)
                if frameRateSamples.count > 9 { frameRateSamples.removeFirst() }
            }
        }
        guard frameRateSamples.count >= 3 else { return nil }
        let median = frameRateSamples.sorted()[frameRateSamples.count / 2]
        let fps = Self.snapFrameRate(median)
        // Settle on the value once there are enough samples; later seeks/stalls disturb the counter.
        if frameRateSamples.count >= 6, let fps { mediaInfo.fps = fps }
        return fps
    }

    /// Snaps to the nearest common broadcast/film rate; nil when nothing is close.
    nonisolated static func snapFrameRate(_ fps: Double) -> Double? {
        let standard: [Double] = [12.5, 15, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 119.88, 120]
        guard fps.isFinite, fps > 0, let nearest = standard.min(by: { abs($0 - fps) < abs($1 - fps) }) else { return nil }
        return abs(nearest - fps) <= nearest * 0.04 ? nearest : nil
    }

    private static func track(_ index: Int, _ option: AVMediaSelectionOption, selected: Bool) -> MediaTrack {
        let codec = option.mediaSubTypes.first.map { codecName(FourCharCode(truncating: $0)) }
        let language = normalizedLanguage(code: option.locale?.language.languageCode?.identifier,
                                          tag: option.extendedLanguageTag)
        var title = option.displayName
        // displayName is often just the localized language name; leave that to `MediaTrack.label`
        // (which appends the language) so it isn't shown twice.
        if let language, let languageName = Locale.current.localizedString(forLanguageCode: language),
           title.caseInsensitiveCompare(languageName) == .orderedSame {
            title = ""
        }
        if title.isEmpty, language == nil { title = "Track \(index + 1)" }
        return MediaTrack(id: index, title: title, language: language, codec: codec, isSelected: selected)
    }

    private nonisolated static func normalizedLanguage(code: String?, tag: String?) -> String? {
        for candidate in [code, tag] {
            if let value = candidate?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
               value.lowercased() != "und" {
                return value
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Always hops asynchronously, so engine callbacks never re-enter AVFoundation's notification/KVO path.
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }

    /// Maps a FourCC media subtype to the short codec names mpv/ffmpeg use.
    nonisolated static func codecName(_ fourCC: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((fourCC >> $0) & 0xFF) }
        let raw = String(bytes: bytes, encoding: .macOSRoman) ?? String(fourCC)
        switch raw {
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1", "dvh1", "dvhe": return "hevc"
        case "av01": return "av1"
        case "vp09": return "vp9"
        case "vp08": return "vp8"
        case "mp4v": return "mpeg4"
        case "mp2v", "mpeg": return "mpeg2video"
        case "jpeg", "mjpa", "mjpb": return "mjpeg"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": return "prores"
        case "aac ", "mp4a": return "aac"
        case "aach", "aacp": return "he-aac"
        case "aacl", "aace", "aacf": return "aac"
        case ".mp3": return "mp3"
        case ".mp2", ".mp1": return "mp2"
        case "ac-3": return "ac3"
        case "ec-3": return "eac3"
        case "ac-4": return "ac4"
        case "opus": return "opus"
        case "fLaC", "flac": return "flac"
        case "alac": return "alac"
        case "lpcm": return "pcm"
        case "c608": return "eia_608"
        case "c708": return "eia_708"
        case "wvtt": return "webvtt"
        case "tx3g": return "mov_text"
        default: return raw.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Error mapping

extension AVEngine {
    struct Failure: Equatable {
        var message: String
        var httpStatus: Int?
    }

    /// Turns an AVFoundation/CoreMedia/URL error (plus the item's error log) into a user-facing message,
    /// extracting the HTTP status when one can be determined.
    nonisolated static func describe(_ error: Error?, errorLog: AVPlayerItemErrorLog?,
                                     continuousStream: Bool = false) -> Failure {
        let chain = errorChain(error)
        let events = Array((errorLog?.events ?? []).reversed())

        if let status = httpStatus(chain: chain, events: events) {
            return Failure(message: httpMessage(status), httpStatus: status)
        }
        if let urlError = chain.first(where: { $0.domain == NSURLErrorDomain }) {
            // CoreMedia reports a response it can't parse as a playlist (an HTML error page,
            // an expired-subscription notice, …) as "unsupported URL".
            if urlError.code == NSURLErrorUnsupportedURL, chain.contains(where: { $0.domain == "CoreMediaErrorDomain" }) {
                return Failure(message: "The server didn't return a playable stream", httpStatus: nil)
            }
            return Failure(message: networkMessage(urlError.code), httpStatus: nil)
        }
        let noByteRanges = chain.contains {
            $0.domain == AVFoundationErrorDomain && $0.code == AVError.Code.serverIncorrectlyConfigured.rawValue
        }
        if chain.contains(where: isUnsupportedFormat) || (noByteRanges && continuousStream) {
            return Failure(message: "This stream format isn't supported by AVFoundation", httpStatus: nil)
        }
        if noByteRanges {
            return Failure(message: "The server doesn't support streaming this file to AVFoundation (no byte-range requests)",
                           httpStatus: nil)
        }
        let protectedCodes = [AVError.Code.contentIsProtected, .contentIsNotAuthorized, .applicationIsNotAuthorized]
            .map(\.rawValue)
        if chain.contains(where: { $0.domain == AVFoundationErrorDomain && protectedCodes.contains($0.code) }) {
            return Failure(message: "This stream is protected and can't be played", httpStatus: nil)
        }
        if let event = events.first(where: { $0.errorDomain == NSURLErrorDomain }) {
            return Failure(message: networkMessage(event.errorStatusCode), httpStatus: nil)
        }
        if let comment = events.first?.errorComment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            return Failure(message: "Playback failed: \(comment)", httpStatus: nil)
        }
        if let error {
            let ns = error as NSError
            var text = ns.localizedDescription
            if let reason = ns.localizedFailureReason, !reason.isEmpty, !text.contains(reason) { text += " — \(reason)" }
            return Failure(message: text.isEmpty ? "Playback failed" : text, httpStatus: nil)
        }
        return Failure(message: "Playback failed", httpStatus: nil)
    }

    /// The error plus its underlying errors (breadth-first, bounded).
    private nonisolated static func errorChain(_ error: Error?) -> [NSError] {
        guard let error else { return [] }
        var result: [NSError] = []
        var queue: [NSError] = [error as NSError]
        while !queue.isEmpty, result.count < 16 {
            let next = queue.removeFirst()
            result.append(next)
            if let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError { queue.append(underlying) }
            if let many = next.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { queue.append(contentsOf: many) }
        }
        return result
    }

    private nonisolated static func httpStatus(chain: [NSError], events: [AVPlayerItemErrorLogEvent]) -> Int? {
        for event in events {
            if (400...599).contains(event.errorStatusCode) { return event.errorStatusCode }
            if let status = mediaErrorStatus(event.errorStatusCode, domain: event.errorDomain) { return status }
            if let status = parseHTTPStatus(event.errorComment) { return status }
        }
        for error in chain {
            if let status = mediaErrorStatus(error.code, domain: error.domain) { return status }
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorUserAuthenticationRequired { return 401 }
            let texts = [
                error.localizedDescription,
                error.localizedFailureReason,
                error.userInfo["NSDescription"] as? String,
                error.userInfo[NSDebugDescriptionErrorKey] as? String,
            ]
            for text in texts {
                if let status = parseHTTPStatus(text) { return status }
            }
        }
        return nil
    }

    /// CoreMedia's HTTP-derived OSStatus codes.
    private nonisolated static func mediaErrorStatus(_ code: Int, domain: String) -> Int? {
        guard domain == "CoreMediaErrorDomain" || domain == NSOSStatusErrorDomain || domain == AVFoundationErrorDomain else {
            return nil
        }
        switch code {
        case -12938: return 404
        case -12660: return 403
        default: return nil
        }
    }

    private nonisolated static func parseHTTPStatus(_ text: String?) -> Int? {
        guard let text, let range = text.range(of: #"HTTP(?:/\d(?:\.\d)?)?\s*(?:status\s*)?(?:code\s*)?:?\s*([45]\d\d)\b"#,
                                                options: [.regularExpression, .caseInsensitive]) else { return nil }
        let digits = text[range].suffix(3)
        guard let status = Int(digits), (400...599).contains(status) else { return nil }
        return status
    }

    private nonisolated static func isUnsupportedFormat(_ error: NSError) -> Bool {
        switch error.domain {
        case AVFoundationErrorDomain:
            let codes: [AVError.Code] = [
                .fileFormatNotRecognized, .fileFailedToParse, .failedToParse, .decoderNotFound,
                .operationNotSupportedForAsset, .formatUnsupported, .undecodableMediaData,
                .incompatibleAsset, .decodeFailed,
            ]
            return codes.map(\.rawValue).contains(error.code)
        case "CoreMediaErrorDomain", NSOSStatusErrorDomain:
            // -12847/-12848: unsupported/unparseable media; -12642: unparseable playlist;
            // -12906/-12910: no VideoToolbox decoder / unsupported data format;
            // 'typ?' / 'fmt?': AudioToolbox unsupported file type / data format.
            return [-12847, -12848, -12642, -12906, -12910, 1_954_115_647, 1_718_449_215].contains(error.code)
        default:
            return false
        }
    }

    nonisolated static func httpMessage(_ status: Int) -> String {
        switch status {
        case 401: "The server requires authentication (HTTP 401)"
        case 403: "Access denied by the server (HTTP 403)"
        case 404, 410: "Stream not found (HTTP \(status))"
        case 429: "Too many requests to the server (HTTP 429)"
        case 500...599: "Server error (HTTP \(status))"
        default: "The server returned HTTP \(status)"
        }
    }

    nonisolated static func networkMessage(_ code: Int) -> String {
        switch code {
        case NSURLErrorNotConnectedToInternet: "You're offline. Check your internet connection"
        case NSURLErrorTimedOut: "The server took too long to respond"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: "The server couldn't be found"
        case NSURLErrorCannotConnectToHost: "Couldn't connect to the server"
        case NSURLErrorNetworkConnectionLost: "The network connection was lost"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            "A secure connection to the server couldn't be made"
        case NSURLErrorBadServerResponse, NSURLErrorZeroByteResource, NSURLErrorCannotParseResponse:
            "The server sent an invalid response"
        case NSURLErrorResourceUnavailable, NSURLErrorFileDoesNotExist: "Stream not found"
        case NSURLErrorNoPermissionsToReadFile: "Access denied by the server"
        case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: "The server requires authentication"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: "Plain-HTTP streams are blocked by App Transport Security"
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL: "The stream URL is invalid"
        case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation: "The server redirected too many times"
        default: "Network error (\(code))"
        }
    }
}

// MARK: - Picture in Picture delegate

extension AVEngine: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Self.onMain { [weak self] in self?.onPictureInPictureChanged?(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Self.onMain { [weak self] in self?.onPictureInPictureChanged?(false) }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        Self.log.error("Picture in Picture failed to start: \(String(describing: error), privacy: .public)")
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - Cached media details

private struct MediaInfo {
    struct AudioTrack {
        var track: AVPlayerItemTrack
        var title: String
        var language: String?
        var codec: String?
    }

    var videoCodec: String?
    var audioCodec: String?
    var fps: Double?
    var videoBitrate: Double?
    var audioBitrate: Double?
    /// For `currentVideoFrameRate` when the asset track reports no nominal rate (common with HLS).
    var videoItemTrack: AVPlayerItemTrack?
    /// Raw audio tracks, used for track selection when the asset has no audible selection group.
    var audioTracks: [AudioTrack] = []
}

// MARK: - Video view

#if os(macOS)
// (iOS: iOS/Sources/Player/AVPlayerHostView.swift)
/// Layer-backed view hosting the `AVPlayerLayer`; black letterboxing, no AVKit controls.
final class AVPlayerHostView: NSView {
    let playerLayer: AVPlayerLayer
    /// Width/height ratio forced by the 16:9 / 4:3 aspect modes (video stretched into that box).
    private var forcedAspectRatio: CGFloat?

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPlayerLayer()
    }

    override func layout() {
        super.layout()
        layoutPlayerLayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        playerLayer.contentsScale = scale
    }

    func setAspect(_ aspect: VideoAspect) {
        switch aspect {
        case .fit:
            forcedAspectRatio = nil
            playerLayer.videoGravity = .resizeAspect
        case .fill:
            forcedAspectRatio = nil
            playerLayer.videoGravity = .resizeAspectFill
        case .stretch:
            forcedAspectRatio = nil
            playerLayer.videoGravity = .resize
        case .ratio16x9:
            forcedAspectRatio = 16.0 / 9.0
            playerLayer.videoGravity = .resize
        case .ratio4x3:
            forcedAspectRatio = 4.0 / 3.0
            playerLayer.videoGravity = .resize
        }
        layoutPlayerLayer()
    }

    private func layoutPlayerLayer() {
        var frame = bounds
        if let ratio = forcedAspectRatio, bounds.width > 0, bounds.height > 0 {
            frame = AVMakeRect(aspectRatio: CGSize(width: ratio, height: 1), insideRect: bounds).integral
        }
        guard playerLayer.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = frame
        CATransaction.commit()
    }
}
#endif
