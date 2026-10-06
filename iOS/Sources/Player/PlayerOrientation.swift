import UIKit

/// The player's Rotate button: switches between portrait and landscape (the system rotates back when the phone is
/// turned again; with rotation lock on, this is the only way to watch in landscape).
@MainActor
enum PlayerOrientation {
    static func toggle() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let landscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .portrait : .landscapeRight)) { error in
            NSLog("Tuner: rotation request failed: \(error.localizedDescription)")
        }
    }
}
