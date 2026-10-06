import Foundation

/// iOS stand-in for the macOS single-key dispatcher (`KeyboardShortcuts` in Sources/Tuner/App/KeyboardShortcuts.swift,
/// an AppKit key monitor). The shortcut actions, menu commands and help sheet in that file are shared; with a
/// hardware keyboard the iPad menu bar carries the ⌘ shortcuts.
@MainActor
enum KeyboardShortcuts {
    static var isRecording = false

    /// Current default bindings as (keys, action) pairs, as on the Mac.
    static var reference: [(String, String)] {
        ShortcutAction.allCases.filter { !$0.defaultKey.isEmpty }.map { (ShortcutKey.label($0.defaultKey), $0.title) }
    }
}
