import Foundation
import Testing
@testable import TunerCore

func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

@Suite("M3U parser")
struct M3UParserTests {
    let playlist: M3UPlaylist

    init() throws {
        playlist = M3UParser.parse(try Data(contentsOf: fixture("sample.m3u")), sourceId: "src")
    }

    @Test func headerEPGURLsAreSplit() {
        #expect(playlist.epgURLs == ["http://epg.example.com/guide.xml.gz", "http://epg2.example.com/g.xml"])
    }

    @Test func liveChannelsAndAttributes() throws {
        #expect(playlist.channels.count == 5)
        let cnn = try #require(playlist.channels.first)
        #expect(cnn.name == "CNN HD")
        #expect(cnn.tvgId == "cnn.us")
        #expect(cnn.logoURL == "http://logos/cnn.png")
        #expect(cnn.id == "src_cnn.us")
        #expect(cnn.categoryId == "src_news")
        #expect(cnn.catchupType == .shift)
        #expect(cnn.catchupDays == 5)
    }

    @Test func commasInsideQuotesAndTitles() throws {
        let bbc = try #require(playlist.channels.first { $0.tvgId == "bbc1.uk" })
        #expect(bbc.name == "BBC One, London")
        #expect(bbc.number == 101)
        #expect(playlist.categories.contains { $0.name == "UK, Entertainment" })
    }

    @Test func vlcOptionsBecomeHeaders() throws {
        let bbc = try #require(playlist.channels.first { $0.tvgId == "bbc1.uk" })
        #expect(bbc.userAgent == "CustomAgent/1.0")
        #expect(bbc.referrer == "http://ref.example.com/")
        // options don't leak to the next entry
        let backup = try #require(playlist.channels.first { $0.name == "CNN Backup" })
        #expect(backup.userAgent == nil)
    }

    @Test func duplicateTvgIdGetsHashedId() throws {
        let backup = try #require(playlist.channels.first { $0.name == "CNN Backup" })
        #expect(backup.id.hasPrefix("src_cnn.us_"))
        #expect(backup.id != "src_cnn.us")
    }

    @Test func emptyUnquotedValueDoesNotSwallowNextKey() throws {
        let ch = try #require(playlist.channels.first { $0.name == "No Id Channel" })
        #expect(ch.tvgId == nil)
        #expect(ch.id.hasPrefix("src_url_"))
        #expect(ch.streamURL == "udp://239.0.0.1:1234")
        #expect(ch.categoryId == "src_misc") // from #EXTGRP
    }

    @Test func xtreamPanelLinksAreRecognised() throws {
        let ch = try #require(playlist.channels.first { $0.name == "Panel Channel" })
        #expect(ch.providerStreamId == "12345")
        #expect(ch.catchupType == .xtream)
    }

    @Test func vodEntriesAreRoutedToLibrary() throws {
        let movie = try #require(playlist.movies.first)
        #expect(movie.name == "The Matrix")
        #expect(movie.year == "1999")
        #expect(movie.containerExtension == "mkv")
        #expect(playlist.series.count == 1)
        #expect(playlist.series.first?.name == "Breaking Bad")
        #expect(playlist.episodes.count == 2)
        let ep = try #require(playlist.episodes.first { $0.number == 2 })
        #expect(ep.season == 1)
        #expect(ep.title == "Cat's in the Bag")
    }

    @Test func idsAreStableAcrossParses() throws {
        let again = M3UParser.parse(try Data(contentsOf: fixture("sample.m3u")), sourceId: "src")
        #expect(again.channels.map(\.id) == playlist.channels.map(\.id))
    }

    @Test func handlesCRLFAndBOM() {
        let text = "\u{FEFF}#EXTM3U\r\n#EXTINF:-1,Only\r\nhttp://x/1.ts\r\n"
        let p = M3UParser.parse(Data(text.utf8), sourceId: "s")
        #expect(p.channels.map(\.name) == ["Only"])
        #expect(p.channels.first?.streamURL == "http://x/1.ts")
    }
}

