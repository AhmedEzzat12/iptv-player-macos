import Foundation

/// Builds the FFmpeg filter list mpv's `af` property gets for the enabled audio enhancements.
///
/// Each filter is its own labelled `af` entry (`@tuner-…:lavfi-<name>=…`) rather than one `lavfi=[graph]`: mpv
/// checks entry names when the property is set, so a filter the FFmpeg build lacks is refused up front (and the
/// old chain stays), whereas an unknown filter inside a graph only fails once audio starts, leaving no sound at
/// all. Filters missing from `available` are skipped, and so is the enhancement that needs them. The labels let
/// the engine remove exactly its own entries (`af remove`) and keep filters from the advanced mpv options.
///
/// - Dialogue Boost: `pan` downmixes to stereo with the centre channel weighted up (layout-independent: absent
///   channels are ignored, stereo passes unchanged), `dialoguenhance` + `aformat` when the build has them, then the
///   same peaking EQ the AVFoundation path uses (`DialogueBoost`), with headroom.
/// - Volume Levelling: `speechnorm` with FFmpeg's "weak and slow" settings. (`dynaudnorm`/`loudnorm` were
///   rejected: their seconds of look-ahead made mpv skip audio whenever the chain changed.)
/// - Night Mode: `acompressor` with `CompressorSettings.nightMode`.
public enum MPVAudioFilterChain {
    /// FFmpeg filters the chain can use; the engine probes which ones its libmpv has.
    public static let filterNames = ["pan", "dialoguenhance", "aformat", "volume", "equalizer", "speechnorm", "acompressor"]

    /// Every label the chain may add, in chain order (for `af remove`).
    public static let labels = ["tuner-dialogue-mix", "tuner-dialogue-enhance", "tuner-dialogue-format",
                                "tuner-dialogue-gain", "tuner-dialogue-low", "tuner-dialogue-presence",
                                "tuner-levelling", "tuner-night"]

    public struct Chain: Equatable, Sendable {
        /// Comma-separated `af` list ("" when nothing applies).
        public var value: String
        /// Enhancements the chain actually implements with the available filters.
        public var applied: Set<AudioEnhancement>
    }

    /// Enhancements a libmpv with these filters can apply.
    public static func supported(by available: Set<String>) -> Set<AudioEnhancement> {
        var result = Set<AudioEnhancement>()
        if available.isSuperset(of: ["equalizer", "volume"]) { result.insert(.dialogueBoost) }
        if available.contains("speechnorm") { result.insert(.volumeLevelling) }
        if available.contains("acompressor") { result.insert(.nightMode) }
        return result
    }

    public static func build(_ settings: AudioEnhancementSettings, available: Set<String>) -> Chain {
        let supported = supported(by: available)
        var entries: [String] = []
        var applied = Set<AudioEnhancement>()

        if settings.dialogueBoost, supported.contains(.dialogueBoost) {
            if available.contains("pan") {
                let c = number(DialogueBoost.centreWeight), s = number(DialogueBoost.surroundWeight)
                entries.append("@tuner-dialogue-mix:lavfi-pan=[stereo|FL<FL+\(c)*FC+\(s)*BL+\(s)*SL|FR<FR+\(c)*FC+\(s)*BR+\(s)*SR]")
                if available.isSuperset(of: ["dialoguenhance", "aformat"]) {
                    entries.append("@tuner-dialogue-enhance:lavfi-dialoguenhance=original=1:enhance=1:voice=2")
                    entries.append("@tuner-dialogue-format:lavfi-aformat=channel_layouts=stereo")
                }
            }
            entries.append("@tuner-dialogue-gain:lavfi-volume=volume=\(number(Dynamics.linear(DialogueBoost.headroomDB)))")
            entries.append(equalizer("tuner-dialogue-low", DialogueBoost.lowFrequency, DialogueBoost.lowQ, DialogueBoost.lowGainDB))
            entries.append(equalizer("tuner-dialogue-presence", DialogueBoost.presenceFrequency, DialogueBoost.presenceQ,
                                     DialogueBoost.presenceGainDB))
            applied.insert(.dialogueBoost)
        }
        if settings.volumeLevelling, supported.contains(.volumeLevelling) {
            entries.append("@tuner-levelling:lavfi-speechnorm=e=6.25:r=0.00001:l=1")
            applied.insert(.volumeLevelling)
        }
        if settings.nightMode, supported.contains(.nightMode) {
            let s = CompressorSettings.nightMode
            // acompressor takes linear values: threshold and makeup as amplitudes, the knee as a factor.
            entries.append("@tuner-night:lavfi-acompressor=threshold=\(number(Dynamics.linear(s.thresholdDB)))"
                           + ":ratio=\(number(s.ratio)):attack=\(number(s.attack * 1000)):release=\(number(s.release * 1000))"
                           + ":knee=\(number(Dynamics.linear(s.kneeDB))):makeup=\(number(Dynamics.linear(s.makeupDB)))")
            applied.insert(.nightMode)
        }
        return Chain(value: entries.joined(separator: ","), applied: applied)
    }

    private static func equalizer(_ label: String, _ frequency: Double, _ q: Double, _ gainDB: Double) -> String {
        "@\(label):lavfi-equalizer=f=\(number(frequency)):t=q:w=\(number(q)):g=\(number(gainDB))"
    }

    /// Up to four decimals, no trailing zeros, always with a dot (mpv parses numbers in the C locale).
    static func number(_ value: Double) -> String {
        var text = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
