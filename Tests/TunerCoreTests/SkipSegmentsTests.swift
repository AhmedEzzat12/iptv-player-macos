import Foundation
import Testing
@testable import TunerCore

@Suite("Skip intro: chapters")
struct SkipChapterTests {
    @Test(arguments: [
        ("Intro", SkipSegment.Kind.intro), ("Opening", .intro), ("OP", .intro), ("OP 2", .intro), ("Opening Credits", .intro),
        ("Main Titles", .intro), ("Theme Song", .intro), ("Recap", .recap), ("Previously on…", .recap),
        ("Credits", .credits), ("End Credits", .credits), ("Ending", .credits), ("ED", .credits), ("Outro", .credits),
        ("End Titles", .credits), ("مقدمة", .intro), ("المقدمة", .intro), ("شارة البداية", .intro), ("تتر", .intro),
        ("شارة النهاية", .credits), ("تتر النهاية", .credits), ("النهاية", .credits), ("ملخص", .recap),
        ("في الحلقة السابقة", .recap), ("سابقاً", .recap),
    ])
    func recognisedTitles(title: String, kind: SkipSegment.Kind) {
        #expect(SkipSegments.classify(chapterTitle: title) == kind)
    }

    @Test(arguments: ["Chapter 1", "Post-credits scene", "Mid-Credits Scene", "Next Episode Preview", "Prologue",
                      "Titles", "The Night Everything Ended Badly For Everyone", "مشهد بعد التتر", "", "05"])
    func storyChaptersAreIgnored(title: String) {
        #expect(SkipSegments.classify(chapterTitle: title) == nil)
    }

    @Test func chaptersBecomeSegments() {
        let chapters = [
            ChapterMark(title: "Recap", start: 0), ChapterMark(title: "Intro", start: 45),
            ChapterMark(title: "Chapter 2", start: 120), ChapterMark(title: "Credits", start: 2500),
        ]
        let segments = SkipSegments.fromChapters(chapters, duration: 2600)
        #expect(segments == [
            SkipSegment(kind: .recap, start: 0, end: 45, source: .chapters),
            SkipSegment(kind: .intro, start: 45, end: 120, source: .chapters),
            SkipSegment(kind: .credits, start: 2500, end: nil, source: .chapters),
        ])
    }

    @Test func adjacentChaptersOfOneKindJoin() {
        let chapters = [ChapterMark(title: "OP part 1", start: 60), ChapterMark(title: "OP part 2", start: 90),
                        ChapterMark(title: "Part A", start: 150)]
        #expect(SkipSegments.fromChapters(chapters, duration: 1440) == [SkipSegment(kind: .intro, start: 60, end: 150, source: .chapters)])
    }

    @Test func misplacedChaptersAreDropped() {
        // An "Ending" chapter in the first minutes is a story title, not credits.
        let segments = SkipSegments.fromChapters([ChapterMark(title: "Ending", start: 30), ChapterMark(title: "Act 1", start: 200)],
                                                 duration: 3000)
        #expect(SkipSegments.merge(segments, duration: 3000).isEmpty)
    }
}

@Suite("Skip intro: databases")
struct SkipDatabaseParsingTests {
    static func json(_ text: String) -> JSONObject {
        JSONObject(try? JSONSerialization.jsonObject(with: Data(text.utf8)))!
    }

