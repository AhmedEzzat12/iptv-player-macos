import Foundation
import Testing
@testable import TunerCore

/// A small bilingual library with obvious neighbours: Nolan films, Pixar, romance, Egyptian thrillers and comedies,
/// crime and comedy shows.
private enum Fixture {
    static func movie(_ id: String, _ title: String, category: String = "action", categoryName: String = "Action Movies",
                      genres: [String] = [], cast: [String] = [], directors: [String] = [], year: Int? = nil,
                      rating: Double? = nil, plot: String? = nil) -> RecommendationItem {
        RecommendationItem(id: id, kind: .movie, title: title, year: year, rating: rating, categoryId: category,
                           categoryName: categoryName, genres: genres, cast: cast, directors: directors, plot: plot)
    }

    static func show(_ id: String, _ title: String, category: String = "tv", categoryName: String = "English Series",
                     genres: [String] = [], cast: [String] = [], year: Int? = nil, plot: String? = nil) -> RecommendationItem {
        RecommendationItem(id: id, kind: .series, title: title, year: year, categoryId: category, categoryName: categoryName,
                           genres: genres, cast: cast, plot: plot)
    }

    static let items: [RecommendationItem] = [
        movie("dark-knight", "The Dark Knight", genres: ["Action", "Crime"], cast: ["Christian Bale", "Heath Ledger"],
              directors: ["Christopher Nolan"], year: 2008, rating: 9.0,
              plot: "Batman faces the Joker, a criminal mastermind who plunges Gotham into chaos."),
        movie("batman-begins", "Batman Begins", genres: ["Action", "Adventure"], cast: ["Christian Bale", "Michael Caine"],
              directors: ["Christopher Nolan"], year: 2005, rating: 8.2,
              plot: "Bruce Wayne becomes Batman to fight the corruption of Gotham."),
        movie("inception", "Inception", genres: ["Action", "Sci-Fi"], cast: ["Leonardo DiCaprio", "Michael Caine"],
              directors: ["Christopher Nolan"], year: 2010, rating: 8.8,
              plot: "A thief steals secrets from dreams and must plant an idea."),
        movie("notebook", "The Notebook", category: "romance", categoryName: "Romance - رومانسي", genres: ["Romance", "Drama"],
              cast: ["Ryan Gosling", "Rachel McAdams"], directors: ["Nick Cassavetes"], year: 2004,
              plot: "A poor young man falls in love with a rich young woman."),
        movie("la-la-land", "La La Land", category: "romance", categoryName: "Romance - رومانسي", genres: ["Romance", "Music"],
              cast: ["Ryan Gosling", "Emma Stone"], directors: ["Damien Chazelle"], year: 2016,
              plot: "A jazz musician and an actress fall in love in Los Angeles."),
        movie("toy-story", "Toy Story", category: "kids", categoryName: "Kids - اطفال", genres: ["Animation", "Family"],
              cast: ["Tom Hanks", "Tim Allen"], year: 1995, plot: "Toys come to life when their owner is away."),
        movie("nemo", "Finding Nemo", category: "kids", categoryName: "Kids - اطفال", genres: ["Animation", "Family"],
              cast: ["Albert Brooks", "Ellen DeGeneres"], year: 2003, plot: "A clownfish crosses the ocean to find his son."),
        // Egyptian films: Arabic genres written with and without hamza, cast and director in Arabic.
        movie("blue-elephant", "الفيل الأزرق", category: "arabic", categoryName: "Arabic Movies - افلام عربي",
              genres: ["إثارة", "غموض"], cast: ["كريم عبد العزيز", "نيللي كريم"], directors: ["مروان حامد"], year: 2014,
              plot: "طبيب نفسي يعود إلى عمله في مستشفى العباسية ويواجه قضية غامضة."),
        movie("blue-elephant-2", "الفيل الازرق 2", category: "arabic", categoryName: "Arabic Movies - افلام عربي",
              genres: ["اثارة", "رعب"], cast: ["كريم عبدالعزيز", "هند صبري"], directors: ["مروان حامد"], year: 2019,
              plot: "الطبيب النفسي يحيى يواجه سجينة غامضة في المستشفى."),
        movie("diamond-dust", "تراب الماس", category: "arabic", categoryName: "Arabic Movies - افلام عربي",
              genres: ["اثارة", "جريمة"], cast: ["آسر ياسين", "منة شلبي"], directors: ["مروان حامد"], year: 2018,
              plot: "صيدلي يكتشف سر والده ويواجه جرائم غامضة."),
        movie("el-nazer", "الناظر", category: "arabic", categoryName: "Arabic Movies - افلام عربي",
              genres: ["كوميدي"], cast: ["علاء ولي الدين", "أحمد حلمي"], year: 2000, plot: "ناظر مدرسة وابنه في مواقف كوميدية."),
        movie("el-limby", "اللمبي", category: "arabic", categoryName: "Arabic Movies - افلام عربي",
              genres: ["كوميديا"], cast: ["محمد سعد", "حلا شيحة"], year: 2002, plot: "شاب شعبي يبحث عن عمل في مواقف مضحكة."),
        show("breaking-bad", "Breaking Bad", genres: ["Crime", "Drama"], cast: ["Bryan Cranston", "Aaron Paul", "Bob Odenkirk"], year: 2008,
             plot: "A chemistry teacher turns to making drugs in Albuquerque."),
        show("saul", "Better Call Saul", genres: ["Crime", "Drama"], cast: ["Bob Odenkirk", "Rhea Seehorn"], year: 2015,
             plot: "A small-time lawyer in Albuquerque becomes a criminal lawyer."),
        show("friends", "Friends", genres: ["Comedy"], cast: ["Jennifer Aniston", "Matthew Perry"], year: 1994,
             plot: "Six friends live and laugh in New York."),
        show("office", "The Office", genres: ["Comedy"], cast: ["Steve Carell", "Rainn Wilson"], year: 2005,
             plot: "A mockumentary about office workers and their boss."),
    ]

