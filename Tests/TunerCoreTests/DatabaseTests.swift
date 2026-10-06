import Foundation
import GRDB
import Testing
@testable import TunerCore

@Suite("Database")
struct DatabaseTests {
    let db: AppDatabase
    let source: Source

    init() async throws {
        db = try AppDatabase.inMemory()
        source = Source(id: "src", name: "Test", kind: .m3u, url: "http://example.com/list.m3u")
        try await db.save(source)
        let playlist = M3UParser.parse(try Data(contentsOf: fixture("sample.m3u")), sourceId: "src")
        try await db.replaceLive(sourceId: "src", categories: playlist.categories, channels: playlist.channels)
    }

    @Test func favoritesSurviveResync() async throws {
        try await db.setFavorite(channelId: "src_cnn.us", true)
        try await db.setAlias(channelId: "src_cnn.us", "My CNN")
        // Resync with a playlist where the channel briefly disappears, then returns.
        try await db.replaceLive(sourceId: "src", categories: [], channels: [])
        #expect(try await db.channels(scope: .favorites).isEmpty)
        let playlist = M3UParser.parse(try Data(contentsOf: fixture("sample.m3u")), sourceId: "src")
        try await db.replaceLive(sourceId: "src", categories: playlist.categories, channels: playlist.channels)
        let favs = try await db.channels(scope: .favorites)
        #expect(favs.map(\.id) == ["src_cnn.us"])
        #expect(favs.first?.displayName == "My CNN")
    }

    @Test func hiddenChannelsAndCategoriesAreFiltered() async throws {
        let all = try await db.channels(scope: .all)
        try await db.setHidden(channelId: all[0].id, true)
        try await db.setCategoryHidden(categoryId: "src_misc", true)
        let visible = try await db.channels(scope: .all)
        #expect(visible.count == all.count - 2)
        #expect(try await db.channels(scope: .all, includeHidden: true).count == all.count)
    }

    @Test func searchMatchesAllWords() async throws {
        let r = try await db.channels(scope: .all, search: "bbc london")
        #expect(r.map(\.tvgId) == ["bbc1.uk"])
        #expect(try await db.channels(scope: .all, search: "100%").isEmpty)
    }

    @Test func categoriesHaveCounts() async throws {
        let cats = try await db.categories(kind: .live)
        #expect(cats.first { $0.name == "News" }?.itemCount == 2)
    }

    @Test func guideKeysResolveByIdThenName() async throws {
        let feed = EPGFeed(id: "src#0", url: "http://epg", sourceId: "src", priority: 0)
        try await db.save(feed)
        let parsed = try GuideService.parse(fileAt: fixture("sample.xml"), feedId: feed.id, wanted: nil, shift: 0,
                                            windowStart: .distantPast, windowEnd: .distantFuture)
        try await db.replaceGuide(feedId: feed.id, channels: parsed.channels, programmes: parsed.programmes, programCounts: parsed.counts)
        try await GuideService(db: db).resolveEPGKeys()

        let cnn = try #require(try await db.channel(id: "src_cnn.us"))
        #expect(cnn.epgKey == "src#0|cnn.us")
        // tvg-id differs only by case → still matched
        let bbc = try #require(try await db.channels(scope: .all).first { $0.tvgId == "bbc1.uk" })
        #expect(bbc.epgKey == "src#0|BBC1.uk")

        let programs = try await db.programs(epgKeys: ["src#0|cnn.us"], from: .distantPast, to: .distantFuture)
        #expect(programs["src#0|cnn.us"]?.map(\.title) == ["News & Views", "No Seconds"])

        // Manual override wins.
        try await db.setEPGOverride(channelId: "src_cnn.us", xmltvId: "BBC1.uk")
        try await GuideService(db: db).resolveEPGKeys()
        #expect(try await db.channel(id: "src_cnn.us")?.epgKey == "src#0|BBC1.uk")
    }

    @Test func overlappingProgrammesAreTrimmed() {
        let t0 = Date(timeIntervalSince1970: 0)
        let list = [
            Program(epgKey: "k", start: t0, end: t0.addingTimeInterval(3600), title: "A"),
            Program(epgKey: "k", start: t0.addingTimeInterval(1800), end: t0.addingTimeInterval(5400), title: "B"),
            Program(epgKey: "k", start: t0.addingTimeInterval(1800), end: t0.addingTimeInterval(5400), title: "dup"),
        ]
        let out = AppDatabase.trimOverlaps(list)
        #expect(out.map(\.title) == ["A", "B"])
        #expect(out[0].end == t0.addingTimeInterval(1800))
    }

    @Test func progressAndContinueWatching() async throws {
        let p = WatchProgress(mediaId: "m1", kind: .movie, sourceId: "src", title: "Movie", position: 600, duration: 6000)
        try await db.saveProgress(p)
        #expect(try await db.continueWatching().map(\.mediaId) == ["m1"])
        var done = p
        done.position = 5800
        try await db.saveProgress(done)
        #expect(try await db.progress(mediaId: "m1")?.completed == true)
        #expect(try await db.continueWatching().isEmpty)
        // zero duration never overwrites
        try await db.saveProgress(WatchProgress(mediaId: "m1", kind: .movie, sourceId: "src", title: "Movie", position: 0, duration: 0))
        #expect(try await db.progress(mediaId: "m1")?.position == 5800)
    }