    @Test func parsesTheIntroDB() {
        // Recorded from api.theintrodb.org/v4/media?imdb_id=tt0108778&season=1&episode=1 (2026-10-30).
        let response = Self.json(#"{"tvdb_id":79168,"type":"tv","season":1,"episode":1,"intro":[{"start_ms":null,"end_ms":46000}],"credits":[{"start_ms":1359000,"end_ms":null}]}"#)
        #expect(SkipSegmentService.parseTheIntroDB(response) == [
            SkipSegment(kind: .intro, start: 0, end: 46, source: .theIntroDB),
            SkipSegment(kind: .credits, start: 1359, end: nil, source: .theIntroDB),
        ])
    }

    @Test func parsesIntroDB() {
        // Recorded from api.introdb.app/segments?imdb_id=tt0944947&season=1&episode=1 (2026-10-30).
        let response = Self.json(#"{"imdb_id":"tt0944947","media_type":"tv","is_movie":false,"season":1,"episode":1,"intro":{"start_sec":437,"end_sec":531,"start_ms":437000,"end_ms":531000,"confidence":1,"submission_count":2,"updated_at":"2026-06-16T02:49:39.823Z"},"recap":null,"outro":{"start_sec":3631.5,"end_sec":3699.5,"start_ms":3631500,"end_ms":3699500,"confidence":1,"submission_count":2,"updated_at":"2026-04-08T18:48:22.562Z"},"post_credits":null,"no_intro":false,"no_recap":true,"no_outro":false}"#)
        #expect(SkipSegmentService.parseIntroDB(response) == [
            SkipSegment(kind: .intro, start: 437, end: 531, source: .introDB),
            SkipSegment(kind: .credits, start: 3631.5, end: 3699.5, source: .introDB),
        ])
        #expect(SkipSegmentService.parseIntroDB(Self.json(#"{"intro":null,"recap":null,"outro":null}"#)).isEmpty)
    }

    @Test func requestURLs() {
        let episode = SkipSegmentService.Lookup(mediaId: "src_e1", imdbId: "tt0944947", tmdbId: "1399", season: 1, episode: 2)
        #expect(SkipSegmentService.theIntroDBURL(episode) == "https://api.theintrodb.org/v4/media?imdb_id=tt0944947&season=1&episode=2")
        #expect(SkipSegmentService.introDBURL(episode) == "https://api.introdb.app/segments?imdb_id=tt0944947&season=1&episode=2")
        let movie = SkipSegmentService.Lookup(mediaId: "src_m1", imdbId: nil, tmdbId: "27205")
        #expect(SkipSegmentService.theIntroDBURL(movie) == "https://api.theintrodb.org/v4/media?tmdb_id=27205")
        #expect(SkipSegmentService.introDBURL(movie) == nil)
        let imdbMovie = SkipSegmentService.Lookup(mediaId: "src_m2", imdbId: "TT1375666", tmdbId: nil)
        #expect(SkipSegmentService.introDBURL(imdbMovie) == "https://api.introdb.app/segments?imdb_id=tt1375666&is_movie=true")
        #expect(SkipSegmentService.Lookup(mediaId: "x", imdbId: "nm123", tmdbId: "0").canLookUp == false)
    }
}

@Suite("Skip intro: sanity checks and merge")
struct SkipMergeTests {
    let duration: Double = 2700 // 45 min

    @Test func plausibleTimingsPass() {
        let intro = SkipSegment(kind: .intro, start: 60, end: 120, source: .theIntroDB)
        let credits = SkipSegment(kind: .credits, start: 2600, end: nil, source: .theIntroDB)
        #expect(SkipSegments.sanitized(intro, duration: duration) == intro)
        #expect(SkipSegments.sanitized(credits, duration: duration) == credits)
    }

    @Test func implausibleTimingsAreDropped() {
        // Intro ending after the first quarter, after 10 minutes, too short, or too long.
        #expect(SkipSegments.sanitized(SkipSegment(kind: .intro, start: 600, end: 700, source: .introDB), duration: duration) == nil)
        #expect(SkipSegments.sanitized(SkipSegment(kind: .intro, start: 500, end: 640, source: .introDB), duration: 7200) == nil)
        #expect(SkipSegments.sanitized(SkipSegment(kind: .intro, start: 10, end: 12, source: .introDB), duration: duration) == nil)
        #expect(SkipSegments.sanitized(SkipSegment(kind: .intro, start: 0, end: 400, source: .introDB), duration: duration) == nil)
        // Credits not in the last 15 %, or beyond the end of this (shorter) encode.
        #expect(SkipSegments.sanitized(SkipSegment(kind: .credits, start: 2000, end: nil, source: .introDB), duration: duration) == nil)
        #expect(SkipSegments.sanitized(SkipSegment(kind: .credits, start: 2650, end: 2800, source: .introDB), duration: duration) == nil)
        #expect(SkipSegments.sanitized(SkipSegment(kind: .credits, start: 2800, end: nil, source: .introDB), duration: duration) == nil)
        // Credits need the duration; an intro without an end is meaningless.
        #expect(SkipSegments.sanitized(SkipSegment(kind: .credits, start: 2600, end: nil, source: .introDB), duration: nil) == nil)
        #expect(SkipSegments.sanitized(SkipSegment(kind: .intro, start: 0, end: nil, source: .introDB), duration: duration) == nil)
    }

    @Test func endsAreClampedToTheDuration() {
        let credits = SkipSegment(kind: .credits, start: 2600, end: 2701, source: .introDB)
        #expect(SkipSegments.sanitized(credits, duration: duration)?.end == 2700)
    }