    static var index: RecommendationIndex { RecommendationIndex(items: items) }
}

@Suite("Recommendations: text")
struct RecommendationTextTests {
    @Test func arabicNormalisation() {
        // Diacritics, tatweel, alef/yaa/taa marbuta/hamza carriers, Arabic-Indic digits.
        #expect(RecommendationText.normalize("أَفْلامٌ") == "افلام")
        #expect(RecommendationText.normalize("مـــدرســة") == "مدرسه")
        #expect(RecommendationText.normalize("إلى آخر مستشفى") == "الي اخر مستشفي")
        #expect(RecommendationText.normalize("مؤمن ونائم") == "مومن ونايم")
        #expect(RecommendationText.normalize("رمضان ٢٠٢٤") == "رمضان 2024")
        #expect(RecommendationText.normalize("إثارة") == RecommendationText.normalize("اثاره"))
    }

    @Test func latinNormalisation() {
        #expect(RecommendationText.normalize("Amélie: L'Été!") == "amelie lete")
        #expect(RecommendationText.normalize("Ocean’s  Eleven") == "oceans eleven")
    }

    @Test func stemmingAndStopWords() {
        #expect(RecommendationText.stem("الحب") == "حب")
        #expect(RecommendationText.stem("والحب") == "حب")
        #expect(RecommendationText.stem("الله") == "الله")
        #expect(RecommendationText.stem("detectives") == "detective")
        #expect(RecommendationText.stem("boss") == "boss")
        let words = RecommendationText.contentWords("قصة الحب في المدينة من أجل The story of a detective in the city")
        #expect(words == ["حب", "مدينه", "اجل", "detective", "city"])
    }

    @Test func titleKeys() {
        let matrix = RecommendationText.titleKey("EN - The Matrix (1999) [4K]", isSeries: false)
        #expect(matrix.key == "the matrix" && matrix.year == 1999)
        let plain = RecommendationText.titleKey("The Matrix", isSeries: false)
        #expect(plain.key == "the matrix" && plain.year == nil)
        let oppenheimer = RecommendationText.titleKey("Oppenheimer 2023", isSeries: false)
        #expect(oppenheimer.key == "oppenheimer" && oppenheimer.year == 2023)
        #expect(RecommendationText.titleKey("Blade Runner 2049", isSeries: false).key == "blade runner 2049")
        #expect(RecommendationText.titleKey("1917", isSeries: false).key == "1917")
        #expect(RecommendationText.titleKey("It: Chapter Two", isSeries: false).key == "it chapter two")
        #expect(RecommendationText.titleKey("Toy Story 2", isSeries: false).key == "toy story 2")
        #expect(RecommendationText.titleKey("Breaking Bad S02", isSeries: true).key == "breaking bad")
        #expect(RecommendationText.titleKey("Breaking Bad - Season 2", isSeries: true).key == "breaking bad")
        #expect(RecommendationText.titleKey("|AR| مسلسل الهيبة الموسم ٢", isSeries: true).key == "الهيبه")
        #expect(RecommendationText.titleKey("4K", isSeries: false).key == "4k") // nothing but a tag: kept as is
    }

