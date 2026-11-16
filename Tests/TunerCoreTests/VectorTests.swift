import Foundation
import Testing
@testable import TunerCore

/// Shared test vectors (`Tests/Vectors/**.json`): the same cases run here and in the Android app's Kotlin tests, so
/// both ports give the same answers. Expected values are produced by this Swift code, never written by hand:
/// `TUNER_VECTORS_REGENERATE=1 scripts/test.sh --filter VectorTests` fills cases whose `expected` is null
/// (`=all` recomputes every case). See `Tests/Vectors/README.md`.
@Suite("Shared vectors")
struct VectorTests {
    /// Found from this file's location (the package only bundles `Fixtures`), so regenerating writes in place.
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vectors", isDirectory: true)

    static let regenerate = ProcessInfo.processInfo.environment["TUNER_VECTORS_REGENERATE"]

    static var files: [URL] {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
    }

    @Test func vectorFilesExist() {
        #expect(!Self.files.isEmpty, "no vector files under \(Self.folder.path)")
    }

    @Test(arguments: VectorTests.files)
    func vectorFile(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        guard var file = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let function = file["function"] as? String,
              var cases = file["cases"] as? [[String: Any]] else {
            Issue.record("\(url.lastPathComponent): not a vector file")
            return
        }
        guard let run = Self.functions[function] else {
            Issue.record("\(url.lastPathComponent): no Swift function registered for \(function)")
            return
        }
        var changed = false
        for i in cases.indices {
            let name = cases[i]["name"] as? String ?? "#\(i)"
            let actual = try run(cases[i]["input"] ?? NSNull())
            let expected = cases[i]["expected"]
            let missing = expected == nil || expected is NSNull
            if Self.regenerate == "all" || (Self.regenerate != nil && missing) {
                if missing || !Self.same(expected!, actual) {
                    cases[i]["expected"] = actual
                    changed = true
                }
            } else if missing {
                Issue.record("\(url.lastPathComponent) / \(name): expected is null; run with TUNER_VECTORS_REGENERATE=1")
            } else if !Self.same(expected!, actual) {
                Issue.record("\(url.lastPathComponent) / \(name): expected \(expected!), got \(actual)")
            }
        }
        if changed {
            file["cases"] = cases
            file["swiftCommit"] = Self.headCommit()
            var out = try JSONSerialization.data(withJSONObject: file,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            out.append(0x0A)
            try out.write(to: url)
        }
    }

    // MARK: - Functions under test

    typealias Run = @Sendable (Any) throws -> Any

    static let functions: [String: Run] = [
        "StableID.hash": { StableID.hash(try string($0)) },
        "StableID.sanitize": { StableID.sanitize(try string($0)) },
        "StableID.slug": { StableID.slug(try string($0)) },
        "ChannelNameNormalizer.normalize": { ChannelNameNormalizer.normalize(try string($0)) },
        "EndOfMediaStall.hasEnded": { input in
            let o = try object(input)
            return EndOfMediaStall.hasEnded(position: o["position"] as? Double, duration: o["duration"] as? Double,
                                            stalledFor: o["stalledFor"] as? Double ?? 0)
        },
        "CatchupURLBuilder.m3u": { input in
            let o = try object(input)
            return CatchupURLBuilder.m3u(
                channelURL: try string(o["channelURL"] as Any),
                type: CatchupType(rawValue: try string(o["type"] as Any)) ?? .default,
                template: o["template"] as? String, tvgId: o["tvgId"] as? String,
                start: try date(o["start"]), end: try date(o["end"]), now: try date(o["now"]))
        },
        "M3UParser.parse": { input in
            let o = try object(input)
            let data: Data
            if let name = o["fixture"] as? String {
                data = try Data(contentsOf: folder.deletingLastPathComponent().appendingPathComponent("TunerCoreTests/Fixtures/\(name)"))
            } else {
                data = Data(try string(o["text"] as Any).utf8)
            }
            let p = M3UParser.parse(data, sourceId: o["sourceId"] as? String ?? "src")
            func opt(_ v: Any?) -> Any { v ?? NSNull() }
            return [
                "epgURLs": p.epgURLs,
                "categories": p.categories.map { ["id": $0.id, "name": $0.name] },
                "channels": p.channels.map { c -> [String: Any] in
                    ["id": c.id, "name": c.name, "categoryId": opt(c.categoryId), "tvgId": opt(c.tvgId), "number": opt(c.number),
                     "logoURL": opt(c.logoURL), "streamURL": c.streamURL, "providerStreamId": opt(c.providerStreamId),
                     "catchupType": opt(c.catchupType?.rawValue), "catchupSource": opt(c.catchupSource),
                     "catchupDays": opt(c.catchupDays), "userAgent": opt(c.userAgent), "referrer": opt(c.referrer),
                     "isAdult": c.isAdult]
                },
                "movieCategories": p.movieCategories.map { ["id": $0.id, "name": $0.name] },
                "movies": p.movies.map { m -> [String: Any] in
                    ["id": m.id, "name": m.name, "year": opt(m.year), "categoryId": opt(m.categoryId),
                     "containerExtension": opt(m.containerExtension), "posterURL": opt(m.posterURL)]
                },
                "seriesCategories": p.seriesCategories.map { ["id": $0.id, "name": $0.name] },
                "series": p.series.map { ["id": $0.id, "name": $0.name, "categoryId": opt($0.categoryId)] },
                "episodes": p.episodes.map { e -> [String: Any] in
                    ["id": e.id, "seriesId": e.seriesId, "season": e.season, "number": e.number, "title": e.title,
                     "containerExtension": opt(e.containerExtension)]
                },
            ]
        },
        "TitleParser.splitYear": { input in
            let r = TitleParser.splitYear(try string(input))
            return ["title": r.title, "year": r.year as Any? ?? NSNull()] as [String: Any]
        },
        "TitleParser.episodeInfo": { input in
            guard let r = TitleParser.episodeInfo(try string(input)) else { return ["found": false] }
            return ["found": true, "show": r.show, "season": r.season, "episode": r.episode, "title": r.title as Any? ?? NSNull()] as [String: Any]
        },
        "XMLTVDate.parse": { input in
            guard let d = XMLTVDate.parse(try string(input)) else { return ["valid": false] }
            return ["valid": true, "epoch": Int(d.timeIntervalSince1970)] as [String: Any]
        },
        "XMLTVDate.formatXMLTVNS": { input in
            ["result": XMLTVDate.formatXMLTVNS(try string(input)) as Any? ?? NSNull()] as [String: Any]
        },
        "XMLTVParser.parse": { input in
            var events: [[String: Any]] = []
            func opt(_ v: Any?) -> Any { v ?? NSNull() }
            try XMLTVParser.parse(Data(try string(input).utf8)) { event in
                switch event {
                case .channel(let c):
                    events.append(["channel": c.id, "displayNames": c.displayNames, "icon": opt(c.iconURL)])
                case .programme(let p):
                    events.append(["programme": p.channel, "start": Int(p.start.timeIntervalSince1970),
                                   "stop": Int(p.stop.timeIntervalSince1970), "title": p.title, "subtitle": opt(p.subtitle),
                                   "desc": opt(p.desc), "category": opt(p.category), "icon": opt(p.iconURL),
                                   "episode": opt(p.episode)])
                }
            }
            return events
        },
        "JSONObject.accessors": { input in
            // input: {"v": <raw JSON value>}; parsed the way the clients parse panel responses.
            let data = try JSONSerialization.data(withJSONObject: try object(input), options: [.fragmentsAllowed])
            let obj = try #require(JSONObject(try JSONSerialization.jsonObject(with: data)))
            return ["string": obj.string("v") as Any? ?? NSNull(), "int": obj.int("v") as Any? ?? NSNull(),
                    "double": obj.double("v").map { $0.isFinite ? $0 as Any : "\($0)" } ?? NSNull(),
                    "bool": obj.bool("v")] as [String: Any]
        },
        "LenientJSON.objects": { input in
            let data = try JSONSerialization.data(withJSONObject: ["v": input], options: [.fragmentsAllowed])
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return LenientJSON.objects(root?["v"]).map { $0.string("id") ?? "?" }
        },
        "CategoryClassifier.classify": { input in
            let f = CategoryClassifier.classify(try string(input))
            func opt(_ v: Any?) -> Any { v ?? NSNull() }
            return ["group": f.group.rawValue, "latinName": opt(f.latinName), "arabicName": opt(f.arabicName),
                    "yearLabel": opt(f.yearLabel), "latestYear": opt(f.latestYear),
                    "automatic": f.displayName(.automatic), "arabic": f.displayName(.arabic)] as [String: Any]
        },
        "SkipSegments.classify": { input in
            ["kind": SkipSegments.classify(chapterTitle: input as? String)?.rawValue as Any? ?? NSNull()] as [String: Any]
        },
        "SkipSegments.fromChapters": { input in
            let o = try object(input)
            let chapters = (o["chapters"] as? [[String: Any]] ?? []).map {
                ChapterMark(title: $0["title"] as? String, start: $0["start"] as? Double ?? 0, end: $0["end"] as? Double)
            }
            return SkipSegments.fromChapters(chapters, duration: o["duration"] as? Double).map(segmentJSON)
        },
        "SkipSegments.merge": { input in
            let o = try object(input)
            let candidates = try (o["candidates"] as? [[String: Any]] ?? []).map(segment)
            return SkipSegments.merge(candidates, duration: o["duration"] as? Double).map(segmentJSON)
        },
        "SkipTracker.run": { input in
            // {segments, steps: [{op: update|seek|undo, position, duration?, mode?, autoSkipCredits?, segment?}]}
            let o = try object(input)
            var tracker = SkipTracker(segments: try (o["segments"] as? [[String: Any]] ?? []).map(segment))
            var out: [Any] = []
            for step in o["steps"] as? [[String: Any]] ?? [] {
                let position = step["position"] as? Double ?? 0
                let duration = step["duration"] as? Double
                switch step["op"] as? String {
                case "seek": tracker.userSeeked(to: position, duration: duration); out.append("seek")
                case "undo":
                    tracker.undoAutoSkip(try segment(step["segment"] as? [String: Any] ?? [:])); out.append("undo")
                default:
                    let r = tracker.update(position: position, duration: duration,
                                           mode: SkipMode(rawValue: step["mode"] as? String ?? "button") ?? .button,
                                           autoSkipCredits: step["autoSkipCredits"] as? Bool ?? false)
                    var e: [String: Any] = ["prompt": NSNull(), "fresh": NSNull(), "autoSkip": NSNull()]
                    if let p = r.prompt { e["prompt"] = p.segment.kind.rawValue; e["fresh"] = p.isFresh }
                    if case .autoSkip(let seg) = r.action { e["autoSkip"] = seg.kind.rawValue }
                    out.append(e)
                }
            }
            return out
        },
        "XtreamClient.urls": { input in
            let o = try object(input)
            let client = XtreamClient(base: try string(o["base"] as Any), username: try string(o["username"] as Any),
                                      password: try string(o["password"] as Any))
            let id = try string(o["streamId"] as Any)
            let ext = o["ext"] as? String
            return [
                "live": client.liveURL(streamId: id, format: .ts),
                "liveM3U8": client.liveURL(streamId: id, format: .m3u8),
                "movie": client.movieURL(streamId: id, ext: ext),
                "episode": client.episodeURL(episodeId: id, ext: ext),
                "timeshift": client.timeshiftURL(streamId: id, start: try date(o["start"]),
                                                 durationMinutes: o["minutes"] as? Int ?? 0,
                                                 serverTimeOffset: o["serverTimeOffset"] as? Double ?? 0),
                "api": client.apiURL("get_live_streams"),
            ]
        },
    ]

    // MARK: - Helpers

    static func segment(_ o: [String: Any]) throws -> SkipSegment {
        guard let kind = SkipSegment.Kind(rawValue: o["kind"] as? String ?? ""),
              let source = SkipSegment.Source(rawValue: o["source"] as? String ?? "") else {
            throw BadInput(description: "bad segment \(o)")
        }
        return SkipSegment(kind: kind, start: o["start"] as? Double ?? 0, end: o["end"] as? Double, source: source,
                           mayAutoSkip: o["mayAutoSkip"] as? Bool ?? true)
    }

    static func segmentJSON(_ s: SkipSegment) -> [String: Any] {
        ["kind": s.kind.rawValue, "start": s.start, "end": s.end as Any? ?? NSNull(), "source": s.source.rawValue,
         "mayAutoSkip": s.mayAutoSkip]
    }

    struct BadInput: Error, CustomStringConvertible { let description: String }

    static func string(_ any: Any) throws -> String {
        guard let s = any as? String else { throw BadInput(description: "expected a string, got \(any)") }
        return s
    }

    static func object(_ any: Any) throws -> [String: Any] {
        guard let o = any as? [String: Any] else { throw BadInput(description: "expected an object, got \(any)") }
        return o
    }

    static func date(_ any: Any?) throws -> Date {
        guard let s = any as? String, let d = ISO8601DateFormatter().date(from: s) else {
            throw BadInput(description: "expected an ISO-8601 date, got \(String(describing: any))")
        }
        return d
    }

    /// JSON equality (numbers compared as numbers, so 1 == 1.0).
    static func same(_ a: Any, _ b: Any) -> Bool {
        let wrap = { (v: Any) -> Data? in
            try? JSONSerialization.data(withJSONObject: ["v": v], options: [.sortedKeys, .fragmentsAllowed])
        }
        return wrap(a) == wrap(b) && wrap(a) != nil
    }

    static func headCommit() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", folder.path, "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out?.isEmpty == false ? out : nil
    }
}