    @Test func chaptersWinThenTheIntroDBThenIntroDBThenLearned() {
        let candidates = [
            SkipSegment(kind: .intro, start: 50, end: 110, source: .learned, mayAutoSkip: false),
            SkipSegment(kind: .intro, start: 61, end: 118, source: .introDB),
            SkipSegment(kind: .intro, start: 60, end: 120, source: .theIntroDB),
            SkipSegment(kind: .credits, start: 2610, end: nil, source: .introDB),
            SkipSegment(kind: .recap, start: 0, end: 40, source: .chapters),
        ]
        #expect(SkipSegments.merge(candidates, duration: duration) == [
            SkipSegment(kind: .recap, start: 0, end: 40, source: .chapters),
            SkipSegment(kind: .intro, start: 60, end: 120, source: .theIntroDB),
            SkipSegment(kind: .credits, start: 2610, end: nil, source: .introDB),
        ])
    }

    @Test func aSourceWithAnImplausibleTimingFallsThrough() {
        // TheIntroDB's timing belongs to a longer cut; IntroDB's fits this file.
        let candidates = [
            SkipSegment(kind: .credits, start: 3400, end: nil, source: .theIntroDB),
            SkipSegment(kind: .credits, start: 2620, end: 2700, source: .introDB),
        ]
        #expect(SkipSegments.merge(candidates, duration: duration) == [SkipSegment(kind: .credits, start: 2620, end: 2700, source: .introDB)])
    }
}

@Suite("Skip intro: tracker")
struct SkipTrackerTests {
    let intro = SkipSegment(kind: .intro, start: 60, end: 120, source: .theIntroDB)
    let credits = SkipSegment(kind: .credits, start: 2600, end: nil, source: .theIntroDB)

    @Test func buttonIsFreshForTheFirstSecondsOfASegment() {
        var tracker = SkipTracker(segments: [intro, credits])
        #expect(tracker.update(position: 30, duration: 2700, mode: .button, autoSkipCredits: false).prompt == nil)
        let entered = tracker.update(position: 61, duration: 2700, mode: .button, autoSkipCredits: false)
        #expect(entered.prompt == SkipTracker.Prompt(segment: intro, isFresh: true))
        #expect(entered.action == .none)
        #expect(tracker.update(position: 70, duration: 2700, mode: .button, autoSkipCredits: false).prompt?.isFresh == false)
        // Leaving and coming back shows it fresh again.
        _ = tracker.update(position: 130, duration: 2700, mode: .button, autoSkipCredits: false)
        #expect(tracker.update(position: 90, duration: 2700, mode: .button, autoSkipCredits: false).prompt?.isFresh == true)
        // Nothing in the last moments of a segment, nothing when off.
        #expect(tracker.update(position: 119.5, duration: 2700, mode: .button, autoSkipCredits: false).prompt == nil)
        #expect(tracker.update(position: 90, duration: 2700, mode: .off, autoSkipCredits: false).prompt == nil)
        #expect(tracker.update(position: 2650, duration: 2700, mode: .button, autoSkipCredits: false).prompt?.segment == credits)
    }

    @Test func automaticSkipsOnceAndNotAfterUndo() {
        var tracker = SkipTracker(segments: [intro])
        #expect(tracker.update(position: 60.2, duration: 2700, mode: .automatic, autoSkipCredits: false).action == .autoSkip(intro))
        // Undo: back to the start of the intro, which now shows the button instead.
        tracker.undoAutoSkip(intro)
        let after = tracker.update(position: 60.5, duration: 2700, mode: .automatic, autoSkipCredits: false)
        #expect(after.action == .none)
        #expect(after.prompt?.segment == intro)
    }

    @Test func seekingIntoASegmentMeansWatchingIt() {
        var tracker = SkipTracker(segments: [intro])
        tracker.userSeeked(to: 80, duration: 2700)
        #expect(tracker.update(position: 80, duration: 2700, mode: .automatic, autoSkipCredits: false).action == .none)
    }

    @Test func creditsAndUnconfirmedLearnedIntrosAreNotSkippedAutomatically() {
        let learned = SkipSegment(kind: .intro, start: 60, end: 120, source: .learned, mayAutoSkip: false)
        var tracker = SkipTracker(segments: [learned, credits])
        #expect(tracker.update(position: 61, duration: 2700, mode: .automatic, autoSkipCredits: true).action == .none)
        #expect(tracker.update(position: 2601, duration: 2700, mode: .automatic, autoSkipCredits: false).action == .none)
        var episode = SkipTracker(segments: [credits])
        #expect(episode.update(position: 2601, duration: 2700, mode: .automatic, autoSkipCredits: true).action == .autoSkip(credits))
    }
}

