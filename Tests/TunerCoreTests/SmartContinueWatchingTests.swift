import Foundation
import GRDB
import Testing
@testable import TunerCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400

private func ep(_ season: Int, _ number: Int, show: String = "show") -> Episode {
    Episode(id: "\(show)-s\(season)e\(number)", seriesId: show, sourceId: "src", season: season, number: number,
            title: "Episode \(number)", providerId: "\(season)-\(number)")
}

/// An episode record `ago` seconds old; `position` of 2400 s (40 min).
private func episode(_ season: Int, _ number: Int, show: String = "show", position: Double, completed: Bool = false,
                     ago: TimeInterval, duration: Double = 2400) -> WatchProgress {
    WatchProgress(mediaId: "\(show)-s\(season)e\(number)", kind: .episode, sourceId: "src", seriesId: show, title: show,
                  subtitle: "S\(season), E\(number) · Episode \(number)", position: position, duration: duration,
                  completed: completed, updatedAt: now.addingTimeInterval(-ago))
}

private func finished(_ season: Int, _ number: Int, show: String = "show", ago: TimeInterval) -> WatchProgress {
    episode(season, number, show: show, position: 2400, completed: true, ago: ago)
}

/// A two-hour movie record.
private func movie(_ id: String, position: Double, ago: TimeInterval, duration: Double = 7200) -> WatchProgress {
    WatchProgress(mediaId: id, kind: .movie, sourceId: "src", title: id, position: position, duration: duration,
                  updatedAt: now.addingTimeInterval(-ago))
}

/// Two seasons of three episodes, plus a special.
private let showEpisodes = ["show": [ep(1, 1), ep(1, 2), ep(1, 3), ep(2, 1), ep(2, 2), ep(2, 3), ep(0, 1)]]

private func rank(_ progress: [WatchProgress], episodes: [String: [Episode]] = showEpisodes, limit: Int = 20) -> [SmartContinueWatching.Entry] {
    SmartContinueWatching.rank(progress: progress, episodes: episodes, now: now, limit: limit)
}

/// "next:<episode id>" or "resume:<media id>", for compact expectations.
private func ids(_ entries: [SmartContinueWatching.Entry]) -> [String] {
    entries.map {
        switch $0 {
        case .resume(let p): "resume:\(p.mediaId)"
        case .nextEpisode(let e, _): "next:\(e.id)"
        }
    }
}

@Suite("Smart Continue Watching: next episodes")
struct SmartContinueWatchingNextEpisodeTests {
    @Test func finishingAnEpisodeOffersTheNextOne() {
        let entries = rank([finished(1, 1, ago: hour * 2), finished(1, 2, ago: hour)])
        #expect(ids(entries) == ["next:show-s1e3"])
        guard case .nextEpisode(_, let after) = entries.first else { Issue.record("not a next episode"); return }
        #expect(after.mediaId == "show-s1e2")
    }

    @Test func aSeasonFinaleLeadsIntoTheNextSeason() {
        #expect(ids(rank([finished(1, 3, ago: hour)])) == ["next:show-s2e1"])
    }

    @Test func theLastCachedEpisodeLeavesTheRow() {
        #expect(rank([finished(2, 3, ago: hour)]).isEmpty)
    }

    @Test func noCachedEpisodesMeansNoCard() {
        #expect(rank([finished(1, 1, ago: hour)], episodes: [:]).isEmpty)
        // …nor when the finished episode isn't in the cached list.
        #expect(rank([finished(5, 1, ago: hour)]).isEmpty)
    }

    @Test func aNextEpisodeAlreadyWatchedIsSkipped() {
        // S1E3 was watched long ago; S1E2 was just rewatched.
        #expect(rank([finished(1, 3, ago: day * 30), finished(1, 2, ago: hour)]).isEmpty)
    }

    @Test func aNextEpisodeWithAResumePointIsResumed() {
        // S1E3 was started, then S1E2 rewatched to the end: carry on with S1E3 where it was left.
        let entries = rank([episode(1, 3, position: 600, ago: day), finished(1, 2, ago: hour)])
        #expect(ids(entries) == ["resume:show-s1e3"])
    }

