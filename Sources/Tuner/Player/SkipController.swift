import Foundation
import Observation
import os
import TunerCore

extension SkipMode {
    var title: String {
        switch self {
        case .button: "Show button"
        case .automatic: "Skip automatically"
        case .off: "Off"
        }
    }
}

extension SkipSegment {
    /// "Skip Intro", "Skip Recap", "Skip Credits".
    var buttonTitle: String {
        switch kind {
        case .intro: "Skip Intro"
        case .recap: "Skip Recap"
        case .credits: "Skip Credits"
        }
    }

    /// "Skipped intro" (the automatic-skip notice).
    var skippedTitle: String {
        switch kind {
        case .intro: "Skipped intro"
        case .recap: "Skipped recap"
        case .credits: "Skipped credits"
        }
    }
}

/// Skip Intro / Skip Credits for the main player: gathers a movie's or episode's segments (chapter markers, the online
/// databases through `SkipSegmentService`, intros learned from the user's own skipping), follows the position through
/// `SkipTracker`, and skips. Lookups run in the background when an item starts and never hold up playback.
@MainActor
@Observable
final class SkipController {
    /// The segment the position is in, while the button should be offered (nil: no button).
    private(set) var prompt: SkipTracker.Prompt?
    /// Shown for a few seconds after an automatic skip, with Undo.
    private(set) var notice: Notice?
    /// The playing item's segments (scrubber markers).
    private(set) var segments: [SkipSegment] = []

    struct Notice: Equatable {
        let id = UUID()
        let segment: SkipSegment
    }

    private static let log = Logger(subsystem: "app.tuner.macos", category: "SkipSegments")

    @ObservationIgnored let service: SkipSegmentService
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var slot: PlayerSlot?
    @ObservationIgnored private var tracker = SkipTracker()
    @ObservationIgnored private var current: Current?
    @ObservationIgnored private var chapterSegments: [SkipSegment] = []
    @ObservationIgnored private var onlineSegments: [SkipSegment] = []
    @ObservationIgnored private var learnedIntro: SkipSegment?
    @ObservationIgnored private var mergedForDuration: Double?
    @ObservationIgnored private var seekChain = ForwardSeekChain()
    @ObservationIgnored private var isSkipping = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// The movie or episode the segments belong to.
    private struct Current {
        let itemId: String
        let mediaId: String
        /// Episodes: for learning the show's intro.
        let seriesId: String?
        var duration: Double?
    }

    init(service: SkipSegmentService) {
        self.service = service
    }

    /// Follows the main player (called once by `AppModel`).
    func attach(to slot: PlayerSlot, model: AppModel) {
        self.slot = slot
        self.model = model
        slot.onPoll = { [weak self] in self?.poll() }
        slot.onLoaded = { [weak self] in self?.loadChapters() }
        slot.onSeek = { [weak self] from, to in self?.userSeeked(from: from, to: to) }
    }

    private var mode: SkipMode { model?.prefs.skipSegments ?? .off }

    // MARK: - Item changes

    /// A new item (or none) in the main player: forget the old segments and look up the new ones.
    func itemChanged(_ item: PlaybackItem?) {
        guard item?.id != current?.itemId else { return }
        finishSeekChain()
        tasks.forEach { $0.cancel() }
        tasks = []
        current = nil
        chapterSegments = []
        onlineSegments = []
        learnedIntro = nil
        mergedForDuration = nil
        tracker = SkipTracker()
        segments = []
        prompt = nil
        notice = nil
        guard let item, let model else { return }
        switch item {
        case .movie(let movie):
            current = Current(itemId: item.id, mediaId: movie.id, seriesId: nil)
            tasks.append(Task { [weak self] in await self?.lookUpOnline(movie: movie, model: model, itemId: item.id) })
        case .episode(let episode, let series):
            current = Current(itemId: item.id, mediaId: episode.id, seriesId: series.id)
            tasks.append(Task { [weak self] in await self?.lookUpOnline(episode: episode, series: series, model: model, itemId: item.id) })
            tasks.append(Task { [weak self] in
                guard let self else { return }
                let learned = await self.service.learnedIntro(seriesId: series.id)
                guard self.current?.itemId == item.id else { return }
                self.learnedIntro = learned
                self.recompute()
            })
        default:
            return
        }
    }

    /// Online lookups only while metadata lookups are on (Settings → Metadata) and the network is up; otherwise the
    /// cache.
    private func allowsNetwork(_ model: AppModel) -> Bool {
        model.prefs.metadataEnabled && !model.isOffline && model.prefs.skipSegments != .off
    }

    private func lookUpOnline(movie: Movie, model: AppModel, itemId: String) async {
        let network = allowsNetwork(model)
        let info = network ? await model.metadata.metadata(for: movie) : await model.metadata.cachedMetadata(mediaId: movie.id)
        let lookup = SkipSegmentService.Lookup(mediaId: movie.id, imdbId: info?.imdbId, tmdbId: info?.tmdbId ?? movie.tmdbId)
        await applyOnline(service.segments(for: lookup, allowNetwork: network), itemId: itemId)
    }

    private func lookUpOnline(episode: Episode, series: Series, model: AppModel, itemId: String) async {
        let network = allowsNetwork(model)
        let info = network ? await model.metadata.metadata(for: series) : await model.metadata.cachedMetadata(mediaId: series.id)
        let lookup = SkipSegmentService.Lookup(mediaId: episode.id, imdbId: info?.imdbId, tmdbId: info?.tmdbId,
                                               season: episode.season, episode: episode.number)
        await applyOnline(service.segments(for: lookup, allowNetwork: network), itemId: itemId)
    }

    private func applyOnline(_ found: [SkipSegment], itemId: String) {
        guard current?.itemId == itemId, !Task.isCancelled else { return }
        onlineSegments = found
        recompute()
    }

