import Foundation
import GRDB

/// Downloads XMLTV/Stalker guide data and maps channels to guide keys.
public actor GuideService {
    let db: AppDatabase
    /// Programmes older than this are dropped (bounded by the longest catchup window people use).
    public var pastRetention: TimeInterval = 7 * 86400
    public var futureRetention: TimeInterval = 10 * 86400

    public init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Feeds

    /// Feed URLs for a source, in priority order: manual or discovered primary, then extras.
    nonisolated func feedURLs(for source: Source, discovered: [String]) -> [String] {
        var urls: [String] = []
        if let manual = source.epgURL?.nilIfEmpty {
            urls.append(manual)
        } else if source.autoLoadEPG {
            if let known = source.discoveredEPGURL?.nilIfEmpty { urls.append(known) }
            urls += discovered
        }
        urls += source.extraEPGURLs.compactMap(\.nilIfEmpty)
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Refreshes the guide for one source. Returns a user-facing error, or nil on success.
    @discardableResult
    public func refresh(source: Source, discovered: [String], stalker: StalkerClient? = nil) async -> String? {
        var errors: [String] = []
        var feeds: [EPGFeed] = []
        // Feeds we tried this pass; a failed one keeps its previous data instead of being deleted.
        var attempted = Set<String>()

        if source.kind == .stalker, source.autoLoadEPG, source.epgURL?.nilIfEmpty == nil, let stalker {
            let feed = EPGFeed(id: "\(source.id)#stalker", url: source.url, sourceId: source.id, priority: 0)
            attempted.insert(feed.id)
            do {
                try await db.save(feed)
                try await ingestStalker(feed: feed, client: stalker, shiftHours: source.epgTimeshiftHours)
                feeds.append(feed)
            } catch {
                errors.append("Portal guide: \(error.localizedDescription)")
            }
        }

        // The primary slot may have several candidate URLs (Xtream server_info variants):
        // the first that works wins and is remembered as `discoveredEPGURL`.
        let manualOrExtras = Set([source.epgURL].compactMap { $0 } + source.extraEPGURLs)
        var urls = feedURLs(for: source, discovered: discovered)
        var primaryCandidates: [String] = []
        if source.epgURL?.nilIfEmpty == nil {
            primaryCandidates = urls.filter { !manualOrExtras.contains($0) }
            urls = urls.filter { manualOrExtras.contains($0) }
        }

        var slot = 0
        if !primaryCandidates.isEmpty {
            let feed = EPGFeed(id: "\(source.id)#0", url: primaryCandidates[0], sourceId: source.id, priority: 0)
            attempted.insert(feed.id)
            var lastError: Error?
            var worked = false
            for candidate in primaryCandidates {
                var f = feed
                f.url = candidate
                do {
                    try await db.save(f)
                    try await ingestXMLTV(feed: f, userAgent: source.userAgent, shiftHours: source.epgTimeshiftHours)
                    feeds.append(f)
                    worked = true
                    if source.discoveredEPGURL != candidate {
                        try? await db.updateSyncStatus(sourceId: source.id) { $0.discoveredEPGURL = candidate }
                    }
                    break
                } catch {
                    lastError = error
                }
            }
            if !worked, let lastError { errors.append("Guide: \(lastError.localizedDescription)") }
            slot = 1
        }

        for (offset, url) in urls.enumerated() {
            let feed = EPGFeed(id: "\(source.id)#\(slot + offset)", url: url, sourceId: source.id, priority: slot + offset)
            attempted.insert(feed.id)
            do {
                try await db.save(feed)
                try await ingestXMLTV(feed: feed, userAgent: source.userAgent, shiftHours: source.epgTimeshiftHours)
                feeds.append(feed)
            } catch {
                errors.append("Guide \(URL(string: url)?.host ?? url): \(error.localizedDescription)")
                try? await db.writer.write { db in
                    try db.execute(sql: "UPDATE epgFeed SET lastError = ? WHERE id = ?", arguments: [error.localizedDescription, feed.id])
                }
            }
        }

        // Remove feeds this source no longer uses.
        for feed in (try? await db.epgFeeds()) ?? [] where feed.sourceId == source.id && !attempted.contains(feed.id) {
            try? await db.deleteFeed(id: feed.id)
        }

        try? await resolveEPGKeys()
        try? await db.pruneProgrammes(endedBefore: Date().addingTimeInterval(-pastRetention))
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// Refreshes user-added global feeds (feeds with no source).
    public func refreshGlobalFeeds() async -> String? {
        var errors: [String] = []
        for feed in (try? await db.epgFeeds()) ?? [] where feed.sourceId == nil {
            if let error = await ingestGlobalFeed(feed) { errors.append(error) }
        }
        try? await resolveEPGKeys()
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// Refreshes one global feed (e.g. right after the user adds it).
    public func refreshFeed(id: String) async -> String? {
        guard let feed = try? await db.epgFeeds().first(where: { $0.id == id }) else { return nil }
        let error = await ingestGlobalFeed(feed)
        try? await resolveEPGKeys()
        return error
    }

    /// Ingests a global feed and stores success/failure on the feed row so Settings can show it.
    private func ingestGlobalFeed(_ feed: EPGFeed) async -> String? {
        do {
            try await ingestXMLTV(feed: feed, userAgent: nil, shiftHours: 0)
            return nil
        } catch {
            let message = error.localizedDescription
            try? await db.writer.write { db in
                try db.execute(sql: "UPDATE epgFeed SET lastError = ?, lastFetchedAt = ? WHERE id = ?", arguments: [message, Date(), feed.id])
            }
            return "\(URL(string: feed.url)?.host ?? feed.url): \(message)"
        }
    }

    // MARK: - XMLTV ingest

    struct Wanted: Sendable {
        let tvgIds: Set<String>   // lowercased
        let names: Set<String>    // normalised channel names
    }

    func wantedSet() async throws -> Wanted {
        try await db.writer.read { db in
            var ids = Set<String>()
            var names = Set<String>()
            let rows = try Row.fetchCursor(db, sql: """
                SELECT c.tvgId, c.normalizedName, p.epgIdOverride FROM channel c LEFT JOIN channelPref p ON p.channelId = c.id
                """)
            while let row = try rows.next() {
                if let id = row["tvgId"] as String? { ids.insert(id.lowercased()) }
                if let o = row["epgIdOverride"] as String? { ids.insert(o.lowercased()) }
                names.insert(row["normalizedName"])
            }
            return Wanted(tvgIds: ids, names: names)
        }
    }

    public func ingestXMLTV(feed: EPGFeed, userAgent: String?, shiftHours: Double) async throws {
        let http = HTTPClient(userAgent: userAgent, timeout: 120)
        let downloaded = try await http.download(from: feed.url)
        defer { if downloaded.path.contains("tuner-") { try? FileManager.default.removeItem(at: downloaded) } }

        var xmlFile = downloaded
        var decompressed: URL?
        if Gzip.isGzipped(fileAt: downloaded) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("tuner-\(UUID().uuidString).xml")
            try Gzip.decompress(fileAt: downloaded, to: out)
            xmlFile = out
            decompressed = out
        }
        defer { if let decompressed { try? FileManager.default.removeItem(at: decompressed) } }

        let wanted = try await wantedSet()
        let result = try Self.parse(fileAt: xmlFile, feedId: feed.id, wanted: wanted, shift: shiftHours * 3600,
                                    windowStart: Date().addingTimeInterval(-pastRetention),
                                    windowEnd: Date().addingTimeInterval(futureRetention))
        // An empty `<tv></tv>` is a valid guide (the provider simply has no data) — not an error.
        guard result.sawGuide || XMLTVParser.looksLikeXMLTV(fileAt: xmlFile) else {
            throw HTTPError.authFailed("Not an XMLTV guide")
        }
        try await db.replaceGuide(feedId: feed.id, channels: result.channels, programmes: result.programmes, programCounts: result.counts)
    }

    struct ParseResult {
        var channels: [EPGChannel] = []
        var programmes: [Program] = []
        var counts: [String: Int] = [:]
        var sawGuide = false
    }

    /// Pure parse step (no I/O besides reading the file) — unit-testable.
    static func parse(fileAt url: URL, feedId: String, wanted: Wanted?, shift: TimeInterval, windowStart: Date, windowEnd: Date) throws -> ParseResult {
        var result = ParseResult()
        var channelsById: [String: EPGChannel] = [:]
        var wantedIds: Set<String>?   // computed at the first programme
        let filterActive = wanted.map { !$0.tvgIds.isEmpty || !$0.names.isEmpty } ?? false

        func computeWanted() -> Set<String> {
            guard let wanted else { return [] }
            var set = Set<String>()
            for (id, ch) in channelsById {
                if wanted.tvgIds.contains(id.lowercased()) || wanted.names.contains(ch.normalizedName) {
                    set.insert(id)
                }
            }
            return set
        }

        var allNames: [String: [String]] = [:]
        try XMLTVParser.parse(fileAt: url) { event in
            switch event {
            case .channel(let c):
                result.sawGuide = true
                let display = c.displayNames.first ?? c.id
                channelsById[c.id] = EPGChannel(feedId: feedId, xmltvId: c.id, displayName: display, iconURL: c.iconURL)
                allNames[c.id] = c.displayNames
            case .programme(let p):
                result.sawGuide = true
                if filterActive {
                    if wantedIds == nil {
                        // Also accept any of a channel's alternative display names.
                        var set = computeWanted()
                        if let wanted {
                            for (id, names) in allNames where !set.contains(id) {
                                if names.contains(where: { wanted.names.contains(ChannelNameNormalizer.normalize($0)) }) { set.insert(id) }
                            }
                        }
                        wantedIds = set
                    }
                    let known = channelsById[p.channel] != nil
                    let accepted = wantedIds!.contains(p.channel) || (!known && (wanted?.tvgIds.contains(p.channel.lowercased()) ?? false))
                    guard accepted else { return }
                }
                let start = p.start.addingTimeInterval(shift)
                let end = p.stop.addingTimeInterval(shift)
                guard end > windowStart, start < windowEnd else { return }
                let key = "\(feedId)|\(p.channel)"
                result.programmes.append(Program(epgKey: key, start: start, end: end, title: p.title.isEmpty ? "Untitled" : p.title,
                                                 subtitle: p.subtitle, summary: p.desc, category: p.category, iconURL: p.iconURL, episode: p.episode))
                result.counts[key, default: 0] += 1
                if channelsById[p.channel] == nil {
                    channelsById[p.channel] = EPGChannel(feedId: feedId, xmltvId: p.channel, displayName: p.channel, iconURL: nil)
                }
            }
        }
        result.channels = Array(channelsById.values)
        return result
    }

    // MARK: - Stalker

    func ingestStalker(feed: EPGFeed, client: StalkerClient, shiftHours: Double) async throws {
        let entries = try await client.epg(hours: 72)
        var channels: [String: EPGChannel] = [:]
        var programmes: [Program] = []
        var counts: [String: Int] = [:]
        let shift = shiftHours * 3600
        for e in entries {
            let key = "\(feed.id)|\(e.channelId)"
            if channels[e.channelId] == nil {
                channels[e.channelId] = EPGChannel(feedId: feed.id, xmltvId: e.channelId, displayName: e.channelId, iconURL: nil)
            }
            programmes.append(Program(epgKey: key, start: e.start.addingTimeInterval(shift), end: e.stop.addingTimeInterval(shift), title: e.title, summary: e.desc))
            counts[key, default: 0] += 1
        }
        try await db.replaceGuide(feedId: feed.id, channels: Array(channels.values), programmes: programmes, programCounts: counts)
    }

    // MARK: - Channel → guide key resolution

    /// Recomputes `channel.epgKey` for every channel:
    /// override → Stalker native → tvg-id → normalised name; preferring keys with programmes,
    /// then the channel's own source feeds, then global feeds, then other sources' feeds.
    public func resolveEPGKeys() async throws {
        try await db.writer.write { db in
            struct Candidate {
                let key: String
                let feedId: String
                let hasPrograms: Bool
            }
            var feedSource: [String: String?] = [:]
            var feedPriority: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, sourceId, priority FROM epgFeed") {
                feedSource[row["id"]] = row["sourceId"] as String?
                feedPriority[row["id"]] = row["priority"]
            }

            var byId: [String: [Candidate]] = [:]
            var byName: [String: [Candidate]] = [:]
            var stalkerKeys = Set<String>()
            let epgRows = try Row.fetchCursor(db, sql: "SELECT key, feedId, xmltvId, normalizedName, programCount FROM epgChannel")
            while let row = try epgRows.next() {
                let feedId: String = row["feedId"]
                let c = Candidate(key: row["key"], feedId: feedId, hasPrograms: (row["programCount"] as Int) > 0)
                byId[(row["xmltvId"] as String).lowercased(), default: []].append(c)
                let name: String = row["normalizedName"]
                if !name.isEmpty { byName[name, default: []].append(c) }
                if feedId.hasSuffix("#stalker") { stalkerKeys.insert(c.key) }
            }

            func rank(_ c: Candidate, sourceId: String) -> (Int, Int, Int) {
                let owner = feedSource[c.feedId] ?? nil
                let tier = owner == sourceId ? 0 : (owner == nil ? 1 : 2)
                return (c.hasPrograms ? 0 : 1, tier, feedPriority[c.feedId] ?? 99)
            }
            func best(_ list: [Candidate]?, sourceId: String) -> String? {
                guard let list, !list.isEmpty else { return nil }
                return list.min { rank($0, sourceId: sourceId) < rank($1, sourceId: sourceId) }?.key
            }

            var updates: [(String, String?)] = []
            let rows = try Row.fetchCursor(db, sql: """
                SELECT c.id, c.sourceId, c.tvgId, c.normalizedName, c.providerStreamId, c.epgKey, p.epgIdOverride
                FROM channel c LEFT JOIN channelPref p ON p.channelId = c.id
                """)
            while let row = try rows.next() {
                let sourceId: String = row["sourceId"]
                var key: String?
                if let override = row["epgIdOverride"] as String? {
                    key = best(byId[override.lowercased()], sourceId: sourceId)
                }
                if key == nil, let sid = row["providerStreamId"] as String? {
                    let stalkerKey = "\(sourceId)#stalker|\(sid)"
                    if stalkerKeys.contains(stalkerKey) { key = stalkerKey }
                }
                if key == nil, let tvg = (row["tvgId"] as String?)?.nilIfEmpty {
                    key = best(byId[tvg.lowercased()], sourceId: sourceId)
                }
                if key == nil {
                    key = best(byName[row["normalizedName"] as String], sourceId: sourceId)
                }
                if key != row["epgKey"] as String? { updates.append((row["id"], key)) }
            }
            let stmt = try db.makeStatement(sql: "UPDATE channel SET epgKey = ? WHERE id = ?")
            for (id, key) in updates { try stmt.execute(arguments: [key, id]) }
        }
    }
}