    @Test func anUnfinishedLatestEpisodeIsResumedAsToday() {
        let entries = rank([finished(1, 1, ago: day), episode(1, 2, position: 900, ago: hour)])
        #expect(ids(entries) == ["resume:show-s1e2"])
    }

    @Test func aFewSecondsOfPlayDoNotCount() {
        // The next episode was opened for 8 s after finishing S1E2: still offered, from the start.
        #expect(ids(rank([finished(1, 2, ago: hour), episode(1, 3, position: 8, ago: 60)])) == ["next:show-s1e3"])
        // An unfinished episode before it is still resumed.
        #expect(ids(rank([episode(1, 2, position: 900, ago: hour), episode(2, 2, position: 8, ago: 60)])) == ["resume:show-s1e2"])
    }

    @Test func aResetRecordTakesTheShowOut() {
        // "Remove from Continue Watching" and "Mark as Unwatched" leave a record at the start.
        #expect(rank([finished(1, 2, ago: hour), episode(1, 3, position: 0, ago: 60)]).isEmpty)
        #expect(rank([finished(1, 1, ago: day), episode(1, 2, position: 0, ago: 60)]).isEmpty)
    }

    @Test func aSeasonMarkedWatchedAtOnceContinuesAfterItsLastEpisode() {
        let marked = [finished(1, 2, ago: hour), finished(1, 3, ago: hour), finished(1, 1, ago: hour)]
        #expect(ids(rank(marked)) == ["next:show-s2e1"])
    }

    @Test func specialsStepThroughSpecials() {
        let episodes = ["show": [ep(1, 1), ep(0, 1), ep(0, 2)]]
        #expect(ids(rank([finished(0, 1, ago: hour)], episodes: episodes)) == ["next:show-s0e2"])
    }

    @Test func onlyShowsEndingOnAFinishedEpisodeNeedTheirEpisodes() {
        let progress = [finished(1, 1, show: "a", ago: hour), episode(1, 2, show: "b", position: 600, ago: hour),
                        finished(1, 1, show: "c", ago: day), episode(1, 2, show: "c", position: 0, ago: hour),
                        movie("m", position: 600, ago: hour)]
        #expect(SmartContinueWatching.showsNeedingEpisodes(progress) == ["a"])
    }

    @Test func theNextEpisodeRecordDescribesTheCard() {
        var next = ep(2, 4)
        next.title = "The Return"
        next.durationSeconds = 2700
        var series = Series(id: "show", sourceId: "src", categoryId: nil, name: "The Show", providerId: "1", providerOrder: 0)
        series.backdropURL = "http://img/backdrop.jpg"
        let record = SmartContinueWatching.nextEpisodeRecord(next, series: series, after: finished(2, 3, ago: hour))
        #expect(record.mediaId == next.id)
        #expect(record.kind == .episode)
        #expect(record.seriesId == "show")
        #expect(record.title == "The Show")
        #expect(record.subtitle == "S2, E4 · The Return")
        #expect(record.posterURL == "http://img/backdrop.jpg")
        #expect(record.position == 0 && record.duration == 2700 && !record.completed)
        #expect(record.updatedAt == now.addingTimeInterval(-hour))
        // The episode's own still wins over the show's artwork.
        next.imageURL = "http://img/still.jpg"
        #expect(SmartContinueWatching.nextEpisodeRecord(next, series: series, after: finished(2, 3, ago: hour)).posterURL == "http://img/still.jpg")
    }
}

