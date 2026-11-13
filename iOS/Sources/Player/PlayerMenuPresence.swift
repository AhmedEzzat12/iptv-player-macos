import UIKit

/// Whether a menu (a SwiftUI `Menu`, shown by UIKit as a context menu) is open in the app. SwiftUI reports neither
/// opening nor closing on iOS, so the player looks for the menu's container in its windows: while one is up, the
/// controls stay (otherwise they faded away and left the open menu floating over the video).
@MainActor
enum PlayerMenuPresence {
    static var isShowing: Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !window.isHidden {
                if contains(window, depth: 0) { return true }
            }
        }
        return false
    }

    private static func contains(_ view: UIView, depth: Int) -> Bool {
        let name = String(describing: type(of: view))
        if name.contains("ContextMenu") { return true }
        guard depth < 6 else { return false }
        return view.subviews.contains { contains($0, depth: depth + 1) }
    }
}
