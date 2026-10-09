import Foundation
import GRDB
import Testing
@testable import TunerCore

@Suite("Guide matcher")
struct GuideMatcherTests {
    /// Matches `name` against guide channels named `guide` (keys are the names themselves).
    func match(_ name: String, in guide: [String], sourceId: String? = nil) -> String? {
        GuideMatcher(candidates: guide.map { GuideMatcher.Candidate(key: $0, names: [$0]) }).match(name, sourceId: sourceId)?.key
    }

    // MARK: Cleaning

    @Test func cleaningStripsTagsPrefixesAndSeparators() throws {
        #expect(try #require(GuideMatcher.analyze("VIP DE: ZDF")).compact == "zdf")
        #expect(try #require(GuideMatcher.analyze("|AR| MBC 2 HD")).tokens == ["mbc", "2"])
        #expect(try #require(GuideMatcher.analyze("UK: BBC One FHD")).tokens == ["bbc", "1"])
        #expect(try #require(GuideMatcher.analyze("beIN SPORTS 1 4K")).tokens == ["bein", "sports", "1"])
        #expect(try #require(GuideMatcher.analyze("EN: CNN International (Backup)")).tokens == ["cnn", "international"])
        #expect(try #require(GuideMatcher.analyze("Sky Sports Main Event Backup 2")).numbers.isEmpty)
        #expect(try #require(GuideMatcher.analyze("FR | TF1 [Multi-Audio]")).tokens == ["tf", "1"])
        #expect(try #require(GuideMatcher.analyze("Discovery Channel HD")).tokens == ["discovery"])
        // A bare country code goes, words that look like one stay.
        #expect(try #require(GuideMatcher.analyze("UK Sky News")).tokens == ["sky", "news"])
        #expect(try #require(GuideMatcher.analyze("Al Jazeera")).tokens == ["al", "jazeera"])
        #expect(try #require(GuideMatcher.analyze("Sky Sports F1 UK")).country == "uk")
        #expect(GuideMatcher.analyze("E!") == nil)
    }

    @Test func timeshiftIsReadNotCounted() throws {
        let plus1 = try #require(GuideMatcher.analyze("Sky Sports Main Event +1"))
        #expect(plus1.timeshift == 1)
        #expect(plus1.numbers.isEmpty)
        #expect(try #require(GuideMatcher.analyze("Channel 4 (+1) HD")).timeshift == 1)
        #expect(try #require(GuideMatcher.analyze("Film4+2h")).timeshift == 2)
        // "Canal+" is a name, not a timeshift.
        let canal = try #require(GuideMatcher.analyze("Canal+ Sport"))
        #expect(canal.timeshift == 0)
        #expect(canal.tokens == ["canal", "plus", "sport"])
    }

    @Test func arabicIsTransliterated() throws {
        let jazeera = try #require(GuideMatcher.analyze("AR - الجزيرة"))
        #expect(jazeera.arabic)
        #expect(jazeera.tokens.allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) })
        #expect(jazeera.skeleton == GuideMatcher.analyze("Al Jazeera")?.skeleton)
        // Arabic-Indic digits are numbers like any other.
        #expect(GuideMatcher.analyze("MBC ٢")?.numbers == ["2"])
    }

    // MARK: Positive matches

    @Test(arguments: [
        ("VIP DE: ZDF", "ZDF"),
        ("|AR| MBC 2 HD", "MBC2"),
        ("beIN SPORTS 1 4K", "beIN Sports 1 HD"),
        ("UK: BBC One FHD", "BBC One"),
        ("BBC 1", "BBC One"),
        ("Sky Sport Main Event", "Sky Sports Main Event"),
        ("Sky Sports Main Event +1", "Sky Sports Main Event HD +1"),
        ("Discovery Channel HD", "Discovery"),
        ("Sky Sports Premier League UK", "Sky Sports Premier League"),
        ("EN: CNN International (Backup)", "CNN International"),
        ("FR | TF1 [Multi-Audio]", "TF1"),
        ("Euro Sport 1", "Eurosport 1"),
        ("National Geographic Documentry", "National Geographic Documentary"),
    ])
    func matches(_ channel: String, _ guideName: String) {
        #expect(match(channel, in: [guideName, "Unrelated Channel", "CNN", "Sky News"]) == guideName)
    }

    // MARK: Guards