    @Test func canonicalGenresAndLanguages() {
        #expect(RecommendationText.canonicalGenres("Action & Adventure") == ["action", "adventure"])
        #expect(RecommendationText.canonicalGenres("افلام أكشن") == ["action"])
        #expect(RecommendationText.canonicalGenres("خيال علمي") == ["scifi"])
        #expect(RecommendationText.canonicalGenres("Sci-Fi") == ["scifi"])
        #expect(RecommendationText.canonicalGenres("Warriors") == []) // "war" only as a word
        #expect(RecommendationText.canonicalLanguages("Turkish Series - مسلسلات تركية") == ["turkish"])
        #expect(RecommendationText.canonicalLanguages("افلام عربي") == ["arabic"])
    }

    @Test func years() {
        #expect(RecommendationText.year("2019-05-01") == 2019)
        #expect(RecommendationText.year("2008–2013") == 2008)
        #expect(RecommendationText.year("12345") == nil)
        #expect(RecommendationText.year(nil) == nil)
    }
}

@Suite("Recommendations: index")
struct RecommendationIndexTests {
    func ids(_ results: [Recommendation]) -> [String] { results.map(\.id) }

    @Test func obviousNeighboursComeFirst() {
        let index = Fixture.index
        let dark = ids(index.similar(toId: "dark-knight"))
        #expect(Array(dark.prefix(2)) == ["batman-begins", "inception"])
        #expect(!dark.contains("dark-knight"))

        let notebook = ids(index.similar(toId: "notebook"))
        #expect(notebook.first == "la-la-land")

        let toy = ids(index.similar(toId: "toy-story"))
        #expect(toy.first == "nemo")
    }

    @Test func arabicTitlesFindArabicNeighbours() {
        let index = Fixture.index
        let elephant = ids(index.similar(toId: "blue-elephant"))
        // Same director and lead (written with and without a space), genre spelled with and without hamza.
        #expect(Array(elephant.prefix(2)) == ["blue-elephant-2", "diamond-dust"])
        let comedy = ids(index.similar(toId: "el-nazer"))
        #expect(comedy.first == "el-limby") // كوميدي ≈ كوميديا
    }

    @Test func showsOnlyGetShows() {
        let index = Fixture.index
        let results = index.similar(toId: "breaking-bad")
        #expect(results.first?.id == "saul")
        #expect(results.allSatisfy { $0.kind == .series })
        #expect(index.similar(toId: "dark-knight").allSatisfy { $0.kind == .movie })
    }

    @Test func liveItemsUseTheirOwnDetails() {
        let index = Fixture.index
        // A page's item with fresher details than the index (e.g. after online metadata arrived).
        let page = Fixture.movie("new", "The Prestige", genres: ["Drama", "Mystery"], cast: ["Christian Bale", "Michael Caine"],
                                 directors: ["Christopher Nolan"], year: 2006)
        let results = ids(index.similar(to: page))
        #expect(Set(results.prefix(3)) == ["batman-begins", "dark-knight", "inception"])
    }

    @Test func sparseItemsFallBackToCategoryAndTitle() {
        // No genres, cast or plots: titles and category names still find the sequel in the same category.
        let items = [
            Fixture.movie("ff7", "Fast & Furious 7", category: "a", categoryName: "Action - افلام اكشن"),
            Fixture.movie("ff8", "The Fate of the Furious", category: "a", categoryName: "Action - افلام اكشن"),
            Fixture.movie("love", "Love Actually", category: "r", categoryName: "Romance"),
            Fixture.movie("love2", "Love Story", category: "r", categoryName: "Romance"),
            Fixture.movie("furious", "Furious Tales", category: "x", categoryName: "Comedy"),
        ]
        let index = RecommendationIndex(items: items)
        #expect(ids(index.similar(toId: "ff7")).first == "ff8")
        #expect(ids(index.similar(toId: "love")).first == "love2")
    }

