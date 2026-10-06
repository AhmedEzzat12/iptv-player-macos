import AVFoundation
import AVKit
import SwiftUI

/// AirPlay route picker. On iOS the picker can't be bound to a player (`AVRoutePickerView.player` is
/// macOS-only); the AVPlayer follows the system route because `allowsExternalPlayback` is on.
struct PlayerAirPlayButton: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .tintColor
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}
