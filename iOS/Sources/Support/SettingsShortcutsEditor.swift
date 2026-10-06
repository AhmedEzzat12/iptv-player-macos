import SwiftUI

/// iOS stand-in for the macOS shortcut editor (Sources/Tuner/Views/Settings/SettingsShortcutsEditor.swift),
/// which records keys with an AppKit event monitor. With a hardware keyboard the iPad menu bar lists the
/// ⌘ shortcuts; this shows the current bindings read-only.
struct SettingsShortcutsEditor: View {
    var body: some View {
        ShortcutHelpView()
    }
}
