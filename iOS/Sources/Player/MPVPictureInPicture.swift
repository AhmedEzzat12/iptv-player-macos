import AVFoundation
import AVKit
import CoreMedia
import os
import UIKit

/// The system Picture in Picture window for mpv's video (iPhone/iPad, Settings → Playback → "Picture in Picture for
/// all videos"). mpv draws into `MPVVideoView`'s sample-buffer layer; this hands that layer to AVKit and answers the
/// window's play/pause and skip buttons through `PlayerSlot` (`PictureInPictureControls`). Like AVFoundation's PiP it
/// can start by itself when the app goes to the background while a video plays.
@MainActor
final class MPVPictureInPicture: NSObject {
    private static let log = Logger(subsystem: "app.tuner.macos", category: "PiP")

    private let layer: AVSampleBufferDisplayLayer
    private let renderer: MPVRenderer
    private var controller: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private var ticker: Timer?

    var controls: PictureInPictureControls? {
        didSet { refreshState() }
    }
    var onChanged: ((Bool) -> Void)?

    // What AVKit asks for synchronously (possibly off the main thread): updated on the main thread.
    nonisolated(unsafe) private var paused = false
    nonisolated(unsafe) private var live = false
    nonisolated(unsafe) private var duration: Double?

    init(layer: AVSampleBufferDisplayLayer, renderer: MPVRenderer) {
        self.layer = layer
        self.renderer = renderer
        super.init()
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            layer.controlTimebase = timebase
            self.timebase = timebase
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        // The window's time and play state follow the player.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshState() }
        }
    }

    isolated deinit {
        ticker?.invalidate()
    }

    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }
    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    func stop() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }

    /// Pushes the player's state to the window: the play/pause button, the time range and where playback is.
    private func refreshState() {
        guard let controls else { return }
        let nowPaused = controls.isPaused()
        let nowLive = controls.isLive()
        let nowDuration = controls.duration()
        let changed = nowPaused != paused || nowLive != live || nowDuration != duration
        paused = nowPaused
        live = nowLive
        duration = nowDuration
        if let timebase {
            let position = controls.position() ?? 0
            CMTimebaseSetTime(timebase, time: CMTime(seconds: nowLive ? 0 : position, preferredTimescale: 600))
            CMTimebaseSetRate(timebase, rate: nowPaused ? 0 : 1)
        }
        if changed { controller?.invalidatePlaybackState() }
    }

    private func videoSize() -> CGSize? {
        controls?.videoSize()
    }
}

// MARK: - PiP window

extension MPVPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            // Frames in the video's own shape for the window (it letterboxes them itself).
            layer.videoGravity = .resizeAspect
            renderer.pictureInPictureChanged(active: true, videoSize: videoSize())
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onChanged?(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            layer.videoGravity = .resize
            renderer.pictureInPictureChanged(active: false, videoSize: nil)
            onChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        Self.log.error("Picture in Picture (mpv) failed to start: \(String(describing: error), privacy: .public)")
        MainActor.assumeIsolated {
            layer.videoGravity = .resize
            renderer.pictureInPictureChanged(active: false, videoSize: nil)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - The window's buttons

extension MPVPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.controls?.setPaused(!playing)
                self?.refreshState()
            }
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Live TV: an endless range, so the window shows it as live (no scrubber).
        guard !live, let duration, duration > 0 else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        paused
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.controls?.seekBy(skipInterval.seconds)
                self?.refreshState()
            }
            completionHandler()
        }
    }
}

// MARK: - Engine

/// mpv's PiP on iPhone/iPad, through `MPVVideoView` (nothing when the setting was off as the engine was made).
extension MPVEngine: PictureInPictureEngine {
    private var pictureInPicture: MPVPictureInPicture? { (view as? MPVVideoView)?.pictureInPicture }

    var isPictureInPicturePossible: Bool { pictureInPicture?.isPossible ?? false }
    var isPictureInPictureActive: Bool { pictureInPicture?.isActive ?? false }

    var onPictureInPictureChanged: ((Bool) -> Void)? {
        get { pictureInPicture?.onChanged }
        set { pictureInPicture?.onChanged = newValue }
    }

    func togglePictureInPicture() { pictureInPicture?.toggle() }

    func attachPictureInPictureControls(_ controls: PictureInPictureControls) {
        pictureInPicture?.controls = controls
    }
}