@Suite("Smart Continue Watching: order and abandoned titles")
struct SmartContinueWatchingOrderTests {
    @Test func nearlyFinishedAndRecentNextEpisodesComeFirst() {
        let progress = [
            movie("fresh", position: 1800, ago: hour),                   // 25 %, newest: recency only
            movie("nearly", position: 5600, ago: day * 3),               // 78 %: first
            movie("lastBit", position: 6100, ago: day * 2),              // 85 %: first
            finished(1, 1, show: "weekly", ago: day * 5),                // next episode, watched this week: first
            finished(1, 1, show: "old", ago: day * 10),                  // next episode, not this week: recency
            movie("middle", position: 3600, ago: day * 4),               // 50 %: recency
        ]
        let episodes = ["weekly": [ep(1, 1, show: "weekly"), ep(1, 2, show: "weekly")],
                        "old": [ep(1, 1, show: "old"), ep(1, 2, show: "old")]]
        #expect(ids(rank(progress, episodes: episodes)) == [
            "resume:lastBit", "resume:nearly", "next:weekly-s1e2",  // boosted, by recency
            "resume:fresh", "resume:middle", "next:old-s1e2",       // the rest, by recency
        ])
    }

    @Test func shortTimeLeftCountsAsNearlyFinished() {
        // A 22-minute episode with 10 minutes left jumps ahead of a newer half-watched movie.
        let progress = [movie("movie", position: 3600, ago: hour),
                        episode(1, 1, position: 720, ago: day, duration: 1320)]
        #expect(ids(rank(progress)) == ["resume:show-s1e1", "resume:movie"])
    }

    @Test func nearlyFinishedTitlesStopJumpingTheQueueAfterAMonth() {
        let progress = [movie("stale", position: 6000, ago: day * 40), movie("fresh", position: 1800, ago: day * 2)]
        #expect(ids(rank(progress)) == ["resume:fresh", "resume:stale"])
    }

    @Test func titlesStoppedEarlyAndUntouchedForThreeWeeksAreLeftOut() {
        let progress = [
            movie("abandoned", position: 600, ago: day * 22),              // 8 %, 22 days: out
            movie("recentStart", position: 600, ago: day * 20),            // 8 %, 20 days: kept
            movie("halfway", position: 3600, ago: day * 60),               // 50 %, 60 days: kept
            episode(1, 1, show: "dropped", position: 200, ago: day * 30),  // 8 %, 30 days: out
        ]
        #expect(ids(rank(progress)) == ["resume:recentStart", "resume:halfway"])
    }

    @Test func aResumedNextEpisodeIsJudgedByTheShowsLatestActivity() {
        // S1E3 was started (10 %) 40 days ago, but S1E2 was rewatched yesterday: the show isn't abandoned.
        let progress = [episode(1, 3, position: 240, ago: day * 40), finished(1, 2, ago: day)]
        #expect(ids(rank(progress)) == ["resume:show-s1e3"])
    }

    @Test func nextEpisodesOfOldShowsStay() {
        #expect(ids(rank([finished(1, 1, ago: day * 90)])) == ["next:show-s1e2"])
    }

    @Test func oneEntryPerShowAndTheLimitApplies() {
        var progress = (1...30).map { movie("m\($0)", position: 3000, ago: Double($0) * hour) }
        progress += [episode(1, 1, position: 600, ago: hour * 5), episode(1, 2, position: 600, ago: hour * 1.5)]
        let entries = rank(progress, limit: 5)
        #expect(ids(entries) == ["resume:m1", "resume:show-s1e2", "resume:m2", "resume:m3", "resume:m4"])
    }

    @Test func finishedMoviesAndUnstartedOnesAreNotListed() {
        var done = movie("done", position: 7200, ago: hour)
        done.completed = true
        #expect(rank([done, movie("barely", position: 8, ago: hour)]).isEmpty)
    }
}

@Suite("Smart Continue Watching: database")
struct SmartContinueWatchingDatabaseTests {
    let db: AppDatabase

    init() async throws {
        db = try AppDatabase.inMemory()
        try await db.save(Source(id: "src", name: "Test", kind: .m3u, url: "http://example.com/list.m3u"))
        var series = Series(id: "show", sourceId: "src", categoryId: nil, name: "The Show", providerId: "show", providerOrder: 0)
        series.coverURL = "http://img/cover.jpg"
        try await db.replaceSeries(sourceId: "src", categories: [], series: [series])
        var episodes = [ep(1, 1), ep(1, 2), ep(1, 3)]
        episodes[2].plot = "Things happen."
        episodes[2].durationSeconds = 2500
        try await db.replaceEpisodes(seriesId: "show", episodes: episodes)
    }