    @Test func neverTheItselfOrCopiesOfIt() {
        var items = Fixture.items
        items.append(Fixture.movie("dark-knight-4k", "EN - The Dark Knight (2008) [4K]", category: "4k", categoryName: "4K Movies",
                                   genres: ["Action", "Crime"], cast: ["Christian Bale"], directors: ["Christopher Nolan"]))
        items.append(Fixture.movie("dark-knight-copy", "The Dark Knight", category: "box", categoryName: "Box Office",
                                   genres: ["Action"], cast: ["Christian Bale"], directors: ["Christopher Nolan"], year: 2008))
        let index = RecommendationIndex(items: items)

        let fromDark = ids(index.similar(toId: "dark-knight"))
        #expect(!fromDark.contains("dark-knight-4k") && !fromDark.contains("dark-knight-copy"))

        // From another title, only one copy of The Dark Knight shows up.
        let fromBatman = ids(index.similar(toId: "batman-begins"))
        #expect(fromBatman.filter { $0.hasPrefix("dark-knight") }.count == 1)
    }

    @Test func remakesWithAnotherYearAreNotDuplicates() {
        let items = [
            Fixture.movie("a", "Dune", genres: ["Sci-Fi"], directors: ["Denis Villeneuve"], year: 2021),
            Fixture.movie("b", "Dune", genres: ["Sci-Fi"], directors: ["David Lynch"], year: 1984),
            Fixture.movie("c", "Arrival", genres: ["Sci-Fi"], directors: ["Denis Villeneuve"], year: 2016),
        ]
        let index = RecommendationIndex(items: items)
        #expect(Set(ids(index.similar(toId: "a"))) == ["b", "c"])
    }

    @Test func excludedIdsHiddenCategoriesAndAdult() {
        var items = Fixture.items
        items.append(Fixture.movie("adult", "Gotham Nights", category: "xxx", categoryName: "Adult +18",
                                   genres: ["Action", "Crime"], cast: ["Christian Bale"], directors: ["Christopher Nolan"], year: 2008))
        let index = RecommendationIndex(items: items)

        #expect(ids(index.similar(toId: "dark-knight")).contains("adult"))
        #expect(!ids(index.similar(toId: "dark-knight", options: RecommendationOptions(hideAdult: true))).contains("adult"))

        let excluded = ids(index.similar(toId: "dark-knight", options: RecommendationOptions(excludedIds: ["batman-begins"], hideAdult: true)))
        #expect(!excluded.contains("batman-begins"))
        #expect(excluded.first == "inception")

        let hidden = ids(index.similar(toId: "dark-knight", options: RecommendationOptions(hiddenCategoryIds: ["action"])))
        #expect(!hidden.contains("batman-begins") && !hidden.contains("inception"))
    }

    @Test func diversityCapsOneCategory() {
        // Ten near-identical titles in one category, three a little less similar elsewhere.
        var items = (0..<10).map { i in
            Fixture.movie("same\(i)", "Space Saga Part \(i)", category: "big", categoryName: "Sci-Fi Movies",
                          genres: ["Sci-Fi", "Adventure"], directors: ["Jane Doe"], year: 2010 + i)
        }
        items += (0..<3).map { i in
            Fixture.movie("other\(i)", "Star Voyage \(i)", category: "c\(i)", categoryName: "Box Office",
                          genres: ["Sci-Fi"], directors: ["Jane Doe"], year: 2015)
        }
        items.append(Fixture.movie("seed", "Space Saga", category: "big", categoryName: "Sci-Fi Movies",
                                   genres: ["Sci-Fi", "Adventure"], directors: ["Jane Doe"], year: 2009))
        let index = RecommendationIndex(items: items)

        let capped = ids(index.similar(toId: "seed", options: RecommendationOptions(limit: 6, maxPerCategory: 3)))
        #expect(capped.count == 6)
        #expect(capped.filter { $0.hasPrefix("same") }.count == 3)
        #expect(capped.filter { $0.hasPrefix("other") }.count == 3)

        // When only one category is left, the cap gives way rather than returning fewer titles.
        let many = ids(index.similar(toId: "seed", options: RecommendationOptions(limit: 12, maxPerCategory: 3)))
        #expect(many.count == 12)

        // Without diversity and with no cap, the closest titles (same category) win.
        let plain = ids(index.similar(toId: "seed", options: RecommendationOptions(limit: 3, diversity: 0, maxPerCategory: 99)))
        #expect(plain.allSatisfy { $0.hasPrefix("same") })
    }