    @Test func numbersMustAgree() {
        let guide = ["beIN Sports 1", "beIN Sports 2", "beIN Sports 3"]
        #expect(match("beIN SPORTS 2 FHD", in: guide) == "beIN Sports 2")
        #expect(match("beIN Sports 1", in: ["beIN Sports 2"]) == nil)
        #expect(match("beIN Sports", in: guide) == nil)
        #expect(match("MBC", in: ["MBC 2", "MBC 4"]) == nil)
        #expect(match("HBO", in: ["HBO 2"]) == nil)
        #expect(match("ESPN", in: ["ESPN2"]) == nil)
    }

    @Test func timeshiftVariantsOnlyMatchTheSameVariant() {
        #expect(match("Sky Sports Main Event", in: ["Sky Sports Main Event +1"]) == nil)
        #expect(match("Sky Sports Main Event +1", in: ["Sky Sports Main Event"]) == nil)
        #expect(match("Film4 +1", in: ["Film4 +2"]) == nil)
        #expect(match("UK: Film4 +1 HD", in: ["Film4", "Film4 +1"]) == "Film4 +1")
    }

    @Test func regionalFeedsStayApart() {
        #expect(match("HBO East", in: ["HBO West"]) == nil)
        #expect(match("HBO", in: ["HBO East"]) == nil)
        #expect(match("BBC One London", in: ["BBC One"]) == nil)
    }

    @Test func extraWordsMeanAnotherChannel() {
        #expect(match("Sky Sports", in: ["Sky Sports News"]) == nil)
        #expect(match("Sky Sports News", in: ["Sky Sports"]) == nil)
        #expect(match("Sky Sports Golf", in: ["Sky Sports Gold"]) == nil)
        #expect(match("Sky Cinema Action", in: ["Sky Cinema Comedy"]) == nil)
        #expect(match("Cartoon Network", in: ["Cartoon Network Arabic"]) == nil)
        #expect(match("Al Jazeera", in: ["Al Jazeera English", "Al Jazeera Documentary"]) == nil)
        #expect(match("Al Jazeera EN", in: ["Al Jazeera"]) == nil)
        #expect(match("MBC Drama", in: ["MBC Drama Plus"]) == nil)
        #expect(match("Canal+", in: ["Canal"]) == nil)
        #expect(match("Nickelodeon", in: ["Nickelodeon Junior"]) == nil)
    }

    @Test func shortNamesMustBeIdentical() {
        #expect(match("CBS", in: ["CBC"]) == nil)
        #expect(match("ARD", in: ["ART"]) == nil)
        #expect(match("ZDF", in: ["ZDF neo"]) == nil)
        #expect(match("VIP ZDF HD", in: ["ZDF"]) == "ZDF")
    }

    @Test func conflictingCountriesNeverMatch() {
        #expect(match("US: Fox Sports 1", in: ["Fox Sports 1 AU"]) == nil)
        #expect(match("US: Fox Sports 1", in: ["Fox Sports 1 AU", "Fox Sports 1 US"]) == "Fox Sports 1 US")
        // The country an XMLTV id carries counts too.
        let guide = GuideMatcher(candidates: [
            GuideMatcher.Candidate(key: "au", names: GuideMatcher.names(displayName: "Fox Sports 1", xmltvId: "FoxSports1.au")),
            GuideMatcher.Candidate(key: "us", names: GuideMatcher.names(displayName: "Fox Sports 1", xmltvId: "FoxSports1.us@SD")),
        ])
        #expect(guide.match("US| Fox Sports 1 HD", sourceId: nil)?.key == "us")
    }

    // MARK: Arabic

    @Test func arabicMatchesArabic() {
        #expect(match("AR - الجزيرة HD", in: ["الجزيرة", "الجزيرة مباشر"]) == "الجزيرة")
        #expect(match("الجزيرة", in: ["الجزيرة مباشر", "الجزيرة الوثائقية"]) == nil)
    }

    @Test(arguments: [
        ("AR - الجزيرة", "Al Jazeera"),
        ("الجزيرة مباشر", "Al Jazeera Mubasher"),
        ("الحدث", "Al Hadath"),
        ("روتانا سينما", "Rotana Cinema"),
        ("سكاي نيوز عربية", "Sky News Arabia"),
        ("MBC مصر", "MBC Masr"),
    ])
    func arabicMatchesLatin(_ arabic: String, _ latin: String) {
        #expect(match(arabic, in: [latin, "Al Arabiya", "Dubai TV", "Rotana Classic"]) == latin)
        // And the other way round.
        #expect(match(latin, in: [arabic, "العربية", "دبي"]) == arabic)
    }

