import Foundation

/// A span of an episode the user skipped over by hand, or a learned intro they confirmed with the Skip Intro button.
public struct LearnedSkipSpan: Sendable, Hashable {
    public var episodeId: String
    public var start: Double
    public var end: Double
    /// Recorded when the user used the Skip Intro button on a learned suggestion.
    public var confirmed: Bool

    public init(episodeId: String, start: Double, end: Double, confirmed: Bool = false) {
        self.episodeId = episodeId
        self.start = start
        self.end = end
        self.confirmed = confirmed
    }
}

/// Learns a show's intro from how the user watches it: a forward seek of 20 s–3 min early in an episode is remembered,
/// and once two episodes of the show have such a span in the same place (±10 s at both ends), later episodes get a
/// Skip Intro button for it. Learned intros are never skipped automatically until the user confirmed the suggestion
/// (pressed its button) in two episodes.
public enum SkipLearner {
    public static let minimumSpan: Double = 20
    public static let maximumSpan: Double = 180
    /// Only seeks starting in the first 15 % of the episode count.
    public static let earlyFraction = 0.15
    public static let tolerance: Double = 10
    public static let episodesNeeded = 2
    public static let confirmationsForAutoSkip = 2

    /// Whether a forward skip from `from` to `to` in an episode of `duration` seconds looks like skipping the intro.
    public static func isIntroSkip(from: Double, to: Double, duration: Double?) -> Bool {
        guard let duration, duration.isFinite, duration > 0, from.isFinite, to.isFinite, from >= 0 else { return false }
        let span = to - from
        return span >= minimumSpan && span <= maximumSpan && from <= duration * earlyFraction && to < duration
    }

    /// The show's learned intro: the largest group of spans from at least two different episodes that agree on start
    /// and end (±10 s), as the median of the group. Auto-skippable once two episodes confirmed it.
    public static func suggestedIntro(from spans: [LearnedSkipSpan]) -> SkipSegment? {
        var best: (episodes: Int, confirmed: Int, members: [LearnedSkipSpan])?
        for anchor in spans {
            let members = spans.filter { abs($0.start - anchor.start) <= tolerance && abs($0.end - anchor.end) <= tolerance }
            let episodes = Set(members.map(\.episodeId)).count
            guard episodes >= episodesNeeded else { continue }
            let confirmed = Set(members.filter(\.confirmed).map(\.episodeId)).count
            if let current = best, (current.episodes, current.confirmed) >= (episodes, confirmed) { continue }
            best = (episodes, confirmed, members)
        }
        guard let best else { return nil }
        let start = median(best.members.map(\.start))
        let end = median(best.members.map(\.end))
        guard end - start >= minimumSpan else { return nil }
        return SkipSegment(kind: .intro, start: start, end: end, source: .learned,
                           mayAutoSkip: best.confirmed >= confirmationsForAutoSkip)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

/// Joins quick successive forward seeks (→ → → → pressed in a row, or a few drags) into one span, so skipping an
/// intro 10 s at a time counts like one drag over it.
public struct ForwardSeekChain: Sendable {
    /// Seeks less than this apart belong to the same chain.
    public static let gap: TimeInterval = 3

    private var start: Double?
    private var end: Double?
    private var lastAt: Date?

    public init() {}

    /// Adds a seek; returns the previous chain when this seek starts a new one.
    public mutating func seek(from: Double, to: Double, at date: Date) -> (from: Double, to: Double)? {
        var finished: (from: Double, to: Double)?
        if let lastAt, date.timeIntervalSince(lastAt) <= Self.gap, let start, let end, to > start {
            // The engine's reported position can lag behind a run of quick seeks, so the chain keeps its first start
            // and the furthest target.
            self.end = max(end, to)
        } else {
            finished = flush()
            if to > from {
                start = from
                end = to
            }
        }
        lastAt = date
        if to <= from, start == nil { lastAt = nil }
        return finished
    }

    /// The chain once no seek followed for `gap` seconds (call periodically).
    public mutating func finished(at date: Date) -> (from: Double, to: Double)? {
        guard let lastAt, date.timeIntervalSince(lastAt) > Self.gap else { return nil }
        return flush()
    }

    /// Ends the chain now (the item changed).
    public mutating func flush() -> (from: Double, to: Double)? {
        defer {
            start = nil
            end = nil
            lastAt = nil
        }
        guard let start, let end, end > start else { return nil }
        return (start, end)
    }
}
