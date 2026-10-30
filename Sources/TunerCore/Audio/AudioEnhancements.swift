import Foundation

/// Sound processing the player can apply on top of the stream's own mix.
public enum AudioEnhancement: String, CaseIterable, Hashable, Sendable {
    /// Speech clearer and louder than music and effects: centre channel raised, speech band lifted, rumble cut.
    case dialogueBoost
    /// Dynamic range compression ("reduce loud sounds"): quiet parts up, loud parts down.
    case nightMode
    /// Slow automatic gain so channels and titles play at a similar loudness.
    case volumeLevelling

    var bit: UInt8 {
        switch self {
        case .dialogueBoost: 1
        case .nightMode: 2
        case .volumeLevelling: 4
        }
    }
}

/// Which enhancements are switched on (a global preference, applied live to the playing stream).
public struct AudioEnhancementSettings: Hashable, Sendable {
    public var dialogueBoost: Bool
    public var nightMode: Bool
    public var volumeLevelling: Bool

    public init(dialogueBoost: Bool = false, nightMode: Bool = false, volumeLevelling: Bool = false) {
        self.dialogueBoost = dialogueBoost
        self.nightMode = nightMode
        self.volumeLevelling = volumeLevelling
    }

    public init(_ enabled: Set<AudioEnhancement>) {
        self.init(dialogueBoost: enabled.contains(.dialogueBoost), nightMode: enabled.contains(.nightMode),
                  volumeLevelling: enabled.contains(.volumeLevelling))
    }

    public subscript(_ enhancement: AudioEnhancement) -> Bool {
        get {
            switch enhancement {
            case .dialogueBoost: dialogueBoost
            case .nightMode: nightMode
            case .volumeLevelling: volumeLevelling
            }
        }
        set {
            switch enhancement {
            case .dialogueBoost: dialogueBoost = newValue
            case .nightMode: nightMode = newValue
            case .volumeLevelling: volumeLevelling = newValue
            }
        }
    }

    public var enabled: Set<AudioEnhancement> { Set(AudioEnhancement.allCases.filter { self[$0] }) }
    public var isActive: Bool { dialogueBoost || nightMode || volumeLevelling }

    /// Compact form for the render thread (one atomic byte).
    var bitmask: UInt8 { AudioEnhancement.allCases.reduce(0) { self[$1] ? $0 | $1.bit : $0 } }
}