    @Test func yearProximityBreaksTies() {
        let items = [
            Fixture.movie("seed", "Seed", genres: ["Western"], directors: ["Sam Hill"], year: 1970),
            Fixture.movie("near", "Near", genres: ["Western"], directors: ["Sam Hill"], year: 1972),
            Fixture.movie("far", "Far", genres: ["Western"], directors: ["Sam Hill"], year: 2020),
        ]
        let index = RecommendationIndex(items: items)
        #expect(ids(index.similar(toId: "seed", options: RecommendationOptions(diversity: 0))) == ["near", "far"])
    }

    @Test func emptyAndUnknown() {
        let empty = RecommendationIndex(items: [])
        #expect(empty.count == 0)
        #expect(empty.similar(toId: "x").isEmpty)
        #expect(empty.similar(to: Fixture.items[0]).isEmpty)
        #expect(Fixture.index.similar(toId: "missing").isEmpty)
        // A title sharing nothing with the library gets nothing rather than random titles.
        let loner = Fixture.movie("loner", "Zzyzx", category: "none", categoryName: "Qwerty")
        #expect(Fixture.index.similar(to: loner).isEmpty)
    }

    @Test func metadataFillsWhatTheProviderLacks() throws {
        var movie = Movie(id: "m1", sourceId: "s", categoryId: "c", name: "EN - Heat (1995)", providerId: "1", providerOrder: 0)
        movie.genre = "Crime, Drama"
        var metadata = MediaMetadata(kind: .movie, source: "Test", title: "Heat")
        metadata.genres = ["Thriller"]
        metadata.cast = [CastMember(name: "Al Pacino"), CastMember(name: "Robert De Niro")]
        metadata.directors = ["Michael Mann"]
        metadata.overview = "A detective hunts a professional thief."
        let item = RecommendationItem(movie: movie, categoryName: "Action", metadata: metadata)
        #expect(item.year == 1995)
        #expect(item.genres == ["Crime", "Drama", "Thriller"])
        #expect(item.cast == ["Al Pacino", "Robert De Niro"])
        #expect(item.directors == ["Michael Mann"])
        #expect(item.plot == "A detective hunts a professional thief.")

        // The cached-JSON reader takes the same fields from the stored document.
        let json = try JSONEncoder().encode(metadata)
        let light = try JSONDecoder().decode(RecommendationMetadata.self, from: json)
        #expect(light.cast == ["Al Pacino", "Robert De Niro"] && light.genres == ["Thriller"] && light.directors == ["Michael Mann"])
    }
}

@Suite("Recommendations: seeds and Home rows")
struct RecommenderTests {
    func progress(_ id: String, kind: MediaKind = .movie, series: String? = nil, position: Double, duration: Double = 100,
                  completed: Bool = false, minutesAgo: Double) -> WatchProgress {
        WatchProgress(mediaId: id, kind: kind, sourceId: "s", seriesId: series, title: id, position: position, duration: duration,
                      completed: completed, updatedAt: Date().addingTimeInterval(-minutesAgo * 60))
    }

    @Test func seedsAreFinishedOrMostlyWatchedThenFavourites() {
        let signals = RecommendationSignals(progress: [
            progress("m-done", position: 100, completed: true, minutesAgo: 1),
            progress("e1", kind: .episode, series: "show", position: 60, minutesAgo: 2),
            progress("e2", kind: .episode, series: "show", position: 100, completed: true, minutesAgo: 3),
            progress("m-started", position: 20, minutesAgo: 4),
        ], favoriteIds: ["fav", "m-done"])
        #expect(signals.seeds.map(\.id) == ["m-done", "show", "fav"])
        #expect(signals.seeds.map(\.reason) == [.watched, .watched, .liked])
        #expect(signals.seenIds == ["m-done", "show", "m-started", "fav"])
    }

