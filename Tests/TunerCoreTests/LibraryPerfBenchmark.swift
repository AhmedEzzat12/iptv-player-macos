import Foundation
import GRDB
import Testing
@testable import TunerCore

/// Times the reads and writes the UI runs against a real-sized library. Opt-in, against a copy of a library file
/// (nothing is printed but timings and counts):
/// `PERF_DB=/path/to/tuner.sqlite scripts/test.sh -c release -Xswiftc -enable-testing --filter PerfBenchmark`.
@Suite("PerfBenchmark", .enabled(if: ProcessInfo.processInfo.environment["PERF_DB"] != nil), .serialized)
struct PerfBenchmark {
    /// A private copy of `PERF_DB` (migrations and writes never touch the original), opened like the app does.
    static func openCopy() throws -> (AppDatabase, URL) {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERF_DB"]!)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tuner-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent("tuner.sqlite"))
        return (try AppDatabase.onDisk(directory: dir), dir)
    }

    /// Runs `body` `runs` times; prints the first (cold) and the median of the rest.
    @discardableResult
    static func time<T>(_ name: String, runs: Int = 5, _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock()
        var durations: [Duration] = []
        var last: T?
        for _ in 0..<runs {
            let start = clock.now
            last = try await body()
            durations.append(clock.now - start)
        }
        let first = durations[0]
        let rest = durations.dropFirst().sorted()
        let median = rest.isEmpty ? first : rest[rest.count / 2]
        func ms(_ d: Duration) -> String { String(format: "%.2f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        print("PERF \(name): first \(ms(first)) ms, median \(ms(median)) ms")
        return last!
    }

    /// Resident memory of the test process, in MB.
    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    /// Heap bytes in use (live allocations), in MB.
    static func heapMB() -> Int {
        var zones: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        guard malloc_get_all_zones(mach_task_self_, nil, &zones, &count) == KERN_SUCCESS, let zones else { return -1 }
        var total = 0
        for i in 0..<Int(count) {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(zones[i])), &stats)
            total += stats.size_in_use
        }
        return total / 1_048_576
    }