    @Test func arabicLatinIsCareful() {
        // Two Latin names with the same consonants: ambiguous, so neither.
        #expect(match("الجزيرة", in: ["Al Jazeera", "Al Gezira"]) == nil)
        // Different words, and too few consonants to tell names apart.
        #expect(match("الجزيرة", in: ["Al Jazeera Mubasher"]) == nil)
        #expect(match("العربية", in: ["Al Arabiya", "Arab"]) == nil)
        #expect(match("روتانا سينما", in: ["Rotana Classic"]) == nil)
        // Numbers still have to agree.
        #expect(match("روتانا سينما 2", in: ["Rotana Cinema"]) == nil)
    }

    // MARK: Ambiguity, preference, determinism

    @Test func nearTiesBetweenDifferentNamesAreRefused() {
        #expect(match("Sky Sport Main Event", in: ["Sky Sports Main Event", "Sky Sport Main Events"]) == nil)
    }

    @Test func sameNameInSeveralFeedsPrefersProgrammesThenOwnSource() {
        func candidate(_ key: String, _ source: String?, priority: Int = 0, programs: Bool = true) -> GuideMatcher.Candidate {
            GuideMatcher.Candidate(key: key, names: ["ZDF HD"], sourceId: source, priority: priority, hasPrograms: programs)
        }
        let all = [candidate("other", "b"), candidate("global", nil), candidate("own", "a"), candidate("own-2", "a", priority: 1)]
        #expect(GuideMatcher(candidates: all).match("VIP DE: ZDF", sourceId: "a")?.key == "own")
        #expect(GuideMatcher(candidates: all).match("VIP DE: ZDF", sourceId: "c")?.key == "global")
        #expect(GuideMatcher(candidates: [candidate("other", "b"), candidate("own", "a", programs: false)])
            .match("VIP DE: ZDF", sourceId: "a")?.key == "other")
        // A better-named candidate from another playlist doesn't lose to a merely close one from this playlist's feed…
        let mixed = [
            GuideMatcher.Candidate(key: "exact", names: ["Sky Sport Main Event"], sourceId: "b"),
            GuideMatcher.Candidate(key: "close", names: ["Sky Sports Main Event"], sourceId: "a"),
        ]
        #expect(GuideMatcher(candidates: mixed).match("UK: Sky Sport Main Event", sourceId: "a")?.key == "exact")
        // …but between near-equals, this playlist's feed wins.
        let near = [
            GuideMatcher.Candidate(key: "theirs", names: ["Sky Sports Main Event"], sourceId: "b"),
            GuideMatcher.Candidate(key: "ours", names: ["Sky Sport Main Events"], sourceId: "a"),
        ]
        #expect(GuideMatcher(candidates: near).match("Sky Sport Main Event", sourceId: "a")?.key == "ours")
        #expect(GuideMatcher(candidates: near).match("Sky Sport Main Event", sourceId: "z") == nil)
    }

    @Test func resultsDoNotDependOnOrder() {
        let names = ["beIN Sports 1 HD", "beIN Sports 1", "beIN Sports 2", "Sky Sports Main Event", "Sky Sports Main Event +1",
                     "الجزيرة", "Al Jazeera", "ZDF", "ZDF HD", "MBC2"]
        let candidates = names.enumerated().map { GuideMatcher.Candidate(key: "k\($0.offset)", names: [$0.element], sourceId: $0.offset.isMultiple(of: 2) ? "a" : nil) }
        let queries = ["beIN SPORTS 1 4K", "Sky Sport Main Event", "AR - الجزيرة", "VIP DE: ZDF", "|AR| MBC 2 HD", "Sky Sports Main Event +1"]
        let expected = queries.map { GuideMatcher(candidates: candidates).match($0, sourceId: "a") }
        #expect(expected.compactMap { $0 }.count == queries.count)
        for seed in 0..<5 {
            var rng = SeededGenerator(seed: UInt64(seed + 1))
            let shuffled = GuideMatcher(candidates: candidates.shuffled(using: &rng))
            #expect(queries.map { shuffled.match($0, sourceId: "a") } == expected)
        }
    }

    @Test func xmltvIdsGiveAnotherName() {
        #expect(GuideMatcher.names(displayName: "BBC One", xmltvId: "BBCOne.uk@SD") == ["BBC One", "BBCOne uk"])
        #expect(GuideMatcher.names(displayName: "BBC One", xmltvId: "12345") == ["BBC One"])
        let guide = GuideMatcher(candidates: [
            GuideMatcher.Candidate(key: "zdf", names: GuideMatcher.names(displayName: "Zweites Deutsches Fernsehen", xmltvId: "ZDFinfo.de")),
        ])
        #expect(guide.match("DE: ZDF Info HD", sourceId: nil)?.key == "zdf")
        #expect(guide.match("UK: ZDF Info", sourceId: nil) == nil)
    }
}