    @Test func homeRowsLeaveOutWhatWasSeenAndDontRepeat() {
        let index = Fixture.index
        let signals = RecommendationSignals(progress: [
            progress("dark-knight", position: 100, completed: true, minutesAgo: 1),
            progress("batman-begins", position: 30, minutesAgo: 2), // in progress: not a seed, but seen
            progress("blue-elephant", position: 80, minutesAgo: 3),
        ], favoriteIds: ["breaking-bad"])
        let rows = Recommender.plan(index: index, signals: signals, hiddenCategoryIds: [], hideAdult: false, rows: 2, limit: 20, minTitles: 1)
        #expect(rows.map(\.seed.id) == ["dark-knight", "blue-elephant"])
        let all = rows.flatMap { $0.titles.map(\.id) }
        #expect(!all.contains("batman-begins") && !all.contains("dark-knight") && !all.contains("blue-elephant"))
        #expect(Set(all).count == all.count) // no title in two rows
        #expect(rows[0].titles.first?.id == "inception")
        #expect(rows[1].titles.first?.id == "blue-elephant-2")
    }

    @Test func homeRowsSkipHiddenSeedsAndNearDuplicateSeeds() {
        var items = Fixture.items
        items.append(Fixture.movie("dark-knight-4k", "The Dark Knight [4K]", category: "4k", categoryName: "4K",
                                   genres: ["Action", "Crime"], cast: ["Christian Bale", "Heath Ledger"],
                                   directors: ["Christopher Nolan"], year: 2008))
        let index = RecommendationIndex(items: items)
        let signals = RecommendationSignals(progress: [
            progress("dark-knight", position: 100, completed: true, minutesAgo: 1),
            progress("dark-knight-4k", position: 100, completed: true, minutesAgo: 2),
            progress("notebook", position: 100, completed: true, minutesAgo: 3),
            progress("toy-story", position: 100, completed: true, minutesAgo: 4),
        ], favoriteIds: [])
        let rows = Recommender.plan(index: index, signals: signals, hiddenCategoryIds: ["romance"], hideAdult: false, rows: 2, limit: 20, minTitles: 1)
        // The second copy of The Dark Knight and the hidden romance seed are skipped.
        #expect(rows.map(\.seed.id) == ["dark-knight", "toy-story"])
    }

