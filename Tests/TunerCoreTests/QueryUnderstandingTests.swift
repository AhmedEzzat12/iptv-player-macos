import Foundation
import Testing
@testable import TunerCore

@Suite("Natural search: query parsing")
struct QueryUnderstandingTests {
    func parse(_ q: String) -> ParsedSearch { QueryUnderstanding.parse(q, currentYear: 2026) }

    // MARK: English

    @Test func kindGenreAndDecade() {
        let p = parse("90s comedy series")
        #expect(p.filters == [.years(.decade(1990)), .genre(.comedy), .kind(.series)])
        #expect(p.text == "")
        #expect(p.filters.map(\.title) == ["1990s", "Comedy", "TV Shows"])
    }

    @Test func languageGenreKind() {
        let p = parse("Arabic drama movies")
        #expect(p.filters == [.language(.arabic), .genre(.drama), .kind(.movie)])
        #expect(p.text == "")
    }

    @Test func kinds() {
        #expect(parse("movies").kind == .movie)
        #expect(parse("films").kind == .movie)
        #expect(parse("film").kind == .movie)
        #expect(parse("tv shows").kind == .series)
        #expect(parse("TV series").kind == .series)
        #expect(parse("shows").kind == .series)
        // Both asked for: no kind filter, the words still go.
        let both = parse("horror movies and series")
        #expect(both.kind == nil)
        #expect(both.genres == [.horror])
        #expect(both.text == "")
    }

    @Test func decadesInEveryForm() {
        for q in ["90s", "'90s", "90's", "1990s", "nineties", "the nineties", "from the 90s"] {
            #expect(parse(q + " movies").years == .decade(1990), "\(q)")
        }
        #expect(parse("80s horror").years == .decade(1980))
        #expect(parse("2000s comedies").years == .decade(2000))
        #expect(parse("00s comedies").years == .decade(2000))
        #expect(parse("2010s dramas").years == .decade(2010))
        #expect(parse("eighties action").years == .decade(1980))
    }

    @Test func yearsAndRanges() {
        #expect(parse("movies from 2015").years == YearSpan(from: 2015, to: nil))
        #expect(parse("movies from 2015").text == "")
        #expect(parse("series since 2020").years == YearSpan(from: 2020, to: nil))
        #expect(parse("comedies after 2015").years == YearSpan(from: 2016, to: nil))
        #expect(parse("horror before 2000").years == YearSpan(from: nil, to: 1999))
        #expect(parse("horror until 2000").years == YearSpan(from: nil, to: 2000))
        #expect(parse("action 2010-2015").years == YearSpan(from: 2010, to: 2015))
        #expect(parse("action 2010–2015").years == YearSpan(from: 2010, to: 2015))
        #expect(parse("action 2010-15").years == YearSpan(from: 2010, to: 2015))
        #expect(parse("action 2010 to 2015").years == YearSpan(from: 2010, to: 2015))
        #expect(parse("action from 2010 to 2015").years == YearSpan(from: 2010, to: 2015))
        #expect(parse("movies between 2010 and 2015").years == YearSpan(from: 2010, to: 2015))
        #expect(parse("movies between 2010 and 2015").text == "")
        #expect(parse("comedy 2015").years == .year(2015))
        #expect(parse("comedy movies in 2015").text == "")
        #expect(YearSpan(from: 2010, to: 2015).title == "2010–2015")
        #expect(YearSpan(from: 2015, to: nil).title == "Since 2015")
        #expect(YearSpan.year(2015).title == "2015")
    }

    @Test func numbersThatArentYearsStayText() {
        // Future years and short numbers are part of the title.
        let p = parse("blade runner 2049")
        #expect(p.filters.isEmpty)
        #expect(p.text == "blade runner 2049")
        #expect(parse("apollo 13 movie").text == "apollo 13")
        #expect(parse("ocean's 11").filters.isEmpty)
    }

    @Test func genres() {
        let cases: [(String, SearchGenre)] = [
            ("comedy", .comedy), ("comedies", .comedy), ("funny movies", .comedy), ("drama", .drama),
            ("action", .action), ("horror", .horror), ("romance", .romance), ("romantic movies", .romance),
            ("thriller", .thriller), ("animation", .animation), ("animated movies", .animation), ("cartoons", .animation),
            ("anime", .animation), ("documentary", .documentary), ("documentaries", .documentary), ("family movies", .family),
            ("crime series", .crime), ("sci-fi", .sciFi), ("scifi movies", .sciFi), ("science fiction", .sciFi),
            ("war movies", .war), ("historical dramas", .history), ("kids movies", .kids), ("movies for kids", .kids),
            ("adventure", .adventure), ("mystery", .mystery), ("fantasy", .fantasy),
        ]
        for (q, genre) in cases {
            #expect(parse(q).genres.contains(genre), "\(q)")
            #expect(parse(q).text == "", "\(q)")
        }
        #expect(parse("rom-com").genres == [.romance, .comedy])
        #expect(parse("action comedy").genres == [.action, .comedy])
        #expect(parse("sitcoms").filters == [.kind(.series), .genre(.comedy)])
        #expect(parse("k-drama").filters == [.language(.korean), .genre(.drama)])
    }

