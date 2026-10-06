import Testing
@testable import TunerCore

/// Real category names from an Arabic/English Xtream panel: bilingual "English - عربي", bracketed parts,
/// Arabic-only names and year shelves.
@Suite("Category grouping")
struct CategoryGroupingTests {
    func group(_ name: String) -> CategoryGroup { CategoryClassifier.facet(for: name).group }

    @Test func yearShelvesGoToByYear() {
        #expect(group("Arabic Movies - عربي 2024") == .byYear)
        #expect(group("English Movies -  2023 اجنبي") == .byYear)
        #expect(group("Arabic Movies -  [  2010 - 2016 ] عربي") == .byYear)
        #expect(group("English Movies [ 2000- 2016 ] اجنبي") == .byYear)
    }

    @Test func seasonalShelvesStayFeaturedDespiteAYear() {
        #expect(group("RAMADAN 2026 مصر") == .featured)
        #expect(group("RAMADAN 2026 سوريا") == .featured)
        #expect(group("مرشحون لجوائز الأوسكار 2023") == .featured)
    }

    @Test func platforms() {
        #expect(group("Netflix - أفلام نت فليكس") == .platforms)
        #expect(group("Shahid vip - أفلام منصة شاهد") == .platforms)
        #expect(group("Disney+ - ديزني بالعربي") == .platforms)
        #expect(group("WATCH-IT - أفلام منصة واتش ات") == .platforms)
        #expect(group("Osn Box Office") == .platforms)
        // BeIN's entertainment channels aren't sport.
        #expect(group("BeIN Entertainment - بين الترفيهية") != .sports)
    }

    @Test func arabicWordsInsideOtherWordsDontMatch() {
        // "المشاهدة" (viewing) contains "شاهد" (Shahid) but isn't the platform.
        #expect(group("Short Series [ تستحق المشاهدة ]") != .platforms)
    }

    @Test func sportsKidsAndGenres() {
        #expect(group("Bein Sport [ FHD ]") == .sports)
        #expect(group("WWE - مصارعة متجددة") == .sports)
        #expect(group("ملخصات المباريات") == .sports)
        #expect(group("Thmanyah | ثمانية | الدوري السعودي") == .sports)
        #expect(group("Spacetoon go - سبيستون غو") == .kids)
        #expect(group("kids [ AR ] - باقه الاطفال العربية") == .kids)
        #expect(group("Action - افلام اكشن اجنبيه") == .genres)
        #expect(group("Drama- افلام اجنبيه دراما") == .genres)
        #expect(group("documentaries  - افلام وثائقية") == .genres)
        #expect(group("Anime With English sub - انمي مترجم للانجليزية") == .genres)
        #expect(group("Concerts - حفلات") == .genres)
    }

    @Test func qualityAndFeatured() {
        #expect(group("4k Movies [ افلام اجنبية تحتاج اجهزه قوية ونت قوي ]") == .quality)
        #expect(group("Pure Movies - افلام اجنبية فائقة الجودة") == .quality)
        #expect(group("Movies Multi Sub - أفلام متعددة التراجم") == .quality)
        #expect(group("Box Office -  افلام السنه المميزة") == .featured)
        #expect(group("IMDB [ TOP 264 Movie ] - أفضل افلام التاريخ") == .featured)
        #expect(group("Marvel Movies - عالم مارفل كامل") == .featured)
        #expect(group("[ مسلسلات عربية تعرض حاليا ]") == .featured)
    }

    @Test func languagesAndCountries() {
        #expect(group("Turkish movies - افلام تركية") == .languages)
        #expect(group("Korean movies - افلام كورية") == .languages)
        #expect(group("Syrian Series [ سورية ]") == .languages)
        #expect(group("Egypt - مصر") == .languages)
        #expect(group("UK - انجلترا") == .languages)
        #expect(group("السعودية") == .languages)
    }

    @Test func unknownNamesGoToMore() {
        #expect(group("Amos") == .more)
        #expect(group("الدكتور راغب السرجاني") == .more)
    }

    @Test func namesSplitByScript() {
        let facet = CategoryClassifier.facet(for: "Bein Sport  [ UHD ] | [ تحتاج اجهزه قوية ونت قوي ]")
        #expect(facet.latinName == "Bein Sport · UHD")
        #expect(facet.arabicName == "تحتاج اجهزه قوية ونت قوي")
        #expect(facet.displayName(.automatic) == "Bein Sport · UHD")
        #expect(facet.displayName(.arabic) == "تحتاج اجهزه قوية ونت قوي")
        #expect(facet.displayName(.original) == "Bein Sport  [ UHD ] | [ تحتاج اجهزه قوية ونت قوي ]")
    }

    @Test func hyphenatedWordsAreNotSplit() {
        #expect(CategoryClassifier.facet(for: "Sci-Fi - افلام خيال علمي").latinName == "Sci-Fi")
        #expect(CategoryClassifier.facet(for: "Drama- افلام اجنبيه دراما").latinName == "Drama")
    }

    @Test func yearsAreKeptInTheDisplayName() {
        let year = CategoryClassifier.facet(for: "English Movies -  2026 اجنبي")
        #expect(year.latinName == "English Movies")
        #expect(year.arabicName == "اجنبي")
        #expect(year.displayName(.automatic) == "English Movies 2026")
        #expect(year.displayName(.arabic) == "اجنبي 2026")
        #expect(year.latestYear == 2026)

        let range = CategoryClassifier.facet(for: "Arabic Movies -  [  2010 - 2016 ] عربي")
        #expect(range.yearLabel == "2010–2016")
        #expect(range.displayName(.automatic) == "Arabic Movies 2010–2016")
        #expect(range.latestYear == 2016)
    }

    @Test func arabicOnlyNamesKeepTheirName() {
        let facet = CategoryClassifier.facet(for: "[ مسلسلات تركية تعرض حاليا ]")
        #expect(facet.latinName == nil)
        #expect(facet.displayName(.automatic) == "مسلسلات تركية تعرض حاليا")
    }
}