    @Test func deletingSourceCascades() async throws {
        try await db.setFavorite(channelId: "src_cnn.us", true)
        try await db.deleteSource(id: "src")
        #expect(try await db.channels(scope: .all, includeHidden: true).isEmpty)
        let prefs = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM channelPref") }
        #expect(prefs == 0)
    }

    @Test func alternateChannelsFindDuplicates() async throws {
        let cnn = try #require(try await db.channel(id: "src_cnn.us"))
        let alts = try await db.alternateChannels(for: cnn)
        #expect(alts.map(\.name) == ["CNN Backup"])
    }
}

@Suite("Database VOD details")
struct VODDetailTests {
    @Test func updatingDetailsWithCastColumnWorks() async throws {
        let db = try AppDatabase.inMemory()
        try await db.save(Source(id: "x", name: "X", kind: .xtream, url: "http://x"))
        let movie = Movie(id: "x_vod_1", sourceId: "x", categoryId: nil, name: "M", providerId: "1", providerOrder: 0)
        let series = Series(id: "x_series_1", sourceId: "x", categoryId: nil, name: "S", providerId: "1", providerOrder: 0)
        try await db.replaceVOD(sourceId: "x", movieCategories: [], movies: [movie], seriesCategories: [], series: [series])
        var d = VODDetails()
        d.cast = "Actor One, Actor Two"
        d.plot = "Plot"
        try await db.updateMovieDetails(id: movie.id, d)
        try await db.updateSeriesDetails(id: series.id, d)
        #expect(try await db.movie(id: movie.id)?.cast == "Actor One, Actor Two")
        #expect(try await db.series(id: series.id)?.plot == "Plot")
    }
}

@Suite("Database categories")
struct CategoryLookupTests {
    @Test func categoryByIdIncludesTheAlias() async throws {
        let db = try AppDatabase.inMemory()
        try await db.save(Source(id: "x", name: "X", kind: .xtream, url: "http://x"))
        let category = Category(id: "x_movie_7", sourceId: "x", kind: .movie, name: "EN | Action", providerOrder: 0)
        let movie = Movie(id: "x_vod_1", sourceId: "x", categoryId: category.id, name: "M", providerId: "1", providerOrder: 0)
        try await db.replaceMovies(sourceId: "x", categories: [category], movies: [movie])
        #expect(try await db.category(id: category.id)?.name == "EN | Action")
        #expect(try await db.category(id: category.id)?.alias == nil)
        try await db.setCategoryAlias(categoryId: category.id, "Action")
        #expect(try await db.category(id: category.id)?.alias == "Action")
        #expect(try await db.category(id: "missing") == nil)
    }
}

@Suite("Migrations")
struct MigrationTests {
    @Test func v3MarksCachedSeriesMetadataStale() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2")
        let recent = Date()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO mediaMetadata (mediaId, kind, json, notFound, fetchedAt) VALUES
                    ('series-match', 'series', '{}', 0, ?), ('series-miss', 'series', NULL, 1, ?), ('movie', 'movie', '{}', 0, ?)
                """, arguments: [recent, recent, recent])
        }
        try AppDatabase.migrator.migrate(queue)
        let fetched = try queue.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT mediaId, fetchedAt FROM mediaMetadata").map {
                ($0["mediaId"] as String, $0["fetchedAt"] as Date)
            })
        }
        // Matched series refetch (to pick up TVmaze episode pictures); misses and movies keep their dates.
        #expect(try #require(fetched["series-match"]) < Date(timeIntervalSince1970: 1))
        #expect(abs(try #require(fetched["series-miss"]).timeIntervalSince(recent)) < 1)
        #expect(abs(try #require(fetched["movie"]).timeIntervalSince(recent)) < 1)
    }
}

@Suite("Mark watched in bulk")
struct BulkWatchedTests {
    static func record(_ id: String, position: Double = 0) -> WatchProgress {
        WatchProgress(mediaId: id, kind: .episode, sourceId: "src", seriesId: "show", title: "Show", position: position, duration: 1200)
    }

    @Test func marksEveryEpisodeAtOnceAndUnmarksBack() async throws {
        let db = try AppDatabase.inMemory()
        try await db.saveProgress(Self.record("e2", position: 300)) // part-watched beforehand
        try await db.markWatched([Self.record("e1"), Self.record("e2", position: 300), Self.record("e3")], watched: true)
        var progress = try await db.progress(seriesId: "show")
        #expect(progress.values.filter(\.completed).map(\.mediaId).sorted() == ["e1", "e2", "e3"])
        #expect(progress["e2"]?.position == 1200) // completed = played to the end

        try await db.markWatched([Self.record("e1"), Self.record("e3")], watched: false)
        progress = try await db.progress(seriesId: "show")
        #expect(progress.values.filter(\.completed).map(\.mediaId) == ["e2"])
        #expect(progress["e1"]?.position == 0)
    }

    @Test func emptyListIsANoOp() async throws {
        let db = try AppDatabase.inMemory()
        try await db.markWatched([], watched: true)
        #expect(try await db.progress(seriesId: "show").isEmpty)
    }
}