    private func save(_ records: [WatchProgress]) async throws {
        try await db.writer.write { db in for r in records { try r.save(db) } }
    }

    /// A mixed history: a finished episode (with an older abandoned one), a half-watched movie, an abandoned movie,
    /// a nearly finished movie.
    private func seedHistory() async throws {
        let realNow = Date()
        func at(_ p: WatchProgress, ago: TimeInterval) -> WatchProgress { var p = p; p.updatedAt = realNow.addingTimeInterval(-ago); return p }
        try await save([
            at(episode(1, 1, position: 200, ago: 0), ago: day * 30),
            at(finished(1, 2, ago: 0), ago: hour),
            at(movie("half", position: 3600, ago: 0), ago: hour * 2),
            at(movie("abandoned", position: 300, ago: 0), ago: day * 25),
            at(movie("nearly", position: 6000, ago: 0), ago: hour * 3),
        ])
    }

    @Test func smartRowOffersTheNextEpisodeWithItsDetails() async throws {
        try await seedHistory()
        let items = try await db.smartContinueWatching()
        #expect(items.map(\.id) == ["show-s1e3", "nearly", "half"]) // the abandoned movie is left out
        guard case .nextEpisode(let next, let record) = items.first else { Issue.record("not a next episode"); return }
        #expect(next.plot == "Things happen.") // full row, not the order-only one
        #expect(next.durationSeconds == 2500)
        #expect(record.title == "The Show")
        #expect(record.subtitle == "S1, E3 · Episode 3")
        #expect(record.posterURL == "http://img/cover.jpg")
        #expect(record.position == 0)
    }

    @Test func offRowIsUnchanged() async throws {
        try await seedHistory()
        // Today's query: unfinished items by recency (the abandoned ones included), no next episodes.
        let items = try await db.continueWatching()
        #expect(items.map(\.mediaId) == ["half", "nearly", "abandoned", "show-s1e1"])
    }

    @Test func removingANextEpisodeCardKeepsItOut() async throws {
        try await seedHistory()
        let items = try await db.smartContinueWatching()
        guard case .nextEpisode(_, let record) = items.first else { Issue.record("not a next episode"); return }
        // The app removes a card by marking its record unwatched (the finished episode stays watched).
        try await db.markWatched(record, watched: false)
        #expect(try await db.smartContinueWatching().map(\.id) == ["nearly", "half"])
        #expect(try await db.progress(mediaId: "show-s1e2")?.completed == true)
        // Today's row doesn't show the not-started record either.
        #expect(try await db.continueWatching().map(\.mediaId) == ["half", "nearly", "abandoned", "show-s1e1"])
    }

    @Test func markingTheNextEpisodeWatchedMovesOn() async throws {
        try await save([finished(1, 1, ago: 0).with(updatedAt: Date().addingTimeInterval(-hour))])
        var items = try await db.smartContinueWatching()
        #expect(items.map(\.id) == ["show-s1e2"])
        try await db.markWatched(items[0].progress, watched: true)
        items = try await db.smartContinueWatching()
        #expect(items.map(\.id) == ["show-s1e3"])
        try await db.markWatched(items[0].progress, watched: true)
        #expect(try await db.smartContinueWatching().isEmpty) // finale: the show leaves the row
    }

    @Test func episodesAreNotFetchedFromTheNetwork() async throws {
        // A show without cached episodes: its finished episode gives no card (and nothing else is asked for).
        try await save([finished(1, 1, show: "uncached", ago: 0).with(updatedAt: Date())])
        #expect(try await db.smartContinueWatching().isEmpty)
    }
}

private extension WatchProgress {
    func with(updatedAt: Date) -> WatchProgress { var p = self; p.updatedAt = updatedAt; return p }
}