@Suite("Skip intro: learning")
struct SkipLearnerTests {
    @Test func onlyEarlyMediumSkipsCount() {
        #expect(SkipLearner.isIntroSkip(from: 60, to: 120, duration: 2700))
        #expect(!SkipLearner.isIntroSkip(from: 60, to: 70, duration: 2700))       // too short
        #expect(!SkipLearner.isIntroSkip(from: 60, to: 300, duration: 2700))      // longer than 3 minutes
        #expect(!SkipLearner.isIntroSkip(from: 600, to: 660, duration: 2700))     // after the first 15 %
        #expect(!SkipLearner.isIntroSkip(from: 60, to: 120, duration: nil))
    }

    @Test func twoEpisodesAgreeingMakeAnIntro() {
        let spans = [
            LearnedSkipSpan(episodeId: "e1", start: 62, end: 121),
            LearnedSkipSpan(episodeId: "e2", start: 58, end: 125),
            LearnedSkipSpan(episodeId: "e3", start: 400, end: 520), // a different skip
        ]
        let intro = SkipLearner.suggestedIntro(from: spans)
        #expect(intro == SkipSegment(kind: .intro, start: 60, end: 123, source: .learned, mayAutoSkip: false))
    }

    @Test func oneEpisodeOrDisagreeingSpansAreNotEnough() {
        #expect(SkipLearner.suggestedIntro(from: [LearnedSkipSpan(episodeId: "e1", start: 60, end: 120),
                                                  LearnedSkipSpan(episodeId: "e1", start: 61, end: 121, confirmed: true)]) == nil)
        #expect(SkipLearner.suggestedIntro(from: [LearnedSkipSpan(episodeId: "e1", start: 60, end: 120),
                                                  LearnedSkipSpan(episodeId: "e2", start: 75, end: 120)]) == nil)
    }

    @Test func twoConfirmationsAllowAutoSkip() {
        let spans = [
            LearnedSkipSpan(episodeId: "e1", start: 60, end: 120), LearnedSkipSpan(episodeId: "e2", start: 61, end: 121),
            LearnedSkipSpan(episodeId: "e3", start: 60, end: 120, confirmed: true),
        ]
        #expect(SkipLearner.suggestedIntro(from: spans)?.mayAutoSkip == false)
        let confirmed = spans + [LearnedSkipSpan(episodeId: "e4", start: 60, end: 120, confirmed: true)]
        #expect(SkipLearner.suggestedIntro(from: confirmed)?.mayAutoSkip == true)
    }

    @Test func quickSeeksJoinIntoOneSpan() {
        var chain = ForwardSeekChain()
        let t0 = Date(timeIntervalSince1970: 0)
        // → pressed six times; the reported position lags behind.
        #expect(chain.seek(from: 60, to: 70, at: t0) == nil)
        #expect(chain.seek(from: 60, to: 80, at: t0.addingTimeInterval(0.4)) == nil)
        #expect(chain.seek(from: 80, to: 90, at: t0.addingTimeInterval(0.8)) == nil)
        #expect(chain.seek(from: 90, to: 120, at: t0.addingTimeInterval(1.5)) == nil)
        #expect(chain.finished(at: t0.addingTimeInterval(2)) == nil)
        let span = chain.finished(at: t0.addingTimeInterval(5))
        #expect(span?.from == 60 && span?.to == 120)
        #expect(chain.finished(at: t0.addingTimeInterval(9)) == nil)
    }

    @Test func aLaterSeekStartsANewChain() {
        var chain = ForwardSeekChain()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = chain.seek(from: 60, to: 120, at: t0)
        let first = chain.seek(from: 900, to: 960, at: t0.addingTimeInterval(30))
        #expect(first?.from == 60 && first?.to == 120)
        // A backward seek ends the chain without a span of its own.
        let second = chain.seek(from: 960, to: 100, at: t0.addingTimeInterval(60))
        #expect(second?.from == 900 && second?.to == 960)
        #expect(chain.flush() == nil)
    }
}

@Suite("Skip intro: service and cache")
struct SkipSegmentServiceTests {
    let db: AppDatabase
    let lookup = SkipSegmentService.Lookup(mediaId: "src_e1", imdbId: "tt0108778", tmdbId: nil, season: 1, episode: 1)

    init() throws {
        db = try AppDatabase.inMemory()
    }

    static let theIntroDB = #"{"tvdb_id":79168,"type":"tv","season":1,"episode":1,"intro":[{"start_ms":null,"end_ms":46000}]}"#
    static let introDB = #"{"intro":{"start_ms":0,"end_ms":47000},"recap":null,"outro":{"start_ms":1360000,"end_ms":1366000}}"#

