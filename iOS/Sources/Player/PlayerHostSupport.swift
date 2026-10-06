import SwiftUI
import UIKit

// iOS counterparts of the Mac-only helpers at the end of Sources/Tuner/Views/Player/PlayerHost.swift.

/// macOS fades the window's traffic-light buttons with the player chrome. iOS has none.
@MainActor
enum PlayerTitlebar {
    static func setButtonsHidden(_ hidden: Bool, in window: UIWindow?) {}
}

/// macOS adjusts the volume with the scroll wheel and tracks the pointer with event monitors. On iOS the
/// hardware buttons set the volume and touches drive the chrome, so there's nothing to monitor.
@MainActor
final class PlayerScrollVolumeMonitor {
    func setEnabled(_ enabled: Bool, model: AppModel, onActivity: @escaping () -> Void,
                    onPointer: @escaping (CGPoint) -> Void) {}
}
