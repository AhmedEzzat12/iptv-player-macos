import Foundation

/// Parameters of a feed-forward compressor (levels in dBFS, times in seconds).
public struct CompressorSettings: Equatable, Sendable {
    public var thresholdDB: Double
    public var ratio: Double
    /// Width of the soft knee around the threshold (0 = hard knee).
    public var kneeDB: Double
    public var attack: Double
    public var release: Double
    public var makeupDB: Double

    public init(thresholdDB: Double, ratio: Double, kneeDB: Double, attack: Double, release: Double, makeupDB: Double) {
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.kneeDB = kneeDB
        self.attack = attack
        self.release = release
        self.makeupDB = makeupDB
    }

    /// Night Mode: 30 dB of range above -30 dBFS squeezed 4:1, then everything lifted 9 dB, so whispers come up
    /// and explosions come down. Peaks end up around -13 dBFS, so the makeup gain can't clip.
    public static let nightMode = CompressorSettings(thresholdDB: -30, ratio: 4, kneeDB: 9, attack: 0.005,
                                                     release: 0.2, makeupDB: 9)

    /// Safety limiter at the end of the AVFoundation chain (EQ boosts and levelling gain can't clip).
    public static let limiter = CompressorSettings(thresholdDB: -1, ratio: 20, kneeDB: 0, attack: 0.0005,
                                                   release: 0.05, makeupDB: 0)
}

/// Pure dynamics maths shared by the compressor and the tests.
public enum Dynamics {
    /// Static gain computer with a soft knee (Giannoulis, Massberg & Reiss, JAES 2012): the gain change in dB
    /// (≤ 0, makeup not included) for a signal at `levelDB`.
    public static func gainReductionDB(levelDB x: Double, settings s: CompressorSettings) -> Double {
        let overshoot = x - s.thresholdDB
        let slope = 1 / max(s.ratio, 1) - 1
        let knee = max(s.kneeDB, 0)
        if 2 * overshoot < -knee { return 0 }
        if knee > 0, 2 * abs(overshoot) <= knee {
            let t = overshoot + knee / 2
            return slope * t * t / (2 * knee)
        }
        return slope * overshoot
    }

    /// One-pole smoothing coefficient for a time constant (`exp(-1 / (t · fs))`); 0 means "follow at once".
    public static func smoothingCoefficient(time: Double, sampleRate: Double) -> Double {
        guard time > 0, sampleRate > 0 else { return 0 }
        return exp(-1 / (time * sampleRate))
    }

    @inline(__always)
    public static func decibels(_ linear: Double) -> Double { 20 * log10(max(linear, 1e-10)) }

    @inline(__always)
    public static func linear(_ decibels: Double) -> Double { pow(10, decibels / 20) }
}

/// Feed-forward compressor with gain smoothing in the log domain (attack when reducing more, release when
/// recovering). Allocation-free; one instance per stream, linked across channels by the caller.
public struct Compressor: Sendable {
    public private(set) var settings: CompressorSettings
    private var attackCoefficient = 0.0
    private var releaseCoefficient = 0.0
    /// Current smoothed gain change (dB, ≤ 0).
    public private(set) var reductionDB = 0.0

    public init(settings: CompressorSettings, sampleRate: Double) {
        self.settings = settings
        configure(sampleRate: sampleRate)
    }

    public mutating func configure(sampleRate: Double) {
        attackCoefficient = Dynamics.smoothingCoefficient(time: settings.attack, sampleRate: sampleRate)
        releaseCoefficient = Dynamics.smoothingCoefficient(time: settings.release, sampleRate: sampleRate)
    }

    public mutating func reset() { reductionDB = 0 }

    /// Feeds one detector level (dBFS) and returns the gain to apply in dB, makeup included.
    @inline(__always)
    public mutating func gainDB(levelDB: Double) -> Double {
        let target = Dynamics.gainReductionDB(levelDB: levelDB, settings: settings)
        let coefficient = target < reductionDB ? attackCoefficient : releaseCoefficient
        reductionDB = coefficient * reductionDB + (1 - coefficient) * target
        return reductionDB + settings.makeupDB
    }
}

