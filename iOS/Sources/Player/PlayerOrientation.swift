import UIKit

/// iPhone orientation, as in the YouTube and TV apps: the app is portrait while browsing; in the full-screen player
/// it's portrait or landscape ("full screen"), switched by turning the phone, the player's full-screen button, or
/// swiping (up: landscape, down: portrait). Closing the player returns to portrait.
///
/// Asking iOS to rotate isn't enough on its own: while the app allows every orientation, the next sensor reading
/// wins. So the allowed orientations (`mask`, returned by the app delegate) follow the player's choice.
/// iPad keeps every orientation.
@MainActor
enum PlayerOrientation {
    /// What the app delegate reports as supported (iPhone).
    private(set) static var mask: UIInterfaceOrientationMask = .portrait
    private static var deviceObserver: NSObjectProtocol?

    private static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    static var isLandscape: Bool { scene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false }

    static func setLandscape(_ landscape: Bool) {
        guard isPhone else { return }
        let target: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
        guard target != mask || isLandscape != landscape else { return }
        mask = target
        guard let scene else { return }
        // Tell UIKit the supported set changed, then rotate into it.
        scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
            NSLog("Tuner: rotation request failed: \(error.localizedDescription)")
        }
    }

    static func toggle() { setLandscape(!isLandscape) }

    /// The player went full screen: follow the phone's rotation while it's open (with rotation lock on there are
    /// no rotation events; the button and swipes still work).
    static func playerOpened() {
        guard isPhone, deviceObserver == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        deviceObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let orientation = UIDevice.current.orientation
                if orientation.isLandscape { setLandscape(true) } else if orientation == .portrait { setLandscape(false) }
            }
        }
        // Already holding the phone sideways when the video opens: go straight to full screen.
        if UIDevice.current.orientation.isLandscape { setLandscape(true) }
    }

    /// The player closed: stop following rotation and return to portrait.
    static func playerClosed() {
        if let deviceObserver {
            NotificationCenter.default.removeObserver(deviceObserver)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        deviceObserver = nil
        setLandscape(false)
    }
}
