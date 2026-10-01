import AppKit
import SwiftUI

/// Hosts a slot's engine view. The engine view is created once per engine and only moved/resized,
/// so playback never restarts when the player moves between full window, preview and mini.
///
/// Corners and the drop shadow are done with Core Animation on the AppKit side. SwiftUI decorations
/// at the same rect (`.clipShape`, a `.shadow` on a backing shape) are composited above an embedded
/// AppKit view on macOS and black the video out.
struct SlotVideoView: View {
    let slot: PlayerSlot
    var cornerRadius: CGFloat = 0
    /// Floating presentation (mini player, PiP inset): casts a soft shadow.
    var isElevated = false

    var body: some View {
        // Reading `viewToken` makes SwiftUI re-run update when the slot switches engines.
        VideoContainerRepresentable(view: slot.activeView, token: slot.viewToken,
                                    cornerRadius: cornerRadius, isElevated: isElevated)
    }
}

private struct VideoContainerRepresentable: NSViewRepresentable {
    let view: NSView
    let token: Int
    let cornerRadius: CGFloat
    let isElevated: Bool

    func makeNSView(context: Context) -> VideoContainerView {
        let container = VideoContainerView()
        update(container)
        return container
    }

    func updateNSView(_ container: VideoContainerView, context: Context) {
        update(container)
    }

    private func update(_ container: VideoContainerView) {
        container.host(view)
        container.setCornerRadius(cornerRadius)
        container.setElevated(isElevated)
    }
}

/// Outer view casts the shadow (no masking); the inner clip view rounds and masks the video.
final class VideoContainerView: NSView {
    private let clip = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        clip.wantsLayer = true
        clip.layer?.backgroundColor = NSColor.black.cgColor
        clip.layer?.cornerCurve = .continuous
        clip.frame = bounds
        clip.autoresizingMask = [.width, .height]
        addSubview(clip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCornerRadius(_ radius: CGFloat) {
        guard let layer = clip.layer, layer.cornerRadius != radius else { return }
        layer.cornerRadius = radius
        layer.masksToBounds = radius > 0
        self.layer?.cornerRadius = radius // keeps the shadow path's shape in sync
    }

    func setElevated(_ elevated: Bool) {
        guard let layer else { return }
        let opacity: Float = elevated ? 0.55 : 0
        guard layer.shadowOpacity != opacity else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: -10) // AppKit layers are y-up
    }

    override func layout() {
        super.layout()
        if let layer, layer.shadowOpacity > 0 {
            layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: layer.cornerRadius, cornerHeight: layer.cornerRadius, transform: nil)
        }
    }

    /// The engine view this container should show. Ownership follows on-screen presence: SwiftUI can
    /// briefly keep an old container alive next to its replacement (e.g. while switching sections), and
    /// whichever was updated last would otherwise "steal" the engine view into an off-screen container.
    private weak var desiredView: NSView?
    private static let releasedNotification = Notification.Name("TunerVideoViewReleased")
    private var releaseObserver: NSObjectProtocol?

    func host(_ view: NSView) {
        desiredView = view
        claimIfOnScreen()
    }

    private func claimIfOnScreen() {
        guard window != nil, let view = desiredView, view.superview !== clip else { return }
        clip.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = clip.bounds
        view.autoresizingMask = [.width, .height]
        clip.addSubview(view)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            claimIfOnScreen()
            if releaseObserver == nil {
                releaseObserver = NotificationCenter.default.addObserver(forName: Self.releasedNotification, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self, let released = note.object as? NSView, released === self.desiredView else { return }
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

    // Let SwiftUI gestures (click/double-click on video) through.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