    @Test func readPaths() async throws {
        let (db, dir) = try await Self.time("copy + open + migrate", runs: 1) { try Self.openCopy() }
        defer { try? FileManager.default.removeItem(at: dir) }
        // Launch: opening an up-to-date library (what AppModel waits for before the first screen).
        try await Self.time("launch.open (migrated)", runs: 3) { try AppDatabase.onDisk(directory: dir).writer.path }
        let rss0 = Self.residentMB()

        // Home: loadLibrary (four shelves side by side, as the view does).
        try await Self.time("home.library") {
            async let a = db.movies(sort: .added, limit: 24)
            async let b = db.series(sort: .added, limit: 24)
            async let c = db.movies(sort: .rating, limit: 20)
            async let d = db.series(sort: .rating, limit: 20)
            return try await (a.count, b.count, c.count, d.count)
        }
        try await Self.time("home.movies(added, 24)") { try await db.movies(sort: .added, limit: 24) }
        try await Self.time("home.movies(rating, 20)") { try await db.movies(sort: .rating, limit: 20) }
        try await Self.time("home.series(added, 24)") { try await db.series(sort: .added, limit: 24) }

        // Home: loadPersonal + the fallback artwork lookups for its cards.
        let personal = try await Self.time("home.personal") {
            async let ranked = db.smartContinueWatching(limit: 40)
            async let plain = db.continueWatching(limit: 20)
            async let fm = db.favoriteMovies()
            async let fs = db.favoriteSeries()
            return try await (ranked, plain, fm.count, fs.count)
        }
        let artworkIds: [(String, Bool)] = (personal.1.map(ContinueWatchingItem.resume) + personal.0).map { item in
            switch item {
            case .resume(let p): (p.seriesId ?? p.mediaId, p.seriesId != nil)
            case .nextEpisode(let e, _): (e.seriesId, true)
            }
        }
        print("PERF home.personal: \(personal.0.count) ranked, \(personal.1.count) resume, \(artworkIds.count) artwork ids")
        try await Self.time("home.fallbackArtwork (per-id lookups)") {
            _ = try await db.cachedMetadata(mediaIds: artworkIds.map(\.0))
            var n = 0
            for (id, isSeries) in artworkIds {
                if isSeries { if try await db.series(id: id) != nil { n += 1 } } else if try await db.movie(id: id) != nil { n += 1 }
            }
            return n
        }
        try await Self.time("home.fallbackArtwork (batched)") {
            _ = try await db.cachedMetadata(mediaIds: artworkIds.map(\.0))
            async let shows = db.series(ids: Array(Set(artworkIds.filter(\.1).map(\.0))))
            async let movies = db.movies(ids: Array(Set(artworkIds.filter { !$0.1 }.map(\.0))))
            return try await shows.count + movies.count
        }

        print("PERF rss after home: \(Self.residentMB()) MB")
        // Movies / TV Shows browser.
        let movieCategories = try await Self.time("browse.categories(movie)") { try await db.categories(kind: .movie) }
        try await Self.time("browse.categories(series)") { try await db.categories(kind: .series) }
        await Self.time("classifier.classify(movie categories, uncached)") {
            movieCategories.map { CategoryClassifier.classify($0.name).group }.count
        }
        await Self.time("classifier.normalized(movie categories)") {
            movieCategories.map { CategoryClassifier.normalized($0.name) }.count
        }
        await Self.time("classifier.split(movie categories)") {
            movieCategories.map { CategoryClassifier.split($0.name).latin.count }.count
        }
        await Self.time("classifier.years(movie categories)") {
            movieCategories.map { CategoryClassifier.yearsMentioned(in: $0.name).count }.count
        }
        await Self.time("browse.categoryGroups(movie)") {
            movieCategories.map { CategoryClassifier.facet(for: $0.name).group }.count
        }
        for sort in VODSort.allCases {
            try await Self.time("browse.movies(\(sort.rawValue)) page 1") { try await db.movies(sort: sort, limit: 200) }
        }
        try await Self.time("browse.movies(name) page 11") { try await db.movies(sort: .name, limit: 200, offset: 2000) }
        try await Self.time("browse.movies(added) reload 2000") { try await db.movies(sort: .added, limit: 2000) }
        for sort in [VODSort.added, .name, .rating] {
            try await Self.time("browse.series(\(sort.rawValue)) page 1") { try await db.series(sort: sort, limit: 200) }
        }
        if let biggest = movieCategories.max(by: { $0.itemCount < $1.itemCount }) {
            print("PERF biggest movie category: \(biggest.itemCount) items")
            try await Self.time("browse.movies(category, added)") { try await db.movies(categoryId: biggest.id, sort: .added, limit: 200) }
            try await Self.time("browse.movies(category, name)") { try await db.movies(categoryId: biggest.id, sort: .name, limit: 200) }
        }
        try await Self.time("browse.movies(search 'the', added)") { try await db.movies(search: "the", sort: .added, limit: 200) }
        try await Self.time("browse.userState") {
            async let f = db.favoriteMovies()
            async let c = db.continueWatching(limit: 100)
            return try await (f.count, c.count)
        }

        print("PERF rss after browse: \(Self.residentMB()) MB")
        // Search.
        for q in ["the", "love", "zzqx", "arabic comedy 2020", "top rated action movies", "4k"] {
            let understood = await Self.time("search.understand '\(q)'") { await db.understandSearch(q) }
            try await Self.time("search.vod '\(q)'") {
                if understood.hasFilters {
                    async let m = db.movies(understood: understood)
                    async let s = db.series(understood: understood)
                    return try await m.count + s.count
                }
                async let m = db.movies(search: q, sort: .name, limit: 200)
                async let s = db.series(search: q, sort: .name, limit: 200)
                return try await m.count + s.count
            }
            try await Self.time("search.channels '\(q)'") { try await db.channels(scope: .all, search: q, sort: .provider, limit: 60) }
        }

        print("PERF rss after search: \(Self.residentMB()) MB")
        // Live TV.
        for sort in ChannelSort.allCases {
            let list = try await Self.time("live.channels(all, \(sort.rawValue))") { try await db.channels(scope: .all, sort: sort) }
            if sort == .provider { print("PERF live: \(list.count) channels") }
        }
        // What the Live TV page does on the main actor with a reloaded list (LiveGuideStore.setChannels, zapList).
        let listA = try await db.channels(scope: .all), listB = try await db.channels(scope: .all)
        await Self.time("live.compare reloaded list (main actor)") { listA == listB }
        try await Self.time("live.rows(all) without decoding") {
            try await db.writer.read { db in try Row.fetchAll(db, sql: AppDatabase.channelSelect + " ORDER BY s.sortIndex, c.sourceId, c.providerOrder").count }
        }
        let liveCategories = try await Self.time("live.categories") { try await db.categories(kind: .live) }
        if let biggest = liveCategories.max(by: { $0.itemCount < $1.itemCount }) {
            try await Self.time("live.channels(category)") { try await db.channels(scope: .category(biggest.id)) }
        }
        try await Self.time("live.channels(favorites)") { try await db.channels(scope: .favorites) }
        try await Self.time("live.channels(recent)") { try await db.channels(scope: .recent) }
        try await Self.time("live.channels(search 'sport')") { try await db.channels(scope: .all, search: "sport") }

        print("PERF rss after live: \(Self.residentMB()) MB")
        // Show page.
        if let seriesId = try await db.writer.read({ db in
            try String.fetchOne(db, sql: "SELECT seriesId FROM episode GROUP BY seriesId ORDER BY COUNT(*) DESC LIMIT 1")
        }) {
            try await Self.time("show.page") {
                async let s = db.series(id: seriesId)
                async let e = db.episodes(seriesId: seriesId)
                async let p = db.progress(seriesId: seriesId)
                return try await (s?.id, e.count, p.count)
            }
        }

        // Top 10 matching (ten chart titles from the library itself, so the name search has work to do).
        let titles = try await db.writer.read { db in try String.fetchAll(db, sql: "SELECT name FROM movie ORDER BY rating DESC LIMIT 10") }
        let service = TopTenService(db: db)
        let words = titles.compactMap { TopTenMatcher.searchWord($0, kind: .movie) }
        try await Self.time("topTen.candidates(movies)") {
            try await db.topTenCandidates(kind: .movie, words: words, imdbIds: [], tmdbIds: [], hideAdult: true).count
        }
        await Self.time("topTen.match(movies)") {
            await service.match(titles.map { ChartEntry(title: $0) }, kind: .movie, hideAdult: true, usage: [:]).count
        }

        print("PERF rss after topTen: \(Self.residentMB()) MB")
        // Recommendations: signature (every Home load), first build, then a warm call.
        try await Self.time("recommender.signature") { try await db.recommendationSignature() }
        try await Self.time("recommender.corpus", runs: 2) { try await db.recommendationCorpus().count }
        print("PERF rss after corpus: \(Self.residentMB()) MB")
        let recommender = Recommender(db: db)
        await Self.time("recommender.becauseYouWatched (build)", runs: 1) { await recommender.becauseYouWatched(libraryRevision: 1, hideAdult: true).count }
        await Self.time("recommender.becauseYouWatched (warm)") { await recommender.becauseYouWatched(libraryRevision: 1, hideAdult: true).count }
        print("PERF memory: resident \(rss0) → \(Self.residentMB()) MB after building the recommendation index")
        if let index = await recommender.currentIndex(libraryRevision: 1) {
            print("PERF memory: index \(index.count) titles, \(index.termCount) terms, ~\(index.approximateVectorBytes / 1_048_576) MB vectors")
        }
        let heap1 = Self.heapMB()
        let allMovies = try await db.writer.read { db in try Movie.fetchAll(db, sql: "SELECT * FROM movie") }
        withExtendedLifetime(allMovies) { print("PERF memory: all \(allMovies.count) movies as records: heap +\(Self.heapMB() - heap1) MB") }
        let heap2 = Self.heapMB()
        let allChannels = try await db.channels(scope: .all)
        withExtendedLifetime(allChannels) { print("PERF memory: all \(allChannels.count) channels as records: heap +\(Self.heapMB() - heap2) MB") }

        // Cloud sync: one pass with nothing remote (first, then steady state).
        try await Self.time("cloudSync.pass", runs: 3) {
            try await db.cloudSyncPass(remote: [:], preferences: [:], deviceId: "perf").records.count
        }
    }

