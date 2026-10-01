import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// AirPlay route picker bound to an `AVPlayer` (only the AVFoundation engine can route to AirPlay).
struct PlayerAirPlayButton: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.white, for: .normal)
        picker.setRoutePickerButtonColor(NSColor.white.withAlphaComponent(0.6), for: .normalHighlighted)
        picker.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        picker.setRoutePickerButtonColor(NSColor.controlAccentColor.withAlphaComponent(0.6), for: .activeHighlighted)
        picker.player = player
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        if picker.player !== player { picker.player = player }
    }
}
