import SwiftUI

/// True where the layout is narrow (iPhone, iPad split view). Shared views switch to stacked layouts when set.
/// macOS never sets it, so the Mac always takes the regular path; the iOS app sets it from the size class.
private struct TunerCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var tunerCompact: Bool {
        get { self[TunerCompactKey.self] }
        set { self[TunerCompactKey.self] = newValue }
    }
}

/// iPhone and iPad, whatever the layout: the swipes (the player down to close it, the Home hero sideways) are always
/// on. The Mac has them only when Settings → Playback → Swipe with the mouse is on (`Preferences.swipeGestures`).
enum TouchScreen {
    static var isAvailable: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}