    @Test func writePaths() async throws {
        let (db, dir) = try Self.openCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The biggest VOD playlist's own rows, written back the way a resync does.
        let (sourceId, movieCats, movies, seriesCats, series) = try await db.writer.read { db in
            let sourceId = try String.fetchOne(db, sql: "SELECT sourceId FROM movie GROUP BY sourceId ORDER BY COUNT(*) DESC LIMIT 1")!
            return (sourceId,
                    try Category.fetchAll(db, sql: "SELECT * FROM category WHERE sourceId = ? AND kind = 'movie'", arguments: [sourceId]),
                    try Movie.fetchAll(db, sql: "SELECT * FROM movie WHERE sourceId = ?", arguments: [sourceId]),
                    try Category.fetchAll(db, sql: "SELECT * FROM category WHERE sourceId = ? AND kind = 'series'", arguments: [sourceId]),
                    try Series.fetchAll(db, sql: "SELECT * FROM series WHERE sourceId = ?", arguments: [sourceId]))
        }
        print("PERF resync: \(movies.count) movies, \(series.count) series")
        try await Self.time("sync.replaceVOD", runs: 3) {
            try await db.replaceVOD(sourceId: sourceId, movieCategories: movieCats, movies: movies, seriesCategories: seriesCats, series: series)
        }
        let channels = try await db.writer.read { db in
            try Channel.fetchAll(db, sql: "SELECT * FROM channel WHERE sourceId = (SELECT sourceId FROM channel GROUP BY sourceId ORDER BY COUNT(*) DESC LIMIT 1)")
        }
        if let liveSource = channels.first?.sourceId {
            let cats = try await db.categories(kind: .live, sourceId: liveSource, includeHidden: true).map {
                Category(id: $0.id, sourceId: $0.sourceId, kind: .live, name: $0.name, providerOrder: $0.providerOrder)
            }
            try await Self.time("sync.replaceLive (\(channels.count))", runs: 3) {
                try await db.replaceLive(sourceId: liveSource, categories: cats, channels: channels)
            }
        }
        if let seriesId = try await db.writer.read({ db in
            try String.fetchOne(db, sql: "SELECT seriesId FROM episode GROUP BY seriesId ORDER BY COUNT(*) DESC LIMIT 1")
        }) {
            let episodes = try await db.episodes(seriesId: seriesId)
            try await Self.time("show.replaceEpisodes (unchanged, \(episodes.count))") { try await db.replaceEpisodes(seriesId: seriesId, episodes: episodes) }
        }
        // An M3U playlist's inline episodes (synthetic: 3,000 shows × 10 episodes), one transaction per show vs one.
        func m3uEpisodes(_ tag: String) -> [String: [Episode]] {
            Dictionary(uniqueKeysWithValues: (0..<3_000).map { s in
                ("\(sourceId)_m3u\(tag)_\(s)", (1...10).map { e in
                    Episode(id: "\(sourceId)_m3u\(tag)_\(s)_\(e)", seriesId: "\(sourceId)_m3u\(tag)_\(s)", sourceId: sourceId, season: 1,
                            number: e, title: "Episode \(e)", providerId: "\(s)_\(e)", streamURL: "http://example.invalid/\(s)/\(e).mp4")
                })
            })
        }
        let perShow = m3uEpisodes("a"), batched = m3uEpisodes("b")
        try await Self.time("sync.m3uEpisodes per show (3000×10)", runs: 2) {
            for (id, list) in perShow { try await db.replaceEpisodes(seriesId: id, episodes: list) }
        }
        try await Self.time("sync.m3uEpisodes one transaction (3000×10)", runs: 2) { try await db.replaceEpisodes(batched) }
    }
}
