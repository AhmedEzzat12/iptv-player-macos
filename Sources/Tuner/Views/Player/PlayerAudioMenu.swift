import SwiftUI
import TunerCore

/// The Mac control panel's Audio menu (next to Audio & Subtitles and Aspect Ratio): Dialogue Boost, Night Mode,
/// Volume Levelling and the sleep timer. The glyph fills while an enhancement is on; a dot shows a running timer.
struct PlayerAudioMenu: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let size: CGFloat

    var body: some View {
        Menu {
            PlayerAudioMenuItems(slot: slot)
        } label: {
            PlayerGlassSymbol(symbol: model.prefs.audioEnhancements.isActive ? "speaker.wave.2.fill" : "speaker.wave.2",
                              size: size)
                .overlay(alignment: .topTrailing) { PlayerAudioBadge(isShown: slot.sleepTimer != nil) }
        }
        .playerMenuStyle()
        .help("Audio")
        .accessibilityLabel("Audio")
    }
}

/// The audio menu's items, shared by the Mac Audio menu and the iPhone "…" menu (as an Audio submenu).
struct PlayerAudioMenuItems: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot

    var body: some View {
        let settings = model.prefs.audioEnhancements
        Section {
            ForEach(AudioEnhancement.allCases, id: \.self) { enhancement in
                Toggle(enhancement.title, isOn: Binding(
                    get: { settings[enhancement] },
                    set: { model.setAudioEnhancement(enhancement, $0) }
                ))
            }
            if let unavailable {
                Text(unavailable)
            }
        }
        Section {
            sleepTimerMenu
        }
    }

    /// Enhancements that are on but can't be applied to this stream (e.g. HLS with the AVFoundation engine chosen,
    /// or Night Mode in mpv on iPhone).
    private var unavailable: String? {
        guard slot.item != nil, slot.phase == .playing || slot.phase == .paused else { return nil }
        let missing = AudioEnhancement.allCases.filter {
            model.prefs.audioEnhancements[$0] && !slot.appliedAudioEnhancements.contains($0)
        }
        guard !missing.isEmpty else { return nil }
        return "Not available for this stream: " + missing.map(\.title).joined(separator: ", ")
    }

    private var sleepTimerMenu: some View {
        let current = slot.sleepTimer?.option
        return Menu {
            if current != nil {
                Button("Turn Off") { slot.setSleepTimer(nil) }
                Divider()
            }
            ForEach(SleepTimerOption.presets, id: \.self) { option in
                item(option, current: current)
            }
            if canStopAtEnd {
                item(.endOfItem, current: current)
            }
        } label: {
            Label(sleepTimerTitle, systemImage: current == nil ? "moon.zzz" : "moon.zzz.fill")
        }
    }

    private func item(_ option: SleepTimerOption, current: SleepTimerOption?) -> some View {
        Button {
            slot.setSleepTimer(option) // choosing the running option again restarts it
        } label: {
            if option == current {
                Label(option.title(for: slot.item), systemImage: "checkmark")
            } else {
                Text(option.title(for: slot.item))
            }
        }
    }

    /// Finite media always; live TV when the guide says when the programme ends.
    private var canStopAtEnd: Bool {
        guard let item = slot.item else { return false }
        return !item.isLive || slot.currentProgram != nil
    }

    private var sleepTimerTitle: String {
        guard let timer = slot.sleepTimer else { return "Sleep Timer" }
        if let seconds = slot.sleepTimerRemaining {
            return "Sleep Timer: \(SleepTimer.label(TimeInterval(seconds))) left"
        }
        return "Sleep Timer: \(timer.option.title(for: slot.item))"
    }
}

/// A small accent dot on a player glyph (sleep timer running / audio options on).
struct PlayerAudioBadge: View {
    let isShown: Bool

    var body: some View {
        if isShown {
            Circle()
                .fill(.tint)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                .offset(x: -2, y: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