    @Test func languages() {
        let cases: [(String, SearchLanguage)] = [
            ("arabic movies", .arabic), ("egyptian comedies", .egyptian), ("turkish series", .turkish),
            ("korean drama", .korean), ("indian movies", .indian), ("hindi movies", .indian), ("bollywood", .indian),
            ("english series", .english), ("foreign films", .english), ("syrian series", .syrian),
            ("khaleeji series", .gulf), ("french movies", .french), ("japanese anime", .japanese),
        ]
        for (q, language) in cases {
            #expect(parse(q).languages == [language], "\(q)")
        }
    }

    @Test func qualityAndRating() {
        #expect(parse("4k movies").filters == [.quality4K, .kind(.movie)])
        #expect(parse("UHD action").wants4K)
        #expect(parse("top rated korean dramas").filters == [.topRated, .language(.korean), .genre(.drama)])
        #expect(parse("top rated korean dramas").text == "")
        #expect(parse("highly rated thrillers").topRated)
        #expect(parse("best horror movies of the 80s").filters == [.topRated, .genre(.horror), .kind(.movie), .years(.decade(1980))])
        #expect(parse("best horror movies of the 80s").text == "")
    }

    @Test func leftoverWordsStayAsTitleText() {
        let p = parse("batman movies")
        #expect(p.kind == .movie)
        #expect(p.text == "batman")
        let q = parse("show me some Arabic comedies with Adel Imam")
        #expect(q.filters == [.language(.arabic), .genre(.comedy)])
        #expect(q.text == "Adel Imam")
        // Original spelling and case are kept.
        #expect(parse("Lucifer series").text == "Lucifer")
    }

    @Test func titlesWithoutFilterWordsAreUntouched() {
        for title in ["Breaking Bad", "The Office", "Friends", "Game of Thrones", "The Lord of the Rings", "Find Nemo", "a quiet place"] {
            let p = parse(title)
            #expect(p.filters.isEmpty, "\(title)")
            #expect(p.text == title, "\(title)")
        }
    }

    @Test func connectorsOnlyGoNextToFilters() {
        // "the" and "of" belong to the title here; only "4k" is understood.
        let p = parse("the lord of the rings 4k")
        #expect(p.filters == [.quality4K])
        #expect(p.text == "the lord of the rings")
        #expect(parse("lost in translation movie").text == "lost in translation")
        #expect(parse("from dusk till dawn movie").text == "from dusk till dawn")
        #expect(parse("new girl series").text == "new girl")
        // A year after a title narrows to that release.
        let star = parse("a star is born 2018")
        #expect(star.years == .year(2018))
        #expect(star.text == "a star is born")
        #expect(parse("Spider-Man 2002").text == "Spider-Man")
    }

    // MARK: Arabic

    @Test func arabicKindsAndGenres() {
        #expect(parse("أفلام رعب").filters == [.kind(.movie), .genre(.horror)])
        #expect(parse("افلام الرعب").filters == [.kind(.movie), .genre(.horror)])
        #expect(parse("فيلم كوميدي").filters == [.kind(.movie), .genre(.comedy)])
        #expect(parse("مسلسلات كوميدية").filters == [.kind(.series), .genre(.comedy)])
        #expect(parse("مسلسل دراما").filters == [.kind(.series), .genre(.drama)])
        #expect(parse("أفلام أكشن").filters == [.kind(.movie), .genre(.action)])
        #expect(parse("افلام رومانسية").genres == [.romance])
        #expect(parse("أفلام إثارة").genres == [.thriller])
        #expect(parse("كرتون").genres == [.animation])
        #expect(parse("انمي").genres == [.animation])
        #expect(parse("أفلام وثائقية").genres == [.documentary])
        #expect(parse("وثائقيات").genres == [.documentary])
        #expect(parse("أفلام عائلية").genres == [.family])
        #expect(parse("مسلسلات جريمة").genres == [.crime])
        #expect(parse("افلام خيال علمي").filters == [.kind(.movie), .genre(.sciFi)])
        #expect(parse("أفلام الخيال العلمي").filters == [.kind(.movie), .genre(.sciFi)])
        #expect(parse("أفلام حرب").genres == [.war])
        #expect(parse("مسلسلات تاريخية").genres == [.history])
        #expect(parse("أفلام أطفال").genres == [.kids])
        #expect(parse("افلام للاطفال").genres == [.kids])
        #expect(parse("رسوم متحركة").genres == [.animation])
    }

