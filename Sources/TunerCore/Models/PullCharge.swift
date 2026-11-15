import Foundation

/// How a held pull-to-refresh arms its second action (iPhone/iPad): a charge from 0 to 1 that fills with time while the
/// page is pulled past the line, faster the farther it's pulled (up to twice as fast), and drains when the pull eases
/// back. Holding at the line takes `holdSeconds`; holding at full depth half of that, so a quick deep flick still can't
/// arm it by accident.
public struct PullCharge: Equatable, Sendable {
    /// Pull (points) where the first action starts and the charge begins to fill.
    public static let line: Double = 80
    /// Once past the line, how far the pull may sag before it counts as let off.
    public static let keep: Double = 60
    /// Pull at which the charge fills fastest.
    public static let deep: Double = 200
    /// Seconds an empty-to-full charge takes to drain.
    public static let drainSeconds: Double = 0.4

    public private(set) var value: Double = 0
    /// Past the line (and not eased back below `keep` since).
    public private(set) var isPastLine = false

    public init() {}

    public var isFull: Bool { value >= 1 }

    /// Advances by `dt` seconds with the page pulled `pull` points.
    public mutating func step(pull: Double, dt: Double, holdSeconds: Double) {
        guard dt > 0 else { return }
        if isPastLine ? pull < Self.keep : pull < Self.line {
            isPastLine = false
            value = max(0, value - dt / Self.drainSeconds)
            return
        }
        isPastLine = true
        let depth = min(max((pull - Self.line) / (Self.deep - Self.line), 0), 1)
        value = min(1, value + dt * (1 + depth) / max(holdSeconds, 0.25))
    }

    public mutating func reset() {
        value = 0
        isPastLine = false
    }
}
