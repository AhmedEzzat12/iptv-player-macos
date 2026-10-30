import Foundation

/// A part of a movie or episode the player offers to skip ("Skip Intro", "Skip Recap", "Skip Credits").
public struct SkipSegment: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case recap
        case intro
        case credits
    }

    /// Where the timing came from. `SkipSegments.merge` prefers them in this order.
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// Chapter markers in the stream itself (exact for this file).
        case chapters
        /// TheIntroDB (api.theintrodb.org), crowd-sourced, by IMDb/TMDB id.
        case theIntroDB
        /// IntroDB (api.introdb.app), crowd-sourced, by IMDb id.
        case introDB
        /// Spans the user skipped by hand in other episodes of the show (`SkipLearner`).
        case learned
    }

    public var kind: Kind
    /// Seconds from the start of the media.
    public var start: Double
    /// nil: until the end of the media (credits).
    public var end: Double?
    public var source: Source
    /// False for learned spans the user hasn't confirmed twice: they get the button but are never skipped
    /// automatically.
    public var mayAutoSkip: Bool

    public init(kind: Kind, start: Double, end: Double?, source: Source, mayAutoSkip: Bool = true) {
        self.kind = kind
        self.start = start
        self.end = end
        self.source = source
        self.mayAutoSkip = mayAutoSkip
    }

    /// The end, with an open end resolved against the duration.
    public func resolvedEnd(duration: Double?) -> Double {
        end ?? duration ?? .infinity
    }

    public func contains(_ position: Double, duration: Double?) -> Bool {
        position >= start && position < resolvedEnd(duration: duration)
    }
}

/// A chapter marker read from the stream (AVFoundation chapter metadata or mpv's `chapter-list`).
public struct ChapterMark: Sendable, Hashable {
    public var title: String?
    public var start: Double
    /// nil: until the next chapter (or the end).
    public var end: Double?

    public init(title: String?, start: Double, end: Double? = nil) {
        self.title = title
        self.start = start
        self.end = end
    }
}

/// How the player treats known intros and credits (Settings → Playback).
public enum SkipMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A "Skip Intro" / "Skip Credits" button.
    case button
    /// Skip on its own, with a short "Skipped intro · Undo" notice.
    case automatic
    case off

    public var id: String { rawValue }
}

/// Chapter classification, sanity checks against the playing file and merging of the sources.
public enum SkipSegments {
    // MARK: Chapters

    /// The kind of segment a chapter title names, or nil for story chapters ("Chapter 3", "The Ending Begins").
    /// English (Intro, Opening, OP, Recap, Previously, Credits, Ending, ED, End Credits…) and the obvious Arabic
    /// names (مقدمة، شارة، تتر، ملخص، النهاية…). Scenes after or in the middle of the credits are story, not credits.
    public static func classify(chapterTitle: String?) -> SkipSegment.Kind? {
        guard let raw = chapterTitle else { return nil }
        let words = normalizedWords(raw)
        // Long titles are story chapters that happen to contain a keyword.
        guard !words.isEmpty, words.count <= 4 else { return nil }
        let set = Set(words)
        let story: Set<String> = ["post", "mid", "after", "scene", "stinger", "bonus", "tag", "preview", "next",
                                  "مشهد", "بعد", "القادمة", "القادم"]
        if !set.isDisjoint(with: story) { return nil }

        let recap: Set<String> = ["recap", "previously", "summary", "ملخص", "سابقا", "السابقة"]
        if !set.isDisjoint(with: recap) { return .recap }

        let arabicEnd: Set<String> = ["النهاية", "نهاية", "الختام", "الخاتمة", "ختام", "خاتمة"]
        if !set.isDisjoint(with: arabicEnd) { return .credits }
        // "Opening credits" is the intro, so opening words win over "credits".
        let intro: Set<String> = ["intro", "introduction", "opening", "op", "theme", "titles", "title",
                                  "مقدمة", "المقدمة", "شارة", "الشارة", "تتر", "التتر"]
        let introWords = set.intersection(intro)
        let credits: Set<String> = ["credits", "credit", "ending", "ed", "outro", "closing", "end", "endcredits"]
        if introWords.contains(where: { ["intro", "introduction", "opening", "op"].contains($0) }) { return .intro }
        if !set.isDisjoint(with: credits) { return .credits }
        // "Main titles", "Title sequence", "Theme song", "شارة"/"تتر" on their own.
        if !introWords.isEmpty {
            if introWords == ["title"] || introWords == ["titles"] {
                return set.contains("main") || set.contains("sequence") || set.contains("opening") ? .intro : nil
            }
            return .intro
        }
        return nil
    }