    @Test func arabicLanguages() {
        #expect(parse("مسلسلات تركية رومانسية").filters == [.kind(.series), .language(.turkish), .genre(.romance)])
        #expect(parse("مسلسلات تركية رومانسية").text == "")
        #expect(parse("أفلام عربي").languages == [.arabic])
        #expect(parse("افلام عربية").languages == [.arabic])
        #expect(parse("مسلسل مصري").languages == [.egyptian])
        #expect(parse("مسلسلات كورية").languages == [.korean])
        #expect(parse("افلام هندي").languages == [.indian])
        #expect(parse("أفلام أجنبية").languages == [.english])
        #expect(parse("مسلسلات سورية").languages == [.syrian])
        #expect(parse("مسلسلات خليجية").languages == [.gulf])
        #expect(parse("افلام بالعربي").languages == [.arabic])
    }

    @Test func arabicYears() {
        #expect(parse("أفلام التسعينات").filters == [.kind(.movie), .years(.decade(1990))])
        #expect(parse("افلام الثمانينات").years == .decade(1980))
        #expect(parse("مسلسلات الثمانينيات").years == .decade(1980))
        #expect(parse("أفلام السبعينات").years == .decade(1970))
        #expect(parse("افلام الالفينات").years == .decade(2000))
        #expect(parse("أفلام من 2015").years == YearSpan(from: 2015, to: nil))
        #expect(parse("أفلام من 2015").text == "")
        #expect(parse("افلام من 2010 الى 2015").years == YearSpan(from: 2010, to: 2015))
        #expect(parse("أفلام من 2010 إلى 2015").years == YearSpan(from: 2010, to: 2015))
        #expect(parse("افلام بعد 2015").years == YearSpan(from: 2016, to: nil))
        #expect(parse("افلام قبل 2000").years == YearSpan(from: nil, to: 1999))
        #expect(parse("افلام سنة 2015").filters == [.kind(.movie), .years(.year(2015))])
        #expect(parse("افلام سنة 2015").text == "")
        // Arabic-Indic digits.
        #expect(parse("أفلام ٢٠١٥").years == .year(2015))
    }

    @Test func arabicRatingAndMixed() {
        #expect(parse("أفضل أفلام الرعب").filters == [.topRated, .kind(.movie), .genre(.horror)])
        #expect(parse("افلام الاعلى تقييما").filters == [.kind(.movie), .topRated])
        #expect(parse("أفلام أكشن 4K").wants4K)
        // A name left over keeps its Arabic spelling.
        let p = parse("أفلام عادل إمام الكوميدية")
        #expect(p.filters == [.kind(.movie), .genre(.comedy)])
        #expect(p.text == "عادل إمام")
        // Arabic and English mixed.
        #expect(parse("مسلسلات korean").filters == [.kind(.series), .language(.korean)])
    }

    @Test func arabicTitlesWithoutFilterWordsAreUntouched() {
        for title in ["باب الحارة", "الهيبة", "ليالي الحلمية"] {
            #expect(parse(title).filters.isEmpty, "\(title)")
            #expect(parse(title).text == title, "\(title)")
        }
    }

    // MARK: Chips

    @Test func removingAChipDropsOnlyThatFilter() {
        let p = parse("90s comedy series").removing([.genre(.comedy)])
        #expect(p.filters == [.years(.decade(1990)), .kind(.series)])
        #expect(p.text == "")
        #expect(p.removing([]).filters == p.filters)
    }

    @Test func emptyAndPunctuation() {
        #expect(parse("").filters.isEmpty)
        #expect(parse("   ").text == "")
        #expect(parse("comedy, drama!").genres == [.comedy, .drama])
    }

    // MARK: Titles

