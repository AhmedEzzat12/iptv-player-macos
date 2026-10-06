import Foundation
import TunerCore

/// iOS stand-in for the macOS `AirPlayBridge` (Sources/Tuner/Player/AirPlayBridge.swift), which re-wraps
/// streams to HLS with an ffmpeg child process. iOS can't launch processes, so the bridge is never used
/// here: `PlayerSlot.canBridgeForAirPlay` is false because `RecordingService.ffmpegPath()` is nil.
/// AVFoundation streams still AirPlay natively. An in-process remuxer could replace this later.
final class AirPlayBridge {
    struct Session {
        let url: URL
        let offset: Double
    }

    enum BridgeError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "AirPlay for this format isn't available on iPhone or iPad yet. Use Screen Mirroring instead."
        }
    }

    static let copyableVideo: Set<String> = ["h264", "avc", "avc1", "hevc", "h265", "hvc1"]
    static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3"]

    var isRunning: Bool { false }

    func start(stream: PlayableStream, startAt: Double, isLive: Bool, videoCodec: String?, audioCodec: String?) async throws -> Session {
        throw BridgeError.unavailable
    }

    func generatedSeconds() -> Double { 0 }

    func stop() {}
}