/// Parameters of the slow automatic gain behind Volume Levelling.
public struct LevellerSettings: Equatable, Sendable {
    /// Loudness everything is steered towards (RMS, dBFS).
    public var targetDB: Double
    public var maxBoostDB: Double
    public var maxCutDB: Double
    /// Below this the signal counts as silence and the gain is held (no pumping up of hiss between scenes).
    public var gateDB: Double
    /// Length of the RMS window the loudness is measured over.
    public var window: Double
    /// How fast the gain may rise / fall (dB per second).
    public var boostRate: Double
    public var cutRate: Double

    public init(targetDB: Double, maxBoostDB: Double, maxCutDB: Double, gateDB: Double, window: Double,
                boostRate: Double, cutRate: Double) {
        self.targetDB = targetDB
        self.maxBoostDB = maxBoostDB
        self.maxCutDB = maxCutDB
        self.gateDB = gateDB
        self.window = window
        self.boostRate = boostRate
        self.cutRate = cutRate
    }

    /// Steers towards -20 dBFS RMS within ±12 dB; rises slowly (2 dB/s) and falls faster (6 dB/s) so a loud
    /// advert after a quiet film is tamed within a couple of seconds.
    public static let standard = LevellerSettings(targetDB: -20, maxBoostDB: 12, maxCutDB: 12, gateDB: -55,
                                                  window: 3, boostRate: 2, cutRate: 6)
}

/// Volume Levelling: measures loudness over a few seconds and moves a gain towards the target, slew-limited.
/// Updated once per audio block; the caller ramps between successive gains. Allocation-free.
public struct Leveller: Sendable {
    public let settings: LevellerSettings
    private var meanSquare: Double
    /// Current gain (dB).
    public private(set) var gainDB = 0.0

    public init(settings: LevellerSettings = .standard) {
        self.settings = settings
        meanSquare = pow(10, settings.targetDB / 10)
    }

    public mutating func reset() {
        meanSquare = pow(10, settings.targetDB / 10)
        gainDB = 0
    }

    /// Smoothed loudness (dBFS RMS) of what was fed so far.
    public var levelDB: Double { 10 * log10(max(meanSquare, 1e-12)) }

    /// Feeds a block's mean square (all channels) and returns the new gain in dB.
    @discardableResult
    public mutating func update(blockMeanSquare: Double, frames: Int, sampleRate: Double) -> Double {
        guard frames > 0, sampleRate > 0, blockMeanSquare.isFinite else { return gainDB }
        let seconds = Double(frames) / sampleRate
        let blockDB = 10 * log10(max(blockMeanSquare, 1e-12))
        // Silent blocks neither count towards the loudness nor move the gain.
        guard blockDB > settings.gateDB else { return gainDB }
        let a = exp(-seconds / max(settings.window, 0.01))
        meanSquare = a * meanSquare + (1 - a) * blockMeanSquare
        let desired = min(max(settings.targetDB - levelDB, -settings.maxCutDB), settings.maxBoostDB)
        let step = (desired > gainDB ? settings.boostRate : settings.cutRate) * seconds
        gainDB += min(max(desired - gainDB, -step), step)
        return gainDB
    }
}

/// Dialogue Boost's curve, shared by both engines: a broad cut around 100 Hz (rumble, score), a lift at 2.5 kHz
/// (consonants), centre-channel emphasis, and 2 dB of headroom for the lift.
public enum DialogueBoost {
    public static let lowFrequency = 100.0
    public static let lowQ = 0.7
    public static let lowGainDB = -5.0
    public static let presenceFrequency = 2500.0
    public static let presenceQ = 0.9
    public static let presenceGainDB = 4.0
    public static let headroomDB = -2.0
    /// Stereo: gain on the mid (centre) signal and on the side (left minus right) signal.
    public static let midGain = 1.12
    public static let sideGain = 0.6
    /// Surround downmix weight of the centre channel relative to the front pair (ITU uses 0.707).
    public static let centreWeight = 1.5
    public static let surroundWeight = 0.6
}
