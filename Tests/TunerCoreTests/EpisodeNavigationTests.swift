import Testing
@testable import TunerCore

@Suite("Episode navigation")
struct EpisodeNavigationTests {
    static func ep(_ season: Int, _ number: Int) -> Episode {
        Episode(id: "s\(season)e\(number)", seriesId: "show", sourceId: "src", season: season, number: number,
                title: "S\(season)E\(number)", providerId: "\(season)-\(number)")
    }

    /// Deliberately unordered, with specials and a gap (no S2E2).
    let episodes = [ep(2, 1), ep(1, 2), ep(0, 1), ep(1, 1), ep(2, 3), ep(0, 2)]

    @Test func nextCrossesIntoTheNextSeason() {
        #expect(EpisodeNavigation.neighbor(of: "s1e2", in: episodes, offset: 1)?.id == "s2e1")
        #expect(EpisodeNavigation.neighbor(of: "s2e1", in: episodes, offset: 1)?.id == "s2e3") // skips the gap
    }

    @Test func previousCrossesBackIntoThePreviousSeason() {
        #expect(EpisodeNavigation.neighbor(of: "s2e1", in: episodes, offset: -1)?.id == "s1e2")
    }

    @Test func endsOfTheListHaveNoNeighbour() {
        #expect(EpisodeNavigation.neighbor(of: "s1e1", in: episodes, offset: -1) == nil)
        #expect(EpisodeNavigation.neighbor(of: "s2e3", in: episodes, offset: 1) == nil)
        #expect(EpisodeNavigation.neighbor(of: "missing", in: episodes, offset: 1) == nil)
    }

    @Test func specialsAreSkippedUnlessYouAreWatchingOne() {
        // From a regular episode, specials (season 0) never come up…
        #expect(EpisodeNavigation.neighbor(of: "s1e1", in: episodes, offset: 1)?.id == "s1e2")
        // …but while watching a special, next/previous move through the specials.
        #expect(EpisodeNavigation.neighbor(of: "s0e1", in: episodes, offset: 1)?.id == "s0e2")
        #expect(EpisodeNavigation.neighbor(of: "s0e2", in: episodes, offset: 1) == nil)
    }
}

@Suite("Mark earlier episodes watched")
struct EarlierEpisodesTests {
    let episodes = [EpisodeNavigationTests.ep(1, 1), EpisodeNavigationTests.ep(1, 2), EpisodeNavigationTests.ep(2, 1),
                    EpisodeNavigationTests.ep(2, 2), EpisodeNavigationTests.ep(0, 1)]

    @Test func listsUnwatchedEpisodesBeforeIncludingEarlierSeasons() {
        let earlier = EpisodeNavigation.unwatched(before: "s2e2", in: episodes, watched: ["s1e2"])
        #expect(earlier.map(\.id) == ["s1e1", "s2e1"]) // in watch order; S1E2 already watched; no specials
    }

    @Test func nothingToAskForTheFirstEpisodeOrWhenAllAreWatched() {
        #expect(EpisodeNavigation.unwatched(before: "s1e1", in: episodes, watched: []).isEmpty)
        #expect(EpisodeNavigation.unwatched(before: "s2e2", in: episodes, watched: ["s1e1", "s1e2", "s2e1"]).isEmpty)
        #expect(EpisodeNavigation.unwatched(before: "missing", in: episodes, watched: []).isEmpty)
    }

    @Test func specialsOnlyAskAboutEarlierSpecials() {
        #expect(EpisodeNavigation.unwatched(before: "s0e1", in: episodes, watched: []).isEmpty)
    }
}

@Suite("Up Next countdown")
struct UpNextCountdownTests {
    @Test func showsOnlyDuringTheLastSecondsRoundedUp() {
        #expect(UpNextCountdown.secondsLeft(position: 1300, duration: 1320, countdown: 10) == nil) // 20 s left
        #expect(UpNextCountdown.secondsLeft(position: 1310, duration: 1320, countdown: 10) == 10)
        #expect(UpNextCountdown.secondsLeft(position: 1316.2, duration: 1320, countdown: 10) == 4)
        #expect(UpNextCountdown.secondsLeft(position: 1319.9, duration: 1320, countdown: 10) == 1)
    }

    @Test func hiddenWhenOffFinishedOrUnknown() {
        #expect(UpNextCountdown.secondsLeft(position: 1315, duration: 1320, countdown: 0) == nil) // setting off
        #expect(UpNextCountdown.secondsLeft(position: 1320, duration: 1320, countdown: 10) == nil) // ended: autoplay takes over
        #expect(UpNextCountdown.secondsLeft(position: nil, duration: 1320, countdown: 10) == nil)
        #expect(UpNextCountdown.secondsLeft(position: 5, duration: nil, countdown: 10) == nil)
        #expect(UpNextCountdown.secondsLeft(position: 5, duration: .infinity, countdown: 10) == nil)
    }

    @Test func notForClipsShorterThanTwiceTheCountdown() {
        #expect(UpNextCountdown.secondsLeft(position: 12, duration: 15, countdown: 10) == nil)
        #expect(UpNextCountdown.secondsLeft(position: 22, duration: 30, countdown: 10) == 8)
    }
}