    @Test func titleMatching() {
        #expect(QueryUnderstanding.title("Family Guy", matches: "family guy"))
        #expect(QueryUnderstanding.title("Family Guy", matches: "Family g"))
        #expect(QueryUnderstanding.title("That '90s Show", matches: "that 90s show"))
        #expect(QueryUnderstanding.title("Top Gun: Maverick", matches: "top gun"))
        #expect(QueryUnderstanding.title("EN - Kids", matches: "kids"))
        #expect(QueryUnderstanding.title("Kids", matches: "kids"))
        // One word must be the whole title; several must be whole words.
        #expect(!QueryUnderstanding.title("The Rocky Horror Picture Show", matches: "horror"))
        #expect(!QueryUnderstanding.title("Comedy Central Roast", matches: "comedy series"))
        #expect(!QueryUnderstanding.title("Warcraft", matches: "war"))
        #expect(QueryUnderstanding.title("أفلام الأبيض والأسود", matches: "افلام الابيض"))
    }

    // MARK: Model suggestions

    @Test func onlyEnglishPhrasesWithLeftoverWordsGoToTheModel() {
        #expect(QueryUnderstanding.shouldAskModel(parse("something for a rainy night")))
        #expect(QueryUnderstanding.shouldAskModel(parse("feel good movies about friendship")))
        #expect(!QueryUnderstanding.shouldAskModel(parse("90s comedy series")))  // fully understood
        #expect(!QueryUnderstanding.shouldAskModel(parse("batman")))  // too short
        #expect(!QueryUnderstanding.shouldAskModel(parse("أفلام عن الصداقة والحب")))  // Arabic
    }

    @Test func modelSuggestionsAreValidated() {
        let rules = parse("feel good movies about friendship")
        #expect(rules.kind == .movie)
        #expect(rules.text == "feel friendship")
        let refined = QueryUnderstanding.refine(rules, with: ModelSearchSuggestion(
            kind: "series", genres: ["Comedy", "drama", "Western", "Sci-Fi"], languages: ["klingon"],
            topRated: true, titleWords: "friendship Inception"
        ))
        // The rules' kind stays; at most two known genres; unknown language ignored; "top rated" needs a word like
        // "good" among the leftover words (here it's been dropped as a connector, so no); invented title words go.
        #expect(refined.filters == [.kind(.movie), .genre(.comedy), .genre(.drama)])
        #expect(refined.text == "friendship")

        let classics = QueryUnderstanding.refine(parse("great classic dramas everyone loves"), with: ModelSearchSuggestion(topRated: true, titleWords: ""))
        #expect(classics.topRated)
        #expect(classics.text == "")
        // The model never sets years.
        let noYears = QueryUnderstanding.refine(parse("movies like breaking bad"), with: ModelSearchSuggestion(languages: ["english"], titleWords: "breaking bad"))
        #expect(noYears.years == nil)
        #expect(noYears.languages == [.english])
        #expect(noYears.text == "breaking bad")
    }
}

@Suite("Natural search: library")
struct NaturalSearchDatabaseTests {
    let db: AppDatabase

    init() async throws {
        db = try AppDatabase.inMemory()
        try await db.save(Source(id: "src", name: "Test", kind: .m3u, url: "http://example.com/list.m3u"))
        let movieCats = [
            Category(id: "c_ar", sourceId: "src", kind: .movie, name: "Arabic Movies - أفلام عربي", providerOrder: 0),
            Category(id: "c_en", sourceId: "src", kind: .movie, name: "English Movies [ 2000- 2016 ] اجنبي", providerOrder: 1),
            Category(id: "c_horror", sourceId: "src", kind: .movie, name: "Horror - افلام الرعب", providerOrder: 2),
            Category(id: "c_4k", sourceId: "src", kind: .movie, name: "4k Movies", providerOrder: 3),
            Category(id: "c_kids", sourceId: "src", kind: .movie, name: "Spacetoon go - سبيستون غو", providerOrder: 4),
        ]
        func movie(_ id: String, _ name: String, cat: String, year: String? = nil, genre: String? = nil, rating: Double? = nil, release: String? = nil) -> Movie {
            var m = Movie(id: id, sourceId: "src", categoryId: cat, name: name, providerId: id, providerOrder: 0)
            m.year = year
            m.genre = genre
            m.rating = rating
            m.releaseDate = release
            return m
        }
        let movies = [
            movie("m1", "Al Irhabi", cat: "c_ar", year: "1994", genre: "Comedy, Drama", rating: 7.8),
            movie("m2", "الكيت كات", cat: "c_ar", year: "1991", genre: "كوميدي", rating: 8.1),
            movie("m3", "Inception", cat: "c_en", year: "2010", genre: "Action, Sci-Fi", rating: 8.8),
            movie("m4", "Scream", cat: "c_horror", genre: "Horror", rating: 7.4, release: "1996-12-20"),
            movie("m5", "Dune 4K", cat: "c_4k", year: "2021", genre: "Sci-Fi", rating: 8.0),
            movie("m6", "Bad Comedy", cat: "c_en", year: "1995", genre: "Comedy", rating: 3.1),
            movie("m7", "Detective Conan", cat: "c_kids", year: "1996"),
            movie("m8", "Top Gun", cat: "c_en", year: "1986", genre: "Action", rating: 6.9),
            movie("m9", "AR - Sahar El Layali", cat: "c_en", year: "2003", genre: "Drama"),
        ]
        let seriesCats = [
            Category(id: "s_tr", sourceId: "src", kind: .series, name: "Turkish Series - مسلسلات تركية", providerOrder: 0),
            Category(id: "s_en", sourceId: "src", kind: .series, name: "English Series", providerOrder: 1),
        ]
        func show(_ id: String, _ name: String, cat: String, year: String?, genre: String?) -> Series {
            var s = Series(id: id, sourceId: "src", categoryId: cat, name: name, providerId: id, providerOrder: 0)
            s.year = year
            s.genre = genre
            return s
        }
        let series = [
            show("s1", "Aşk-ı Memnu", cat: "s_tr", year: "2008", genre: "دراما، رومانسية"),
            show("s2", "Friends", cat: "s_en", year: "1994", genre: "Comedy"),
            show("s3", "Family Guy", cat: "s_en", year: "1999", genre: "Animation, Comedy"),
            show("s4", "That '90s Show", cat: "s_en", year: "2023", genre: "Comedy"),
        ]
        try await db.replaceVOD(sourceId: "src", movieCategories: movieCats, movies: movies, seriesCategories: seriesCats, series: series)
    }

