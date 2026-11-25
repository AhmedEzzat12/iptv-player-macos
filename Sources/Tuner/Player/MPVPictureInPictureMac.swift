#if os(macOS)
import AVFoundation
import AppKit
import AVKit
import CoreMedia
import os

/// The system Picture in Picture window for mpv's video on the Mac (Settings → Playback → "Picture in Picture for all
/// videos"). While the window is open mpv draws into `MPVVideoView`'s sample-buffer layer instead of the screen layer;
/// this hands that layer to AVKit and answers the window's play/pause and skip buttons through `PlayerSlot`
/// (`PictureInPictureControls`). The iPhone/iPad version is iOS/Sources/Player/MPVPictureInPicture.swift.
///
/// On the Mac the PiP window mirrors the layer where it is, at the layer's own size in points: it doesn't scale it
/// (a layer the size of the player showed a zoomed-in corner). So while the window is open the layer follows the
/// window's size, read from the window list (the window belongs to the system's PIPAgent).
@MainActor
final class MPVPictureInPicture: NSObject {
    nonisolated private static let log = Logger(subsystem: "app.tuner.macos", category: "PiP")

    private let renderer: MPVRenderer
    private weak var layer: AVSampleBufferDisplayLayer?
    /// Puts the layer back at the video's size when the window closes (set by `MPVVideoView`).
    var restoreLayout: (() -> Void)?
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
        self.renderer = renderer
        self.layer = layer
        super.init()
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            layer.controlTimebase = timebase
            self.timebase = timebase
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
        // The window's time and play state follow the player; the layer follows the window's size.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshState()
                self?.followWindowSize()
            }
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
            // The first frame has to be in the layer as the window opens: AVKit takes its size from it.
            guard renderer.prepareForPictureInPicture() else {
                Self.log.error("Picture in Picture (mpv): no frame to show yet")
                return
            }
            controller.startPictureInPicture()
        }
    }

    /// While PiP is open: sizes the layer like the PiP window (the one closest to the layer's size, should another
    /// app have one open too).
    private func followWindowSize() {
        guard controller?.isPictureInPictureActive == true, let layer,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        let current = layer.bounds.size
        let sizes = windows.compactMap { window -> CGSize? in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.PIPAgent",
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 0, rect.height > 0 else { return nil }
            return rect.size
        }
        guard let size = sizes.min(by: { abs($0.width - current.width) + abs($0.height - current.height)
                                          < abs($1.width - current.width) + abs($1.height - current.height) }),
              size != current else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()
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
            CMTimebaseSetTime(timebase, time: CMTime(seconds: nowLive ? 0 : controls.position() ?? 0, preferredTimescale: 600))
            CMTimebaseSetRate(timebase, rate: nowPaused ? 0 : 1)
        }
        if changed { controller?.invalidatePlaybackState() }
    }
}

// MARK: - PiP window

extension MPVPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { renderer.pictureInPictureChanged(active: true) }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            followWindowSize()
            onChanged?(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            renderer.pictureInPictureChanged(active: false)
            restoreLayout?()
            onChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        Self.log.error("Picture in Picture (mpv) failed to start: \(String(describing: error), privacy: .public)")
        MainActor.assumeIsolated {
            renderer.pictureInPictureChanged(active: false)
            restoreLayout?()
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

/// mpv's PiP on the Mac, through `MPVVideoView` (nothing when the setting was off as the engine was made).
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
#endif
