import Foundation
import Observation
import TunerCore

/// Owns the four player slots (main + multiview cells) and how the player is presented.
@MainActor
@Observable
final class PlayerManager {
    /// Fixed pool; `order[0]` is the main (audible, controlled) slot.
    let slots: [PlayerSlot]
    private(set) var order: [Int] = [0, 1, 2, 3]

    var layout: MultiviewLayout = .single {
        didSet {
            guard layout != oldValue else { return }
            for position in layout.slotCount..<slots.count { slot(at: position).stop() }
            updateAudioFocus()
        }
    }

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
        slots = (0..<4).map { PlayerSlot(id: $0, services: services) }
        updateAudioFocus()
    }

    var main: PlayerSlot { slot(at: 0) }

    func slot(at position: Int) -> PlayerSlot { slots[order[position]] }

    /// Slots shown by the current layout, in visual order.
    var visibleSlots: [PlayerSlot] { (0..<layout.slotCount).map { slot(at: $0) } }

    var hasMedia: Bool { main.item != nil }

    func play(_ item: PlaybackItem, at position: Int = 0, startAt: Double? = nil) {
        if position >= layout.slotCount {
            layout = position < 2 ? .pictureInPicture : .grid2x2
        }
        slot(at: position).play(item, startAt: startAt)
    }

    /// Makes the slot at `position` the main one (gets audio and the controls).
    func promote(position: Int) {
        guard position > 0, position < order.count else { return }
        order.swapAt(0, position)
        updateAudioFocus()
    }

    func stopAll() {
        for slot in slots { slot.stop() }
        layout = .single
        isFullWindow = false
    }

    func shutdown() {
        for slot in slots { slot.shutdown() }
    }

    private func updateAudioFocus() {
        for (position, id) in order.enumerated() {
            slots[id].hasAudioFocus = position == 0
        }
    }
}
