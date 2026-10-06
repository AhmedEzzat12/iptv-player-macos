import Foundation
import Observation
import TunerCore

/// Owns the player slot and how the player is presented.
@MainActor
@Observable
final class PlayerManager {
    /// The one player. Kept as an array so code that handles "every slot" (network monitoring, shutdown,
    /// connection limits) reads naturally.
    let slots: [PlayerSlot]

    /// Player covers the whole window (sidebar collapsed, toolbar hidden), Apple TV style.
    var isFullWindow = false
    /// Show the technical stats overlay.
    var showStats = false
    /// The in-player episode list (series only); keeps the controls up while open, Esc closes it first.
    var isEpisodeListOpen = false
    /// The Live TV guide's preview slot, in window-content coordinates (top-left origin), while on screen.
    /// Reported by an AppKit probe because SwiftUI preferences can't cross the NavigationSplitView /
    /// NavigationStack hosting boundaries between the guide and the window-level player.
    var previewFrameInWindow: CGRect?

    init(services: PlayerServices) {
        slots = [PlayerSlot(id: 0, services: services)]
    }

    var main: PlayerSlot { slots[0] }

    var hasMedia: Bool { main.item != nil }

    func play(_ item: PlaybackItem, startAt: Double? = nil) {
        main.play(item, startAt: startAt)
    }

    func stopAll() {
        for slot in slots { slot.stop() }
        isFullWindow = false
    }

    func shutdown() {
        for slot in slots { slot.shutdown() }
    }
}