    @Test func recommenderWorksAgainstTheDatabase() async throws {
        let db = try AppDatabase.inMemory()
        try await db.save(Source(id: "s", name: "S", kind: .xtream, url: "http://x"))
        let categories = [
            Category(id: "c-action", sourceId: "s", kind: .movie, name: "Action - افلام اكشن", providerOrder: 0),
            Category(id: "c-kids", sourceId: "s", kind: .movie, name: "Kids", providerOrder: 1),
        ]
        func movie(_ id: String, _ name: String, _ category: String, genre: String, director: String) -> Movie {
            var m = Movie(id: id, sourceId: "s", categoryId: category, name: name, providerId: id, providerOrder: 0)
            m.genre = genre
            m.director = director
            return m
        }
        let movies = [
            movie("m1", "The Dark Knight (2008)", "c-action", genre: "Action, Crime", director: "Christopher Nolan"),
            movie("m2", "Batman Begins (2005)", "c-action", genre: "Action", director: "Christopher Nolan"),
            movie("m3", "Inception (2010)", "c-action", genre: "Action, Sci-Fi", director: "Christopher Nolan"),
            movie("m4", "Tenet (2020)", "c-action", genre: "Action, Sci-Fi", director: "Christopher Nolan"),
            movie("m5", "Toy Story (1995)", "c-kids", genre: "Animation", director: "John Lasseter"),
            movie("m6", "Cars (2006)", "c-kids", genre: "Animation", director: "John Lasseter"),
            movie("m8", "The Prestige (2006)", "c-action", genre: "Drama, Mystery", director: "Christopher Nolan"),
        ]
        try await db.replaceMovies(sourceId: "s", categories: categories, movies: movies)
        // Online metadata cached for one title adds cast the provider lacks.
        var md = MediaMetadata(kind: .movie, source: "Test", title: "Inception")
        md.cast = [CastMember(name: "Michael Caine")]
        try await db.saveMetadata(md, mediaId: "m3")

        let recommender = Recommender(db: db)
        let empty = await recommender.becauseYouWatched(libraryRevision: 1, hideAdult: false)
        #expect(empty.isEmpty) // no history yet

        let similar = await recommender.moreLike(movie: movies[0], metadata: nil, libraryRevision: 1, hideAdult: false)
        #expect(similar.count == 4)
        #expect(Set(similar.map(\.id)) == ["m2", "m3", "m4", "m8"])

        try await db.markWatched(WatchProgress(mediaId: "m1", kind: .movie, sourceId: "s", title: "The Dark Knight", position: 0, duration: 100), watched: true)
        try await db.saveProgress(WatchProgress(mediaId: "m2", kind: .movie, sourceId: "s", title: "Batman Begins", position: 30, duration: 100))
        let rows = await recommender.becauseYouWatched(libraryRevision: 1, hideAdult: false)
        #expect(rows.count == 1)
        #expect(rows.first?.seed.id == "m1")
        #expect(rows.first?.reason == .watched)
        #expect(Set(rows.first?.titles.map(\.id) ?? []) == ["m3", "m4", "m8"]) // Batman Begins was started

        // Hiding a category applies at once, without a rebuild.
        try await db.setCategoryHidden(categoryId: "c-action", true)
        #expect(await recommender.moreLike(movie: movies[0], metadata: nil, libraryRevision: 1, hideAdult: false).isEmpty)
        try await db.setCategoryHidden(categoryId: "c-action", false)

        // A library change (new revision) is picked up: the first query after it still uses the old index while
        // the new one builds; a later one sees the new title.
        var added = movie("m7", "Interstellar (2014)", "c-action", genre: "Sci-Fi", director: "Christopher Nolan")
        added.addedAt = Date()
        try await db.replaceMovies(sourceId: "s", categories: categories, movies: movies + [added])
        _ = await recommender.moreLike(movie: movies[0], metadata: nil, libraryRevision: 2, hideAdult: false)
        var found = false
        for _ in 0..<50 where !found {
            let ids = await recommender.moreLike(movie: movies[0], metadata: nil, libraryRevision: 2, hideAdult: false).map(\.id)
            found = ids.contains("m7")
            if !found { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(found)

        await recommender.clear()
        let afterClear = await recommender.moreLike(movie: movies[4], metadata: nil, libraryRevision: 2, hideAdult: false)
        #expect(afterClear.map(\.id) == ["m6"])
    }

    @Test func emptyLibrary() async throws {
        let db = try AppDatabase.inMemory()
        let recommender = Recommender(db: db)
        let movie = Movie(id: "x", sourceId: "s", categoryId: nil, name: "Nothing", providerId: "x", providerOrder: 0)
        #expect(await recommender.moreLike(movie: movie, metadata: nil, libraryRevision: 0, hideAdult: true).isEmpty)
        #expect(await recommender.becauseYouWatched(libraryRevision: 0, hideAdult: true).isEmpty)
    }
}

/// Synthetic library of the size of a big provider (≈ 41 k movies + 15 k shows). Opt-in, because unoptimised test
/// builds are several times slower than the app: `RECOMMENDER_BENCHMARK=1 scripts/test.sh -c release -Xswiftc -enable-testing --filter RecommendationBenchmark`.
@Suite("RecommendationBenchmark", .enabled(if: ProcessInfo.processInfo.environment["RECOMMENDER_BENCHMARK"] != nil))
struct RecommendationBenchmark {
    static func syntheticLibrary(movies: Int, series: Int) -> [RecommendationItem] {
        var rng = SystemRandomNumberGenerator()
        let genres = ["Action", "Drama", "Comedy", "Horror", "Romance", "Thriller", "Sci-Fi", "Animation", "Crime", "Documentary",
                      "دراما", "كوميدي", "اكشن", "رعب", "رومانسي", "اثارة"]
        let categories = (0..<400).map { "Category \($0) - قسم \($0 % 37) \(["Arabic", "English", "Turkish", "Indian", "Korean"][$0 % 5])" }
        let words = (0..<20_000).map { "word\($0)" } + (0..<5_000).map { "كلمة\($0)" }
        let people = (0..<30_000).map { "Person \($0)" }
        func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &rng)] }
        func item(_ i: Int, kind: RecommendationItem.Kind) -> RecommendationItem {
            let category = Int.random(in: 0..<categories.count, using: &rng)
            let hasDetails = kind == .series || i % 3 == 0 // providers list plots for shows, rarely for movies
            return RecommendationItem(
                id: "\(kind.rawValue)\(i)", kind: kind, title: (0..<Int.random(in: 1...4, using: &rng)).map { _ in pick(words) }.joined(separator: " "),
                year: Int.random(in: 1960...2025, using: &rng), rating: Double.random(in: 0...10, using: &rng),
                categoryId: "cat\(category)", categoryName: categories[category],
                genres: (0..<Int.random(in: 1...3, using: &rng)).map { _ in pick(genres) },
                cast: hasDetails ? (0..<5).map { _ in pick(people) } : [], directors: hasDetails ? [pick(people)] : [],
                plot: hasDetails ? (0..<45).map { _ in pick(words) }.joined(separator: " ") : nil
            )
        }
        return (0..<movies).map { item($0, kind: .movie) } + (0..<series).map { item($0, kind: .series) }
    }

    @Test func buildAndQuery() {
        let items = Self.syntheticLibrary(movies: 38_000, series: 12_000)
        let clock = ContinuousClock()
        var index: RecommendationIndex?
        let build = clock.measure { index = RecommendationIndex(items: items) }
        guard let index else { return }
        var worst = Duration.zero
        let queries = clock.measure {
            for i in stride(from: 0, to: 50_000, by: 500) {
                let id = i < 38_000 ? "movie\(i)" : "series\(i - 38_000)"
                let one = clock.measure { _ = index.similar(toId: id, options: RecommendationOptions(hiddenCategoryIds: ["cat1", "cat2"], hideAdult: true)) }
                worst = max(worst, one)
            }
        }
        let live = clock.measure { _ = index.similar(to: items[123]) }
        print("""
            RecommendationBenchmark: \(index.count) titles, \(index.termCount) terms, \(index.nonZeroCount) weights, \
            ~\(index.approximateVectorBytes / 1_048_576) MB vectors; build \(build); 100 queries \(queries) (worst \(worst)); \
            live-item query \(live)
            """)
        #expect(worst < .milliseconds(100))
    }

    /// The same library through SQLite: loading the corpus, then the first query through `Recommender` (which builds).
    @Test func throughTheDatabase() async throws {
        let items = Self.syntheticLibrary(movies: 38_000, series: 12_000)
        let db = try AppDatabase.inMemory()
        try await db.save(Source(id: "s", name: "S", kind: .xtream, url: "http://x"))
        func list(_ values: [String]) -> String? { values.isEmpty ? nil : values.joined(separator: ", ") }
        let movies = items.filter { $0.kind == .movie }.enumerated().map { i, item in
            var m = Movie(id: item.id, sourceId: "s", categoryId: item.categoryId, name: item.title, providerId: item.id, providerOrder: i)
            m.year = item.year.map(String.init)
            m.rating = item.rating
            m.genre = list(item.genres)
            m.cast = list(item.cast)
            m.director = list(item.directors)
            m.plot = item.plot
            return m
        }
        let series = items.filter { $0.kind == .series }.enumerated().map { i, item in
            var s = Series(id: item.id, sourceId: "s", categoryId: item.categoryId, name: item.title, providerId: item.id, providerOrder: i)
            s.genre = list(item.genres)
            s.cast = list(item.cast)
            s.plot = item.plot
            return s
        }
        let names = Dictionary(items.compactMap { item in item.categoryId.map { ($0, item.categoryName ?? "") } }, uniquingKeysWith: { a, _ in a })
        let categories = names.map { Category(id: $0.key, sourceId: "s", kind: .movie, name: $0.value, providerOrder: 0) }
        try await db.replaceVOD(sourceId: "s", movieCategories: categories, movies: movies, seriesCategories: [], series: series)

        let clock = ContinuousClock()
        var corpus: [RecommendationItem] = []
        let load = try await clock.measure { corpus = try await db.recommendationCorpus() }
        let recommender = Recommender(db: db)
        let first = await clock.measure { _ = await recommender.moreLike(movie: movies[7], metadata: nil, libraryRevision: 1, hideAdult: true) }
        let second = await clock.measure { _ = await recommender.moreLike(movie: movies[8], metadata: nil, libraryRevision: 1, hideAdult: true) }
        print("RecommendationBenchmark DB: \(corpus.count) titles, corpus load \(load); first query incl. build \(first); next query \(second)")
        #expect(corpus.count == 50_000)
    }
}
