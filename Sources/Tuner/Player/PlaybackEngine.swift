import AppKit
import TunerCore

struct MediaTrack: Identifiable, Hashable {
    var id: Int
    var title: String
    var language: String?
    var codec: String?
    var isSelected: Bool

    var label: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        if let language, !language.isEmpty, !title.localizedCaseInsensitiveContains(language) {
            parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        if parts.isEmpty { parts.append("Track \(id)") }
        if let codec, !codec.isEmpty { parts.append("(\(codec))") }
        return parts.joined(separator: " ")
    }
}

/// Point-in-time engine state, polled by `PlayerSlot` (every 0.5 s) for UI and the stall watchdog.
struct EngineSnapshot: Equatable {
    var position: Double?
    var duration: Double?
    var isPaused = false
    var isBuffering = false
    var isIdle = false
    var reachedEnd = false
    /// End of buffered media (seconds, same timeline as `position`); growth means data is arriving.
    var bufferedEnd: Double?
    var bufferedSeconds: Double?
    var videoSize: CGSize?
    var videoCodec: String?
    var audioCodec: String?
    var fps: Double?
    /// bits per second
    var videoBitrate: Double?
    var audioBitrate: Double?
    var hardwareDecoder: String?
    var droppedFrames: Int?
    var isSeekable = false
}

enum EngineEvent {
    /// Media opened and is ready (first frame may follow).
    case loaded
    /// Reached end of a finite stream (VOD/catchup).
    case ended
    /// Fatal load/playback error with a user-facing message.
    case failed(String)
    /// HTTP status error seen in the engine log (403/404/…).
    case httpError(Int)
    /// The media opened and its audio plays, but the engine can't decode the video (AVFoundation and
    /// HEVC in MPEG-TS HLS segments, `hev1`-tagged HEVC MP4…). Sent before `.loaded`; the receiver may stop
    /// the engine and switch, otherwise playback continues audio-only. Also what a radio stream looks like.
    case videoUnsupported
}

enum VideoAspect: String, CaseIterable, Identifiable {
    case fit, fill, stretch, ratio16x9, ratio4x3

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill (crop)"
        case .stretch: "Stretch"
        case .ratio16x9: "16:9"
        case .ratio4x3: "4:3"
        }
    }
}

/// A video engine that renders into an AppKit view. All methods are called on the main thread.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// "mpv" or "AVFoundation" (shown in the stats overlay).
    var name: String { get }
    /// The view the engine renders into; created once and reused for the engine's lifetime.
    var view: NSView { get }
    /// Delivered on the main thread.
    var onEvent: ((EngineEvent) -> Void)? { get set }

    /// Replaces the current media. `startAt` seeks once the media is loaded (resume).
    func load(_ stream: PlayableStream, startAt: Double?)
    func stop()
    func setPaused(_ paused: Bool)
    func seek(to seconds: Double)
    func seek(by delta: Double)
    /// 0...100
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
    func setRate(_ rate: Double)
    func setAspect(_ aspect: VideoAspect)
    func snapshot() -> EngineSnapshot
    func audioTracks() -> [MediaTrack]
    func subtitleTracks() -> [MediaTrack]
    func selectAudioTrack(_ id: Int)
    /// nil disables subtitles
    func selectSubtitleTrack(_ id: Int?)
    /// Releases native resources (app quit / engine switch).
    func shutdown()
}
