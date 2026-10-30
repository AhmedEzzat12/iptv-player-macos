import SwiftUI
import TunerCore

/// Settings › Playback › Audio: the same toggles as the player's Audio menu, applied live to what's playing.
struct SettingsAudioSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        Section {
            ForEach(AudioEnhancement.allCases, id: \.self) { enhancement in
                Toggle(isOn: $prefs.audioEnhancements[enhancement]) {
                    Text(enhancement.title)
                    Text(enhancement.detail)
                }
            }
        } header: {
            Text("Audio")
        } footer: {
            SettingsFooter(footer)
        }
        .onChange(of: prefs.audioEnhancements) { _, _ in
            model.audioPreferencesChanged()
        }
    }

    private var footer: String {
        #if os(macOS)
        "Also in the player's Audio menu. Apple's player can't process the sound of HLS streams, so while one of these is on they play with mpv (Automatic engine), without Picture in Picture or AirPlay."
        #else
        "Also in the player's … menu. Apple's player can't process the sound of HLS streams, so while Dialogue Boost is on they play with mpv, without Picture in Picture or AirPlay. Night Mode and Volume Levelling work with Apple's player only (movies and episodes in MP4)."
        #endif
    }
}