    static func network(theIntroDB: String?, introDB: String?, failing: Bool = false) -> StubNetwork {
        StubNetwork { url in
            if failing { throw URLError(.notConnectedToInternet) }
            let body = url.contains("theintrodb") ? theIntroDB : introDB
            guard let body else { throw HTTPError.status(404, url: url) }
            return SkipDatabaseParsingTests.json(body)
        }
    }

    @Test func fetchesBothDatabasesAndCaches() async throws {
        let network = Self.network(theIntroDB: Self.theIntroDB, introDB: Self.introDB)
        let service = SkipSegmentService(db: db, fetch: network.fetch)
        let segments = await service.segments(for: lookup, allowNetwork: true)
        #expect(segments.count == 3)
        #expect(Set(segments.map(\.source)) == [.theIntroDB, .introDB])
        #expect(network.requests.count == 2)
        // Second play: from the cache.
        _ = await service.segments(for: lookup, allowNetwork: true)
        #expect(network.requests.count == 2)
        // Merged for a 23-minute file: TheIntroDB's intro, IntroDB's credits.
        #expect(SkipSegments.merge(segments, duration: 1380) == [
            SkipSegment(kind: .intro, start: 0, end: 46, source: .theIntroDB),
            SkipSegment(kind: .credits, start: 1360, end: 1366, source: .introDB),
        ])
    }

    @Test func notFoundIsCachedForAWeek() async throws {
        let clock = ChartClock(Date(timeIntervalSince1970: 1_800_000_000))
        let network = Self.network(theIntroDB: nil, introDB: #"{"intro":null,"recap":null,"outro":null}"#)
        let service = SkipSegmentService(db: db, fetch: network.fetch, now: { clock.now })
        #expect(await service.segments(for: lookup, allowNetwork: true).isEmpty)
        clock.now = clock.now.addingTimeInterval(6 * 86_400)
        _ = await service.segments(for: lookup, allowNetwork: true)
        #expect(network.requests.count == 2)
        clock.now = clock.now.addingTimeInterval(2 * 86_400)
        _ = await service.segments(for: lookup, allowNetwork: true)
        #expect(network.requests.count == 4)
    }

    @Test func failuresAreNotCachedAndOfflineUsesTheCache() async throws {
        let failing = Self.network(theIntroDB: nil, introDB: nil, failing: true)
        let service = SkipSegmentService(db: db, fetch: failing.fetch)
        #expect(await service.segments(for: lookup, allowNetwork: true).isEmpty)
        #expect(try await db.skipSegmentCache(mediaId: lookup.mediaId) == nil)

        try await db.saveSkipSegments([SkipSegment(kind: .intro, start: 0, end: 46, source: .theIntroDB)], mediaId: lookup.mediaId,
                                      at: Date(timeIntervalSince1970: 0))
        // Offline (or lookups off): the stale cache, no request.
        let offline = await service.segments(for: lookup, allowNetwork: false)
        #expect(offline.count == 1)
        #expect(failing.requests.count == 2)
    }

    @Test func noIdsMeansNoRequest() async {
        let network = Self.network(theIntroDB: Self.theIntroDB, introDB: Self.introDB)
        let service = SkipSegmentService(db: db, fetch: network.fetch)
        let anonymous = SkipSegmentService.Lookup(mediaId: "src_e2", imdbId: nil, tmdbId: nil, season: 1, episode: 2)
        #expect(await service.segments(for: anonymous, allowNetwork: true).isEmpty)
        #expect(network.requests.isEmpty)
    }

    @Test func learnedSpansAreStoredPerEpisode() async throws {
        let service = SkipSegmentService(db: db, fetch: Self.network(theIntroDB: nil, introDB: nil).fetch)
        await service.record(LearnedSkipSpan(episodeId: "e1", start: 60, end: 120), seriesId: "s1")
        #expect(await service.learnedIntro(seriesId: "s1") == nil)
        // A newer skip in the same episode replaces the older one.
        await service.record(LearnedSkipSpan(episodeId: "e1", start: 300, end: 400), seriesId: "s1")
        await service.record(LearnedSkipSpan(episodeId: "e2", start: 62, end: 118), seriesId: "s1")
        #expect(await service.learnedIntro(seriesId: "s1") == nil)
        await service.record(LearnedSkipSpan(episodeId: "e1", start: 61, end: 119), seriesId: "s1")
        #expect(await service.learnedIntro(seriesId: "s1") == SkipSegment(kind: .intro, start: 61.5, end: 118.5, source: .learned,
                                                                          mayAutoSkip: false))
        #expect(await service.learnedIntro(seriesId: "other") == nil)
    }
}
