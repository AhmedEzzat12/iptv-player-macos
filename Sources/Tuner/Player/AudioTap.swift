import AVFoundation
import MediaToolbox
import TunerCore

/// An `MTAudioProcessingTap` that runs an `AudioEnhancementProcessor` on an AVPlayerItem audio track.
///
/// Works for file-based media (MP4/MOV/M4V, MP3/AAC, progressive HTTP). It doesn't for HLS: measured on macOS
/// 27.0.1, a tap bound to an HLS item's audio track is never prepared or called, and a tap without a track only
/// sees silence (MP4 control: called with the real samples). So `PlayerSlot` plays HLS in mpv while an
/// enhancement is on. The tap retains the processor until the tap itself is released.
enum AudioTap {
    static func make(processor: AudioEnhancementProcessor) -> MTAudioProcessingTap? {
        let info = Unmanaged.passRetained(processor).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: info,
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<AudioEnhancementProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                AudioTap.processor(tap).prepare(format: format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                AudioTap.processor(tap).process(buffers, frameCount: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            // `init`/`finalize` never ran: balance the retain here.
            Unmanaged<AudioEnhancementProcessor>.fromOpaque(info).release()
            return nil
        }
        return tap
    }

    private static func processor(_ tap: MTAudioProcessingTap) -> AudioEnhancementProcessor {
        Unmanaged<AudioEnhancementProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    /// HLS (by URL, the same test engine routing uses): AVFoundation can't tap its audio.
    static func isHLS(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains("m3u8")
    }
}
