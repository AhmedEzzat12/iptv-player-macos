import Foundation
import TunerCore

extension Preferences {
    /// Dialogue Boost / Night Mode / Volume Levelling as one value (the three stored toggles).
    var audioEnhancements: AudioEnhancementSettings {
        get { AudioEnhancementSettings(dialogueBoost: dialogueBoost, nightMode: nightMode, volumeLevelling: volumeLevelling) }
        set {
            if dialogueBoost != newValue.dialogueBoost { dialogueBoost = newValue.dialogueBoost }
            if nightMode != newValue.nightMode { nightMode = newValue.nightMode }
            if volumeLevelling != newValue.volumeLevelling { volumeLevelling = newValue.volumeLevelling }
        }
    }
}

extension AppModel {
    /// Turns an audio enhancement on or off everywhere (it's a preference) and applies it to the playing stream.
    func setAudioEnhancement(_ enhancement: AudioEnhancement, _ isOn: Bool) {
        guard prefs.audioEnhancements[enhancement] != isOn else { return }
        prefs.audioEnhancements[enhancement] = isOn
        audioPreferencesChanged()
    }

    /// Applies the audio preferences to the player (Settings toggles call this too).
    func audioPreferencesChanged() {
        player.main.audioEnhancementsChanged()
    }
}

extension AudioEnhancement {
    var title: String {
        switch self {
        case .dialogueBoost: "Dialogue Boost"
        case .nightMode: "Night Mode"
        case .volumeLevelling: "Volume Levelling"
        }
    }

    var detail: String {
        switch self {
        case .dialogueBoost: "Makes speech clearer and louder than music and effects."
        case .nightMode: "Reduces loud sounds and raises quiet ones."
        case .volumeLevelling: "Evens out the volume between channels, shows and movies."
        }
    }
}

extension SleepTimerOption {
    func title(for item: PlaybackItem?) -> String {
        switch self {
        case .minutes(let minutes):
            return minutes == 60 ? "1 Hour" : (minutes % 60 == 0 ? "\(minutes / 60) Hours" : "\(minutes) Minutes")
        case .endOfItem:
            switch item {
            case .episode: return "End of Episode"
            case .movie: return "End of Movie"
            case .channel, .catchup: return "End of Programme"
            case .recording: return "End of Recording"
            case nil: return "End of Video"
            }
        }
    }
}