@Suite("XMLTV parser")
struct XMLTVParserTests {
    func events(_ data: Data) throws -> (channels: [XMLTVChannel], programmes: [XMLTVProgramme]) {
        var channels: [XMLTVChannel] = []
        var programmes: [XMLTVProgramme] = []
        try XMLTVParser.parse(data) { event in
            switch event {
            case .channel(let c): channels.append(c)
            case .programme(let p): programmes.append(p)
            }
        }
        return (channels, programmes)
    }

    @Test func parsesChannelsAndProgrammes() throws {
        let (channels, programmes) = try events(Data(contentsOf: fixture("sample.xml")))
        #expect(channels.map(\.id) == ["cnn.us", "BBC1.uk", "unused.channel"])
        #expect(channels[0].displayNames == ["CNN", "CNN International"])
        #expect(channels[0].iconURL == "http://logos/cnn-epg.png")
        #expect(programmes.count == 4)
        let first = programmes[0]
        #expect(first.title == "News & Views") // entity decoded, first title wins
        #expect(first.subtitle == "Midday")
        #expect(first.desc == "Top <stories> of the day") // CDATA
        #expect(first.category == "News")
        #expect(first.episode == "S02E05")
        #expect(first.iconURL == "http://img/p1.jpg")
    }

    @Test func timezoneOffsetsAreApplied() throws {
        let (_, programmes) = try events(Data(contentsOf: fixture("sample.xml")))
        let who = try #require(programmes.first { $0.title == "Doctor Who" })
        // 14:00 +0200 == 12:00 UTC
        #expect(who.start == XMLTVDate.parse("20260101120000 +0000"))
        #expect(who.desc == "Time & space ©")
    }

    @Test func dateWithoutSecondsOrOffset() throws {
        let d = try #require(XMLTVDate.parse("202601011300"))
        #expect(d.timeIntervalSince1970 == 1767272400)
        #expect(XMLTVDate.parse("20260101130000 -0130")?.timeIntervalSince1970 == 1_767_277_800)
        #expect(XMLTVDate.parse("garbage") == nil)
    }

    @Test func emptyGuideIsStillRecognised() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).xml")
        try Data(#"<?xml version="1.0" encoding="utf-8" ?><!DOCTYPE tv SYSTEM "xmltv.dtd"><tv generator-info-name="x"></tv>"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(XMLTVParser.looksLikeXMLTV(fileAt: url))
        let html = FileManager.default.temporaryDirectory.appendingPathComponent("page-\(UUID().uuidString).html")
        try Data("<html><body>Login</body></html>".utf8).write(to: html)
        defer { try? FileManager.default.removeItem(at: html) }
        #expect(!XMLTVParser.looksLikeXMLTV(fileAt: html))
    }

    @Test func gzipRejectsGarbage() {
        #expect(throws: GzipError.self) { try Gzip.decompress(Data([0x1F, 0x8B, 0x08, 0x00, 0x01, 0x02])) }
    }

    @Test func gzipSingleAndMultiMember() throws {
        let plain = try Data(contentsOf: fixture("sample.xml"))
        let single = try Gzip.decompress(Data(contentsOf: fixture("sample.xml.gz")))
        #expect(single == plain)
        let multi = try Gzip.decompress(Data(contentsOf: fixture("multi.xml.gz")))
        #expect(multi == plain + plain)
    }

    @Test func guideIngestFiltersToWantedChannels() throws {
        let wanted = GuideService.Wanted(tvgIds: ["cnn.us"], names: [ChannelNameNormalizer.normalize("BBC One HD")])
        let r = try GuideService.parse(fileAt: fixture("sample.xml"), feedId: "f", wanted: wanted, shift: 0,
                                       windowStart: .distantPast, windowEnd: .distantFuture)
        #expect(Set(r.programmes.map(\.epgKey)) == ["f|cnn.us", "f|BBC1.uk"])
        #expect(r.counts["f|cnn.us"] == 2)
        #expect(!r.programmes.contains { $0.title == "Filtered Out" })
    }

    @Test func guideIngestAppliesShift() throws {
        let r = try GuideService.parse(fileAt: fixture("sample.xml"), feedId: "f", wanted: nil, shift: 3600,
                                       windowStart: .distantPast, windowEnd: .distantFuture)
        let first = try #require(r.programmes.first)
        #expect(first.start == XMLTVDate.parse("20260101130000 +0000"))
    }
}

