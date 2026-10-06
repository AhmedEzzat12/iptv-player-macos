import AVFoundation
import AVKit
import SwiftUI
import UIKit

// iOS counterparts of the AppKit parts of Sources/Tuner/Views/Common/TrailerPlayer.swift. The YouTube trailer
// view (WKWebView) is shared through the `NSViewRepresentable` bridge in AppKitCompat.swift.

/// Direct video trailers (MP4/HLS links) in the system player, with its standard controls.
struct NativeTrailerView: UIViewRepresentable {
    let requestID: UUID
    let url: URL
    let playback: TrailerPlaybackController
    let onEnded: () -> Void
    let onFailure: (TrailerFailure) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TrailerVideoContainer {
        let coordinator = context.coordinator
        coordinator.onEnded = onEnded
        coordinator.onFailure = onFailure

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false

        let container = TrailerVideoContainer(content: controller.view)
        coordinator.observe(item, player: player, controller: controller)
        playback.attach(requestID, webView: nil, player: player, container: container)
        player.play()
        container.fadeIn()
        return container
    }

    func updateUIView(_ view: TrailerVideoContainer, context: Context) {
        context.coordinator.onEnded = onEnded
        context.coordinator.onFailure = onFailure
    }

    static func dismantleUIView(_ view: TrailerVideoContainer, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        var onEnded: (() -> Void)?
        var onFailure: ((TrailerFailure) -> Void)?
        private var player: AVPlayer?
        /// Retained here: its view is shown inside the container.
        private var controller: AVPlayerViewController?
        private var statusObservation: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?

        func observe(_ item: AVPlayerItem, player: AVPlayer, controller: AVPlayerViewController) {
            self.player = player
            self.controller = controller
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.player?.pause()
                    self.onFailure?(.unplayable)
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEnded?() }
            }
        }

        func tearDown() {
            onEnded = nil
            onFailure = nil
            statusObservation?.invalidate()
            statusObservation = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            controller?.player = nil
            controller = nil
            player = nil
        }
    }
}

/// Rounded black host for the trailer's video view; the fade is the clip view's alpha.
final class TrailerVideoContainer: UIView {
    static let cornerRadius: CGFloat = 14
    private let clip = UIView()

    init(content: UIView) {
        super.init(frame: .zero)
        clip.layer.cornerRadius = Self.cornerRadius
        clip.layer.cornerCurve = .continuous
        clip.layer.masksToBounds = true
        clip.backgroundColor = .black
        clip.alpha = 0
        clip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(clip)
        content.frame = clip.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clip.addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
    }

    func fadeIn() { fade(to: 1, duration: 0.3) }

    func fadeOut() { fade(to: 0, duration: 0.2) }

    private func fade(to alpha: CGFloat, duration: TimeInterval) {
        UIView.animate(withDuration: duration) { self.clip.alpha = alpha }
    }
}

/// macOS closes the trailer on Esc with a key monitor. On iOS the close button (and swipe) do it.
@MainActor
final class TrailerEscapeMonitor {
    func setEnabled(_ enabled: Bool, window: UIWindow?, onEscape: @escaping () -> Void) {}
}
