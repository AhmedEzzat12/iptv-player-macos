import UIKit

/// Full screen on iPhone = landscape, like YouTube: the player's full-screen button and swipe up switch to landscape,
/// swipe down or the button again switch back, and closing the player restores portrait when the app turned the
/// screen (so it can't stay stuck in landscape with rotation lock on).
@MainActor
enum PlayerOrientation {
    /// The player turned the screen to landscape (rather than the user rotating the phone).
    private static var forcedLandscape = false

    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    static var isLandscape: Bool { scene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false }

    static func setLandscape(_ landscape: Bool) {
        guard let scene, scene.effectiveGeometry.interfaceOrientation.isLandscape != landscape else { return }
        forcedLandscape = landscape
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { error in
            NSLog("Tuner: rotation request failed: \(error.localizedDescription)")
        }
    }

    static func toggle() { setLandscape(!isLandscape) }

    /// The player closed: undo a rotation the player made.
    static func restorePortraitIfForced() {
        guard forcedLandscape else { return }
        setLandscape(false)
        forcedLandscape = false
    }
}