@Suite("Catchup URLs")
struct CatchupTests {
    let start = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01 12:00 UTC
    let end = Date(timeIntervalSince1970: 1_767_272_400)   // 13:00
    let now = Date(timeIntervalSince1970: 1_767_276_000)   // 14:00

    @Test func shiftAppendsUTC() {
        let url = CatchupURLBuilder.m3u(channelURL: "http://x/ch.m3u8?token=1", type: .shift, template: nil, tvgId: nil, start: start, end: end, now: now)
        #expect(url == "http://x/ch.m3u8?token=1&utc=1767268800&lutc=1767276000")
    }

    @Test func flussonicRewritesPath() {
        let url = CatchupURLBuilder.m3u(channelURL: "http://f/chan/index.m3u8?token=a", type: .flussonic, template: nil, tvgId: nil, start: start, end: end, now: now)
        #expect(url == "http://f/chan/index-1767268800-3600.m3u8?token=a")
        let ts = CatchupURLBuilder.m3u(channelURL: "http://f/chan/mpegts", type: .flussonic, template: nil, tvgId: nil, start: start, end: end, now: now)
        #expect(ts == "http://f/chan/timeshift_abs-1767268800.ts")
    }

    @Test func templateSubstitution() {
        let template = "http://arch/{catchup-id}/{Y}-{m}-{d}/{H}{M}?d={duration:60}&s=${start}&e={utcend}&o={offset}"
        let url = CatchupURLBuilder.m3u(channelURL: "http://live/x", type: .default, template: template, tvgId: "cnn.us", start: start, end: end, now: now)
        #expect(url == "http://arch/cnn.us/2026-01-01/1200?d=60&s=1767268800&e=1767272400&o=7200")
    }

    @Test func appendTemplateIsRelative() {
        let url = CatchupURLBuilder.m3u(channelURL: "http://live/x.ts", type: .append, template: "?utc={utc}&lutc={lutc}", tvgId: nil, start: start, end: end, now: now)
        #expect(url == "http://live/x.ts?utc=1767268800&lutc=1767276000")
    }

    @Test func xtreamTimeshiftUsesServerLocalTime() {
        let client = XtreamClient(base: "http://panel:8080/", username: "u s", password: "p&w")
        let url = client.timeshiftURL(streamId: "42", start: start, durationMinutes: 60, serverTimeOffset: 3600)
        #expect(url == "http://panel:8080/timeshift/u%20s/p&w/60/2026-01-01:13-00/42.ts")
    }

    @Test func xtreamPartsFromM3UURL() throws {
        let parts = try #require(StreamResolver.xtreamParts("http://panel.example.com:80/live/user/pass/12345.ts"))
        #expect(parts.base == "http://panel.example.com:80")
        #expect(parts.user == "user")
        #expect(parts.id == "12345")
        #expect(StreamResolver.xtreamParts("http://x/hls/stream.m3u8") == nil)
    }
}

@Suite("Identifiers and names")
struct IdentityTests {
    @Test func djb2IsDeterministic() {
        #expect(StableID.hash("http://example.com/a.ts") == StableID.hash("http://example.com/a.ts"))
        #expect(StableID.hash("a") != StableID.hash("b"))
        #expect(StableID.hash("").count <= 8)
    }

    @Test func slugKeepsUnicodeLetters() {
        #expect(StableID.slug("UK | Sports HD") == "uk-sports-hd")
        #expect(StableID.slug("Федеральные") == "федеральные")
        #expect(StableID.slug("!!!").hasPrefix("category-"))
    }

