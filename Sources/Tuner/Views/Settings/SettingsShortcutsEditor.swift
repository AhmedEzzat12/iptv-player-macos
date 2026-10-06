#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Settings → Shortcuts: view and remap the single-key shortcuts.
/// Click a key, press the new key; a key already used elsewhere moves to this action.
struct SettingsShortcutsEditor: View {
    @Environment(AppModel.self) private var model
    @ViewState private var recorder = ShortcutRecorder()
    @ViewState private var notice: String?

    var body: some View {
        Form {
            ForEach(ShortcutAction.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        row(action)
                    }
                }
            }
            Section {
                HStack {
                    Text("Media keys (⏯ ⏮ ⏭), AirPods and Control Center also control playback. Shortcuts with ⌘ are listed in the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") {
                        recorder.stop()
                        model.prefs.resetShortcuts()
                        notice = "All shortcuts were reset."
                    }
                    .disabled(model.prefs.shortcutOverrides.isEmpty)
                }
            } footer: {
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(Color.accentColor)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { recorder.stop() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let key = model.prefs.key(for: action)
        let isRecording = recorder.action == action
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let note = action.contextNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isRecording {
                Text(recorder.hint ?? "Press a key…")
                    .font(.callout)
                    .foregroundStyle(recorder.hint == nil ? Color.accentColor : .orange)
            }
            Button {
                if isRecording {
                    recorder.stop()
                } else {
                    notice = nil
                    recorder.start(for: action) { name in assign(name, to: action) }
                }
            } label: {
                ShortcutKeyCap(label: isRecording ? "…" : ShortcutKey.label(key))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the new key (click again to cancel)" : "Click to change")
            .accessibilityLabel("\(action.title): \(key.isEmpty ? "not assigned" : ShortcutKey.label(key))")

            Button {
                recorder.stop()
                model.prefs.bind(action, to: "")
                notice = "“\(action.title)” has no key now."
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .opacity(key.isEmpty ? 0 : 1)
            .disabled(key.isEmpty)
            .help("Remove this shortcut")
        }
    }

    private func assign(_ name: String, to action: ShortcutAction) {
        if let displaced = model.prefs.bind(action, to: name) {
            notice = "\(ShortcutKey.label(name)) now does “\(action.title)” (removed from “\(displaced.title)”)."
        } else {
            notice = "\(ShortcutKey.label(name)) now does “\(action.title)”."
        }
    }
}

/// Captures the next key press for a binding (suspends app shortcuts while recording).
@MainActor
@Observable
final class ShortcutRecorder {
    private(set) var action: ShortcutAction?
    /// Feedback when an unusable key was pressed.
    private(set) var hint: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onKey: ((String) -> Void)?

    func start(for action: ShortcutAction, onKey: @escaping (String) -> Void) {
        stop()
        self.action = action
        self.onKey = onKey
        hint = nil
        KeyboardShortcuts.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let hasModifiers = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            MainActor.assumeIsolated { self?.capture(code: code, characters: characters, hasModifiers: hasModifiers) }
            return nil // swallow while recording
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        action = nil
        onKey = nil
        hint = nil
        KeyboardShortcuts.isRecording = false
    }

    private func capture(code: UInt16, characters: String?, hasModifiers: Bool) {
        guard !hasModifiers else {
            hint = "Single keys only (⌘ shortcuts live in the menus)"
            return
        }
        guard let name = ShortcutKey.name(code: code, characters: characters) else {
            hint = "That key can't be used"
            return
        }
        let callback = onKey
        stop()
        callback?(name)
    }
}