/// Deterministic shuffles for the order test.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 33)
    }
}

/// End to end through GuideService: off = exactly as before, on = automatic matches stored and dropped again.
@Suite("Smart guide matching")
struct SmartGuideMatchingTests {
    let db: AppDatabase
    let guideFile: URL

    static let playlist = """
        #EXTM3U
        #EXTINF:-1 tvg-id="cnn.us" group-title="News",CNN HD
        http://example.com/cnn.ts
        #EXTINF:-1 group-title="DE",VIP DE: ZDF HD
        http://example.com/zdf.ts
        #EXTINF:-1 group-title="Sport",beIN SPORTS 1 4K
        http://example.com/bein1.ts
        #EXTINF:-1 group-title="Sport",beIN SPORTS 3 4K
        http://example.com/bein3.ts
        #EXTINF:-1 group-title="Arabic",AR - الجزيرة
        http://example.com/jazeera.ts
        #EXTINF:-1 group-title="UK",Sky Sports Main Event +1
        http://example.com/ssme1.ts
        #EXTINF:-1 group-title="UK",Sky Sport Main Event
        http://example.com/ssme.ts
        """

    static let guide = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="cnn.us"><display-name>CNN</display-name></channel>
          <channel id="ZDF.de"><display-name>ZDF</display-name></channel>
          <channel id="bein1"><display-name>beIN Sports 1 HD</display-name></channel>
          <channel id="bein2"><display-name>beIN Sports 2 HD</display-name></channel>
          <channel id="jazeera"><display-name>Al Jazeera</display-name></channel>
          <channel id="ssme"><display-name>Sky Sports Main Event</display-name></channel>
          <channel id="other"><display-name>Nobody Watches This</display-name></channel>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="cnn.us"><title>News</title></programme>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="ZDF.de"><title>heute</title></programme>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="bein1"><title>Match 1</title></programme>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="bein2"><title>Match 2</title></programme>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="jazeera"><title>Newshour</title></programme>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="ssme"><title>Live Football</title></programme>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="other"><title>Nothing</title></programme>
        </tv>
        """

    init() async throws {
        db = try AppDatabase.inMemory()
        try await db.save(Source(id: "src", name: "Test", kind: .m3u, url: "http://example.com/list.m3u"))
        let playlist = M3UParser.parse(Data(Self.playlist.utf8), sourceId: "src")
        try await db.replaceLive(sourceId: "src", categories: playlist.categories, channels: playlist.channels)
        guideFile = FileManager.default.temporaryDirectory.appendingPathComponent("tuner-test-\(UUID().uuidString).xml")
        try Data(Self.guide.utf8).write(to: guideFile)
        try await db.save(EPGFeed(id: "src#0", url: "http://epg", sourceId: "src", priority: 0))
    }

    /// Parses the guide with what the service wants (as `ingestXMLTV` does) and resolves keys.
    func ingest(_ service: GuideService) async throws {
        let wanted = try await service.wantedSet()
        let parsed = try GuideService.parse(fileAt: guideFile, feedId: "src#0", wanted: wanted, shift: 0,
                                            windowStart: .distantPast, windowEnd: .distantFuture)
        try await db.replaceGuide(feedId: "src#0", channels: parsed.channels, programmes: parsed.programmes, programCounts: parsed.counts)
        try await service.resolveEPGKeys()
    }

    func keys() async throws -> [String: String] {
        let channels = try await db.channels(scope: .all, includeHidden: true)
        return Dictionary(uniqueKeysWithValues: channels.map { ($0.name, $0.epgKey ?? "-") })
    }

    func programmeKeys() async throws -> Set<String> {
        try await db.writer.read { Set(try String.fetchAll($0, sql: "SELECT DISTINCT epgKey FROM program")) }
    }

    func autoMatchCount() async throws -> Int {
        try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM epgAutoMatch") ?? 0 }
    }

    @Test func offMatchesExactlyAsBefore() async throws {
        let service = GuideService(db: db)
        try await ingest(service)
        let keys = try await keys()
        #expect(keys["CNN HD"] == "src#0|cnn.us")
        #expect(keys["VIP DE: ZDF HD"] == "-")
        #expect(keys["beIN SPORTS 1 4K"] == "src#0|bein1")   // exact normalised name, as always
        #expect(keys["AR - الجزيرة"] == "-")
        #expect(keys["Sky Sport Main Event"] == "-")
        #expect(try await programmeKeys() == ["src#0|cnn.us", "src#0|bein1"])
        #expect(try await autoMatchCount() == 0)
        // Off, nothing about smart matching is asked of the library.
        #expect(try await service.wantedSet().fuzzy.isEmpty)
    }

    @Test func onAddsAutomaticMatchesAndOffRestoresTheExactOnes() async throws {
        let service = GuideService(db: db)
        try await ingest(service)
        let before = try await keys()
        let programmesBefore = try await programmeKeys()

        await service.setSmartMatching(true)
        try await ingest(service)
        let on = try await keys()
        #expect(on["CNN HD"] == "src#0|cnn.us")
        #expect(on["VIP DE: ZDF HD"] == "src#0|ZDF.de")
        #expect(on["beIN SPORTS 1 4K"] == "src#0|bein1")
        #expect(on["beIN SPORTS 3 4K"] == "-")                 // never beIN Sports 2
        #expect(on["AR - الجزيرة"] == "src#0|jazeera")
        #expect(on["Sky Sport Main Event"] == "src#0|ssme")
        #expect(on["Sky Sports Main Event +1"] == "-")         // never the non-+1 feed
        // Programmes are kept for the automatic matches, still not for unmatched guide channels.
        #expect(try await programmeKeys() == ["src#0|cnn.us", "src#0|bein1", "src#0|ZDF.de", "src#0|jazeera", "src#0|ssme"])
        // Only automatic matches are recorded; exact ones are not.
        #expect(try await autoMatchCount() == 3)
        let zdf = try #require(try await db.channels(scope: .all).first { $0.name == "VIP DE: ZDF HD" })
        #expect(try await db.guideAutoMatch(channelId: zdf.id) == "src#0|ZDF.de")
        let cnn = try #require(try await db.channels(scope: .all).first { $0.name == "CNN HD" })
        #expect(try await db.guideAutoMatch(channelId: cnn.id) == nil)

        // A refresh keeps automatic matches (and their programmes).
        try await ingest(service)
        #expect(try await keys() == on)
        #expect(try await programmeKeys().contains("src#0|ZDF.de"))

        // Off: straight back to the exact matches, and the table is empty.
        await service.setSmartMatching(false)
        #expect(try await keys() == before)
        #expect(try await autoMatchCount() == 0)
        try await ingest(service)
        #expect(try await keys() == before)
        #expect(try await programmeKeys() == programmesBefore)
    }

    @Test func overrideAlwaysWins() async throws {
        let service = GuideService(db: db)
        await service.setSmartMatching(true)
        let zdf = try #require(try await db.channels(scope: .all).first { $0.name == "VIP DE: ZDF HD" })
        try await db.setEPGOverride(channelId: zdf.id, xmltvId: "other")
        try await ingest(service)
        #expect(try await db.channel(id: zdf.id)?.epgKey == "src#0|other")
        #expect(try await db.guideAutoMatch(channelId: zdf.id) == nil)
        // An override to a guide channel that isn't there leaves the channel without a guide; no automatic stand-in.
        try await db.setEPGOverride(channelId: zdf.id, xmltvId: "missing")
        try await service.resolveEPGKeys()
        #expect(try await db.channel(id: zdf.id)?.epgKey == nil)
        #expect(try await db.guideAutoMatch(channelId: zdf.id) == nil)
    }

    @Test func leftoverMatchesAreDroppedWhenOff() async throws {
        let on = GuideService(db: db)
        await on.setSmartMatching(true)
        try await ingest(on)
        #expect(try await autoMatchCount() == 3)
        // A new service (next launch) with the feature off clears what an earlier run left behind.
        let off = GuideService(db: db)
        await off.setSmartMatching(false)
        #expect(try await autoMatchCount() == 0)
        #expect(try await keys()["VIP DE: ZDF HD"] == "-")
    }
}