    @Test func normalizerStripsNoise() {
        #expect(ChannelNameNormalizer.normalize("US| CNN HD") == ChannelNameNormalizer.normalize("CNN"))
        #expect(ChannelNameNormalizer.normalize("[UK] BBC One FHD") == ChannelNameNormalizer.normalize("BBC One"))
        #expect(ChannelNameNormalizer.normalize("Sky Sports+ (1080p)") == "skysportsplus")
        #expect(!ChannelNameNormalizer.normalize("HD").isEmpty)
        #expect(ChannelNameNormalizer.normalize("HBO East") != ChannelNameNormalizer.normalize("HBO West"))
    }

    @Test func xtreamCredentialsFromPastedLink() throws {
        let c = try #require(XtreamClient.parseCredentials(from: "http://host.tv:8080/get.php?username=bob&password=s3cret&type=m3u_plus"))
        #expect(c.base == "http://host.tv:8080")
        #expect(c.username == "bob")
        #expect(c.password == "s3cret")
    }

    @Test func stalkerIdentityHashes() {
        let id = StalkerClient.Identity(mac: "00:1A:79:00:00:01")
        #expect(id.sn.count == 13)
        #expect(id.sn == id.sn.uppercased())
        #expect(id.deviceId.count == 64)
        #expect(id.hwVersion2.count == 40)
    }

    @Test func stalkerLocatorRoundTrip() {
        let loc = StalkerLocator.episode(cmd: "ffrt http://localhost/ch/1", series: 3)
        #expect(StalkerLocator.decode(loc.encoded) == loc)
        #expect(StalkerLocator.decode("http://not") == nil)
    }

    @Test func stalkerSanitizesLinks() {
        let c = StalkerClient(portalURL: "http://portal.tv:8080/c/", mac: "00:1A:79:00:00:01")
        #expect(c.sanitize("ffmpeg http://localhost/ch/123?x=1") == "http://portal.tv:8080/ch/123?x=1")
        #expect(c.sanitize("ffrt http://cdn.tv/live.ts") == "http://cdn.tv/live.ts")
        #expect(c.candidateEndpoints().first == "http://portal.tv:8080/portal.php")
    }

    @Test func titleParsing() {
        #expect(TitleParser.splitYear("Dune Part Two (2024)").title == "Dune Part Two")
        #expect(TitleParser.splitYear("Blade Runner 2049") == ("Blade Runner 2049", nil))
        #expect(TitleParser.splitYear("Sardar 2 ( 2026 )") == ("Sardar 2", "2026"))
        #expect(TitleParser.splitYear("المهايطية ( 2026 ) Pure") == ("المهايطية Pure", "2026"))
        #expect(TitleParser.splitYear("The Nice Ones [2026]") == ("The Nice Ones", "2026"))
        #expect(TitleParser.splitYear("Heat - 1995") == ("Heat", "1995"))
        let ep = TitleParser.episodeInfo("The Office (US) S03E10 A Benihana Christmas")
        #expect(ep?.show == "The Office (US)")
        #expect(ep?.season == 3)
        #expect(ep?.episode == 10)
    }
}

@Suite("HTTP robustness")
struct HTTPRobustnessTests {
    @Test func jsonWithPHPWarningPrefixIsRecovered() throws {
        let body = "<br />\n<b>Warning</b>: Undefined index in /var/www/player_api.php on line 12<br />\n[{\"category_id\":\"1\",\"category_name\":\"Movies\"}]\n"
        let value = try #require(HTTPClient.parseJSONLeniently(Data(body.utf8)) as? [[String: Any]])
        #expect(value.first?["category_name"] as? String == "Movies")
    }

    @Test func objectWithTrailingJunkIsRecovered() throws {
        let body = "{\"user_info\":{\"auth\":1}}<!-- served in 0.2s -->"
        let value = try #require(HTTPClient.parseJSONLeniently(Data(body.utf8)) as? [String: Any])
        #expect(value["user_info"] != nil)
    }

    @Test func htmlPageIsRejectedWithPreview() {
        let page = Data("<html><body>Too many requests</body></html>".utf8)
        #expect(HTTPClient.parseJSONLeniently(page) == nil)
        let message = HTTPError.invalidJSON(HTTPClient.preview(of: page)).localizedDescription
        #expect(message.contains("Too many requests"))
    }
}
