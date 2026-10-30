import Foundation

/// When the sleep timer stops playback.
public enum SleepTimerOption: Hashable, Sendable {
    /// After a number of minutes (wall-clock, also while paused).
    case minutes(Int)
    /// When the playing movie or episode ends (no autoplay into the next one); live TV: when the programme ends.
    case endOfItem

    public static let presets: [SleepTimerOption] = [15, 30, 45, 60, 90].map { .minutes($0) }
}

/// The player's sleep timer (per session, never persisted): the time left, the volume fade over the last seconds
/// and when to stop.
public struct SleepTimer: Equatable, Sendable {
    /// The volume fades out over this many seconds before the timer fires.
    public static let fadeDuration: TimeInterval = 10

    public let option: SleepTimerOption
    /// When a `.minutes` timer fires.
    public let deadline: Date?

    public init(_ option: SleepTimerOption, now: Date = Date()) {
        self.option = option
        if case .minutes(let minutes) = option {
            deadline = now.addingTimeInterval(TimeInterval(max(minutes, 0) * 60))
        } else {
            deadline = nil
        }
    }

    public var isEndOfItem: Bool { option == .endOfItem }

    /// Seconds until the timer fires, or nil when that isn't known yet (end of item without a duration).
    /// `itemTimeLeft` is the playing item's remaining real time (see `itemTimeLeft(position:duration:rate:)`),
    /// or for live TV the time until the current programme ends.
    public func remaining(now: Date = Date(), itemTimeLeft: TimeInterval?) -> TimeInterval? {
        switch option {
        case .minutes:
            return deadline.map { max(0, $0.timeIntervalSince(now)) }
        case .endOfItem:
            return itemTimeLeft.map { max(0, $0) }
        }
    }

    /// Whether the timer should stop playback now. End of a movie/episode fires from the player's own end event
    /// (so the last seconds aren't cut by polling), so only minutes and live programme ends fire from here.
    public func shouldFire(remaining: TimeInterval?, isLive: Bool) -> Bool {
        guard let remaining, remaining <= 0 else { return false }
        return !isEndOfItem || isLive
    }

    /// Volume multiplier: 1, then a linear fade to 0 over the last `fadeDuration` seconds.
    public static func volumeFactor(remaining: TimeInterval?) -> Double {
        guard let remaining, remaining < fadeDuration else { return 1 }
        return min(max(remaining / fadeDuration, 0), 1)
    }

    /// Real time left in a finite item at playback speed `rate`, or nil without a usable position/duration.
    public static func itemTimeLeft(position: Double?, duration: Double?, rate: Double = 1) -> TimeInterval? {
        guard let position, let duration, duration > 0, position.isFinite, duration.isFinite else { return nil }
        return max(0, duration - position) / max(rate, 0.01)
    }

    /// "12:05" or "1:02:03" (rounded up, so it never shows 0:00 while still running).
    public static func label(_ remaining: TimeInterval) -> String {
        let total = Int(max(0, remaining).rounded(.up))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
