import AVFoundation

/// iOS needs an explicit playback audio session for sound with the ringer switch off, background audio,
/// Picture in Picture and AirPlay. (macOS has no audio session.)
enum AudioSessionSetup {
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        } catch {
            NSLog("Tuner: audio session category failed: \(error)")
        }
    }

    /// Activated when playback starts (not at launch, so opening the app doesn't stop other audio).
    static func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("Tuner: audio session activation failed: \(error)")
        }
    }
}
