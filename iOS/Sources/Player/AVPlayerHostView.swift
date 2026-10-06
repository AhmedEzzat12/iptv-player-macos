import AVFoundation
import UIKit

/// iOS counterpart of the macOS `AVPlayerHostView` (Sources/Tuner/Player/AVEngine.swift): a black view
/// hosting the `AVPlayerLayer`, no AVKit controls. Same API, so `AVEngine` is shared unchanged.
final class AVPlayerHostView: UIView {
    let playerLayer: AVPlayerLayer
    /// Set by `AVEngine`: while Picture in Picture runs, the layer must stay attached in the background.
    var isPictureInPictureActive: () -> Bool = { false }
    /// Width/height ratio forced by the 16:9 / 4:3 aspect modes (video stretched into that box).
    private var forcedAspectRatio: CGFloat?
    private let player: AVPlayer
    private var observers: [NSObjectProtocol] = []

    init(player: AVPlayer) {
        self.player = player
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        backgroundColor = .black
        isOpaque = true
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = bounds
        layer.addSublayer(playerLayer)
        observeAppState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// iOS pauses an AVPlayer whose layer is attached when the app goes to the background. Detaching the layer
    /// (unless Picture in Picture is showing it) keeps the audio playing; it's reattached on return.
    private func observeAppState() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPictureInPictureActive() else { return }
                self.playerLayer.player = nil
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playerLayer.player == nil else { return }
                self.playerLayer.player = self.player
            }
        })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPlayerLayer()
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