    /// Lowercased words with digits, punctuation and Arabic diacritics removed ("OP 2" → ["op"]).
    static func normalizedWords(_ text: String) -> [String] {
        let folded = text.lowercased()
            .applyingTransform(.stripDiacritics, reverse: false)?
            .replacingOccurrences(of: "ـ", with: "") ?? text.lowercased()
        // "سابقاً" → "سابقا" once the tanween is stripped; normalise alef forms too.
        let alef = folded.replacingOccurrences(of: "[أإآ]", with: "ا", options: .regularExpression)
        return alef.split { !$0.isLetter }.map(String.init)
    }

    /// Segments named by chapter titles. A chapter runs until the next one starts (or the end of the media).
    public static func fromChapters(_ chapters: [ChapterMark], duration: Double?) -> [SkipSegment] {
        let ordered = chapters.filter { $0.start.isFinite && $0.start >= 0 }.sorted { $0.start < $1.start }
        var out: [SkipSegment] = []
        for (i, chapter) in ordered.enumerated() {
            guard let kind = classify(chapterTitle: chapter.title) else { continue }
            let next = i + 1 < ordered.count ? ordered[i + 1].start : nil
            var end = chapter.end ?? next ?? duration
            // The last chapter of a file running to the end: credits stay open-ended.
            if next == nil, kind == .credits { end = nil }
            out.append(SkipSegment(kind: kind, start: chapter.start, end: end, source: .chapters))
        }
        // Adjacent chapters of the same kind ("OP part 1", "OP part 2") become one.
        var merged: [SkipSegment] = []
        for segment in out {
            if var last = merged.last, last.kind == segment.kind, let lastEnd = last.end, abs(lastEnd - segment.start) < 1 {
                last.end = segment.end
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    // MARK: Sanity checks

    /// Limits for timings from the online databases and learned spans. They describe a specific release, which may
    /// be cut or offset differently from the provider's file, so anything that doesn't look like an intro or credits
    /// of *this* file is dropped.
    public enum Limits {
        /// An intro or recap ends within the first quarter and the first 10 minutes.
        public static let introEndFraction = 0.25
        public static let introEndMax: Double = 600
        public static let introLength: ClosedRange<Double> = 5...300
        /// Credits start in the last 15 %.
        public static let creditsStartFraction = 0.85
        /// Chapters are exact for the file, so they only have to be in the right half.
        public static let chapterIntroStartFraction = 0.4
        public static let chapterCreditsStartFraction = 0.6
        /// Slack for rounding at the end of the file.
        public static let endSlack: Double = 2
    }

    /// The segment if its times are plausible for a file of `duration` seconds, with the end clamped to the duration.
    public static func sanitized(_ segment: SkipSegment, duration: Double?) -> SkipSegment? {
        var s = segment
        guard s.start.isFinite, s.start >= 0 else { return nil }
        if let end = s.end { guard end.isFinite, end > s.start + 1 else { return nil } }
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let duration {
            guard s.start < duration - 1 else { return nil }
            if let end = s.end {
                // Times beyond the file's end come from another cut or an offset encode.
                guard end <= duration + Limits.endSlack else { return nil }
                s.end = min(end, duration)
            }
        }

        if s.source == .chapters {
            guard let duration else { return s }
            switch s.kind {
            case .recap, .intro: return s.start < duration * Limits.chapterIntroStartFraction ? s : nil
            case .credits: return s.start >= duration * Limits.chapterCreditsStartFraction ? s : nil
            }
        }

        switch s.kind {
        case .recap, .intro:
            guard let end = s.end, Limits.introLength.contains(end - s.start), end <= Limits.introEndMax else { return nil }
            if let duration { guard end <= duration * Limits.introEndFraction else { return nil } }
            return s
        case .credits:
            // Where "the last 15 %" is needs the duration.
            guard let duration, s.start >= duration * Limits.creditsStartFraction else { return nil }
            return s
        }
    }

    // MARK: Merge

    /// The segments to offer, best source first per kind: chapters, then the online databases (TheIntroDB before
    /// IntroDB), then learned spans. Each kind comes from a single source: the first one with a plausible segment of
    /// that kind. Sorted by start.
    public static func merge(_ candidates: [SkipSegment], duration: Double?) -> [SkipSegment] {
        let sane = candidates.compactMap { sanitized($0, duration: duration) }
        var out: [SkipSegment] = []
        for kind in SkipSegment.Kind.allCases {
            for source in SkipSegment.Source.allCases {
                let picked = sane.filter { $0.kind == kind && $0.source == source }
                if !picked.isEmpty {
                    out += picked
                    break
                }
            }
        }
        // Drop exact duplicates (two equal entries from one database).
        var seen = Set<SkipSegment>()
        return out.filter { seen.insert($0).inserted }.sorted { $0.start < $1.start }
    }
}

// MARK: - Playback tracking

/// What the player shows or does for skip segments as the position moves (pure state; `SkipController` in the app
/// drives it from the player's 0.5 s poll).
///
/// - The button shows while the position is inside a segment, but only for the first `pinnedSeconds` after the
///   segment was entered unless the controls are up (the caller decides that).
/// - In automatic mode a segment is skipped once when playback reaches it. A segment the user seeked into, or
///   came back to after an automatic skip ("Undo"), is never skipped automatically again during this playback.
/// - Credits are only skipped automatically when the caller allows it (episodes with a next episode to go to).
public struct SkipTracker: Sendable {
    public struct Prompt: Equatable, Sendable {
        public var segment: SkipSegment
        /// True for the first seconds after entering the segment: shown even while the controls are hidden.
        public var isFresh: Bool
    }

    public enum Action: Equatable, Sendable {
        case none
        case autoSkip(SkipSegment)
    }

    public static let pinnedSeconds: Double = 6
    /// A segment with less than this left isn't offered any more (nothing worth skipping).
    public static let minimumRemaining: Double = 1.5

    public private(set) var segments: [SkipSegment] = []
    private var noAuto: Set<SkipSegment> = []
    private var enteredAt: [SkipSegment: Double] = [:]

    public init(segments: [SkipSegment] = []) {
        self.segments = segments
    }

    /// Replaces the segments (new information arrived); what happened to unchanged segments is kept.
    public mutating func setSegments(_ new: [SkipSegment]) {
        segments = new
        noAuto = noAuto.filter { new.contains($0) }
        enteredAt = enteredAt.filter { new.contains($0.key) }
    }

    /// The segment the position is in, if any (with enough of it left to be worth skipping).
    public func segment(at position: Double, duration: Double?) -> SkipSegment? {
        segments.first { $0.contains(position, duration: duration)
            && $0.resolvedEnd(duration: duration) - position >= Self.minimumRemaining }
    }

    public mutating func update(position: Double, duration: Double?, mode: SkipMode,
                                autoSkipCredits: Bool) -> (prompt: Prompt?, action: Action) {
        guard mode != .off else { return (nil, .none) }
        let current = segment(at: position, duration: duration)
        // Leaving a segment resets its "fresh" window, so coming back shows the button again.
        for key in enteredAt.keys where key != current { enteredAt[key] = nil }
        guard let current else { return (nil, .none) }
        if mode == .automatic, current.mayAutoSkip, !noAuto.contains(current),
           current.kind != .credits || autoSkipCredits {
            noAuto.insert(current)
            return (nil, .autoSkip(current))
        }
        let entered = enteredAt[current] ?? position
        enteredAt[current] = entered
        let fresh = position - entered < Self.pinnedSeconds && position >= entered
        return (Prompt(segment: current, isFresh: fresh), .none)
    }

    /// A seek by the user: landing inside a segment means they want to watch it.
    public mutating func userSeeked(to position: Double, duration: Double?) {
        if let segment = segment(at: position, duration: duration) { noAuto.insert(segment) }
    }

    /// The user undid an automatic skip (it isn't skipped again).
    public mutating func undoAutoSkip(_ segment: SkipSegment) {
        noAuto.insert(segment)
        enteredAt[segment] = nil
    }
}