    /// Chapters are known once the engine has opened the media (mpv lists them at load; AVFoundation reads them from
    /// the file). Read again a little later in case they arrive after the first frames.
    private func loadChapters() {
        guard let slot, let itemId = current?.itemId else { return }
        tasks.append(Task { [weak self] in
            for delay in [0.3, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.current?.itemId == itemId else { return }
                let chapters = await slot.chapters()
                guard self.current?.itemId == itemId else { return }
                let found = SkipSegments.fromChapters(chapters, duration: slot.snapshot.duration)
                if !chapters.isEmpty {
                    Self.log.info("\(chapters.count, privacy: .public) chapters, \(found.count, privacy: .public) skippable")
                    self.chapterSegments = found
                    self.recompute()
                    return
                }
            }
        })
    }

    private func recompute() {
        let duration = slot?.snapshot.duration
        mergedForDuration = duration
        let merged = SkipSegments.merge(chapterSegments + onlineSegments + [learnedIntro].compactMap { $0 }, duration: duration)
        tracker.setSegments(merged)
        if merged != segments { segments = merged }
        poll()
    }

    // MARK: - Playback

    private func poll() {
        guard let slot, var current, let item = slot.item, item.id == current.itemId else { return }
        let snapshot = slot.snapshot
        if let duration = snapshot.duration, duration > 0, current.duration != duration {
            current.duration = duration
            self.current = current
        }
        // Timings are checked against the duration, which is only known once the media has loaded.
        if hasCandidates, abs((snapshot.duration ?? -1) - (mergedForDuration ?? -1)) > 1 { recompute(); return }
        if let span = seekChain.finished(at: Date()) { learn(from: span) }

        let active = slot.phase == .playing || slot.phase == .paused || slot.phase == .buffering
        guard active, let position = snapshot.position else {
            if prompt != nil { prompt = nil }
            return
        }
        let result = tracker.update(position: position, duration: snapshot.duration, mode: mode,
                                    autoSkipCredits: canAutoSkipCredits)
        if result.prompt != prompt { prompt = result.prompt }
        if case .autoSkip(let segment) = result.action {
            skip(segment, automatically: true)
        }
    }

    private var hasCandidates: Bool {
        !chapterSegments.isEmpty || !onlineSegments.isEmpty || learnedIntro != nil
    }

    /// Credits are skipped automatically only into a next episode that would autoplay anyway; a movie's credits
    /// (and a finale's) only get the button.
    private var canAutoSkipCredits: Bool {
        guard let model, let episode = model.currentEpisode, model.prefs.autoplayNextEpisode,
              model.upNextCancelledFor != episode.episode.id, let next = model.adjacentEpisode(1) else { return false }
        return !model.isOffline || model.isDownloaded(next.id)
    }

    /// The Skip button (or K on the Mac).
    func skipCurrent() {
        guard let segment = prompt?.segment else { return }
        skip(segment, automatically: false)
    }

    private func skip(_ segment: SkipSegment, automatically: Bool) {
        guard let slot, let model else { return }
        let duration = slot.snapshot.duration
        prompt = nil
        if segment.kind == .credits {
            // Episodes go on to the next one (as Up Next would); movies and finales jump to the end.
            if model.currentEpisode != nil, model.adjacentEpisode(1) != nil,
               !model.isOffline || model.adjacentEpisode(1).map({ model.isDownloaded($0.id) }) == true {
                model.playAdjacentEpisode(1)
            } else if let duration {
                seek(to: max(0, duration - 0.5))
            }
            return
        }
        let end = segment.resolvedEnd(duration: duration)
        guard end.isFinite else { return }
        seek(to: end)
        if automatically {
            showNotice(for: segment)
        } else if segment.source == .learned, let current, current.seriesId != nil {
            // The user accepted a learned intro: two of these let it skip automatically.
            record(LearnedSkipSpan(episodeId: current.mediaId, start: segment.start, end: end, confirmed: true))
        }
    }

    /// Undo of an automatic skip: back to the start of the segment, which then just shows its button.
    func undo() {
        guard let notice else { return }
        tracker.undoAutoSkip(notice.segment)
        seek(to: notice.segment.start)
        dismissNotice()
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    private func showNotice(for segment: SkipSegment) {
        let shown = Notice(segment: segment)
        notice = shown
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.notice?.id == shown.id else { return }
            self?.notice = nil
        }
    }

    private func seek(to seconds: Double) {
        isSkipping = true
        slot?.seek(to: seconds)
        isSkipping = false
    }

    // MARK: - Learning

    /// A seek by the user (not by a skip): landing in a segment means "watch it"; early forward seeks in episodes
    /// may be the user skipping the intro by hand.
    private func userSeeked(from: Double, to: Double) {
        guard !isSkipping, let current else { return }
        tracker.userSeeked(to: to, duration: slot?.snapshot.duration)
        if notice != nil { dismissNotice() }
        guard current.seriesId != nil, mode != .off else { return }
        if let span = seekChain.seek(from: from, to: to, at: Date()) { learn(from: span) }
    }

    private func finishSeekChain() {
        if let span = seekChain.flush() { learn(from: span) }
    }

    private func learn(from span: (from: Double, to: Double)) {
        guard let current, current.seriesId != nil,
              SkipLearner.isIntroSkip(from: span.from, to: span.to, duration: current.duration) else { return }
        record(LearnedSkipSpan(episodeId: current.mediaId, start: span.from, end: span.to))
    }

    private func record(_ span: LearnedSkipSpan) {
        guard let seriesId = current?.seriesId else { return }
        let service = service
        Task { await service.record(span, seriesId: seriesId) }
    }
}