    func understood(_ q: String) async -> ParsedSearch { await db.understandSearch(q, currentYear: 2026) }

    @Test func decadeGenreAndKind() async throws {
        let search = await understood("90s comedy series")
        #expect(search.filters == [.years(.decade(1990)), .genre(.comedy), .kind(.series)])
        #expect(try await db.movies(understood: search).isEmpty)
        #expect(Set(try await db.series(understood: search).map(\.id)) == ["s2", "s3"])
    }

    @Test func genreFromGenreTextOrCategory() async throws {
        // Genre text in English or Arabic; the horror category counts even without genre text.
        let comedies = try await db.movies(understood: await understood("comedy movies")).map(\.id)
        #expect(Set(comedies) == ["m1", "m2", "m6"])
        let horror = try await db.movies(understood: await understood("أفلام رعب")).map(\.id)
        #expect(horror == ["m4"])
    }

    @Test func languageFromCategoryOrTitle() async throws {
        let arabic = try await db.movies(understood: await understood("arabic movies")).map(\.id)
        #expect(Set(arabic) == ["m1", "m2", "m9"])  // m9 by its "AR - " title tag
        let turkish = try await db.series(understood: await understood("مسلسلات تركية رومانسية")).map(\.id)
        #expect(turkish == ["s1"])
    }

    @Test func yearsUseYearThenReleaseDate() async throws {
        let ninetiesHorror = try await db.movies(understood: await understood("90s horror")).map(\.id)
        #expect(ninetiesHorror == ["m4"])
        let since2010 = try await db.movies(understood: await understood("movies since 2010")).map(\.id)
        #expect(Set(since2010) == ["m3", "m5"])
    }

    @Test func topRatedSortsAndFilters() async throws {
        let best = try await db.movies(understood: await understood("best comedies")).map(\.id)
        #expect(best == ["m2", "m1"])  // Bad Comedy (3.1) is left out, highest first
    }

    @Test func fourKAndKids() async throws {
        #expect(try await db.movies(understood: await understood("4k movies")).map(\.id) == ["m5"])
        #expect(try await db.movies(understood: await understood("kids movies")).map(\.id) == ["m7"])
    }

    @Test func leftoverTextSearchesTitles() async throws {
        let search = await understood("inception movie")
        #expect(search.kind == .movie)
        #expect(try await db.movies(understood: search).map(\.id) == ["m3"])
    }

    @Test func exactLibraryTitlesWinOverParsing() async throws {
        #expect(await understood("Family Guy") == .plain("Family Guy"))
        #expect(await understood("family g") == .plain("family g"))
        #expect(await understood("That '90s Show") == .plain("That '90s Show"))
        #expect(await understood("top gun") == .plain("top gun"))
        // Not a title in this library: understood.
        #expect(await understood("family movies").hasFilters)
        #expect(await understood("comedy").hasFilters)
    }

    @Test func removedFiltersWiden() async throws {
        let search = await understood("90s comedy series").removing([.kind(.series)])
        #expect(Set(try await db.movies(understood: search).map(\.id)) == ["m1", "m2", "m6"])
    }
}
