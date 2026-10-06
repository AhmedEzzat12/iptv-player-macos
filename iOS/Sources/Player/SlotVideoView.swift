import SwiftUI
import UIKit

/// iOS counterpart of Sources/Tuner/Player/SlotVideoView.swift: hosts a slot's engine view. The engine view
/// is created once per engine and only moved/resized, so playback never restarts when the player moves
/// between full screen, preview and mini. Corners and shadow are Core Animation properties.
struct SlotVideoView: View {
    let slot: PlayerSlot
    var cornerRadius: CGFloat = 0
    /// Floating presentation (mini player, picture-in-picture inset): casts a soft shadow.
    var isElevated = false

    var body: some View {
        // Reading `viewToken` makes SwiftUI re-run update when the slot switches engines.
        VideoContainerRepresentable(view: slot.activeView, token: slot.viewToken,
                                    cornerRadius: cornerRadius, isElevated: isElevated)
    }
}

private struct VideoContainerRepresentable: UIViewRepresentable {
    let view: UIView
    let token: Int
    let cornerRadius: CGFloat
    let isElevated: Bool

    func makeUIView(context: Context) -> VideoContainerView {
        let container = VideoContainerView()
        update(container)
        return container
    }

    func updateUIView(_ container: VideoContainerView, context: Context) {
        update(container)
    }

    private func update(_ container: VideoContainerView) {
        container.host(view)
        container.setCornerRadius(cornerRadius)
        container.setElevated(isElevated)
    }
}

/// Outer view casts the shadow (no masking); the inner clip view rounds and masks the video.
final class VideoContainerView: UIView {
    private let clip = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = false
        isUserInteractionEnabled = false // taps go to the SwiftUI gestures around the video
        clip.backgroundColor = .black
        clip.layer.cornerCurve = .continuous
        clip.frame = bounds
        clip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(clip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCornerRadius(_ radius: CGFloat) {
        guard clip.layer.cornerRadius != radius else { return }
        clip.layer.cornerRadius = radius
        clip.layer.masksToBounds = radius > 0
        layer.cornerRadius = radius // keeps the shadow path's shape in sync
    }

    func setElevated(_ elevated: Bool) {
        let opacity: Float = elevated ? 0.55 : 0
        guard layer.shadowOpacity != opacity else { return }
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: 10)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = layer.shadowOpacity > 0
            ? UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath : nil
    }

    /// The engine view this container should show. Ownership follows on-screen presence: SwiftUI can briefly
    /// keep an old container alive next to its replacement, and whichever was updated last would otherwise
    /// "steal" the engine view into an off-screen container.
    private weak var desiredView: UIView?
    private static let releasedNotification = Notification.Name("TunerVideoViewReleased")
    private var releaseObserver: NSObjectProtocol?

    func host(_ view: UIView) {
        desiredView = view
        claimIfOnScreen()
    }

    private func claimIfOnScreen() {
        guard window != nil, let view = desiredView, view.superview !== clip else { return }
        clip.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = clip.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clip.addSubview(view)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            claimIfOnScreen()
            if releaseObserver == nil {
                releaseObserver = NotificationCenter.default.addObserver(forName: Self.releasedNotification, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self, let released = note.object as? UIView, released === self.desiredView else { return }
                        self.claimIfOnScreen()
                    }
                }
            }
        } else {
            if let observer = releaseObserver {
                NotificationCenter.default.removeObserver(observer)
                releaseObserver = nil
            }
            // Leaving the window: hand the engine view back so an on-screen container can take it.
            if let view = desiredView, view.superview === clip {
                view.removeFromSuperview()
                NotificationCenter.default.post(name: Self.releasedNotification, object: view)
            }
        }
    }
}
