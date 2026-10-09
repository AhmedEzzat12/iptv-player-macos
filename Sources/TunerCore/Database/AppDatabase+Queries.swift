import Foundation
import GRDB

public enum ChannelScope: Hashable, Sendable {
    case all
    case favorites
    case recent
    case source(String)
    case category(String)
    case group(String)
}

public enum ChannelSort: String, Sendable, CaseIterable, Codable {
    case provider
    case name
    case number

    public var title: String {
        switch self {
        case .provider: "Provider order"
        case .name: "Name"
        case .number: "Channel number"
        }
    }
}

public enum VODSort: String, Sendable, CaseIterable, Codable {
    case added
    case name
    case year
    case rating
    case provider

    public var title: String {
        switch self {
        case .added: "Recently added"
        case .name: "Name"
        case .year: "Year"
        case .rating: "Rating"
        case .provider: "Provider order"
        }
    }
}

/// Read paths used by the UI.
extension AppDatabase {
    static let channelSelect = """
        SELECT c.*, p.isFavorite, p.favoriteOrder, p.isHidden, p.alias, p.epgIdOverride
        FROM channel c
        JOIN source s ON s.id = c.sourceId AND s.enabled = 1 AND s.includeLive = 1
        LEFT JOIN channelPref p ON p.channelId = c.id
        LEFT JOIN categoryPref cp ON cp.categoryId = c.categoryId
        """

    // MARK: Channels

    public func channels(scope: ChannelScope, search: String? = nil, sort: ChannelSort = .provider, includeHidden: Bool = false, limit: Int? = nil) async throws -> [Channel] {
        try await writer.read { db in
            var sql = Self.channelSelect
            var args: [any DatabaseValueConvertible] = []
            var conditions: [String] = []
            var order: String

            switch sort {
            case .provider: order = "s.sortIndex, c.sourceId, c.providerOrder"
            case .name: order = "COALESCE(p.alias, c.name) COLLATE NOCASE"
            case .number: order = "c.number IS NULL, c.number, c.providerOrder"
            }

            switch scope {
            case .all:
                break
            case .favorites:
                conditions.append("p.isFavorite = 1")
                order = "p.favoriteOrder IS NULL, p.favoriteOrder, COALESCE(p.alias, c.name) COLLATE NOCASE"
            case .recent:
                sql += " JOIN history h ON h.channelId = c.id"
                order = "h.watchedAt DESC"
            case .source(let id):
                conditions.append("c.sourceId = ?")
                args.append(id)
            case .category(let id):
                conditions.append("c.categoryId = ?")
                args.append(id)
            case .group(let id):
                sql += " JOIN customGroupMember m ON m.channelId = c.id AND m.groupId = ?"
                args.insert(id, at: 0)
                order = "m.sortIndex"
            }

            if !includeHidden {
                conditions.append("COALESCE(p.isHidden, 0) = 0 AND COALESCE(cp.isHidden, 0) = 0")
            }
            for word in Self.searchWords(search) {
                conditions.append("(c.name LIKE ? ESCAPE '\\' OR p.alias LIKE ? ESCAPE '\\')")
                let pattern = "%\(Self.escapeLike(word))%"
                args.append(pattern)
                args.append(pattern)
            }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " ORDER BY \(order)"
            if let limit { sql += " LIMIT \(limit)" } else if scope == .recent { sql += " LIMIT 50" }
            return try Channel.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    public func channel(id: String) async throws -> Channel? {
        try await writer.read { db in
            try Channel.fetchOne(db, sql: """
                SELECT c.*, p.isFavorite, p.favoriteOrder, p.isHidden, p.alias, p.epgIdOverride
                FROM channel c LEFT JOIN channelPref p ON p.channelId = c.id WHERE c.id = ?
                """, arguments: [id])
        }
    }

    public func channels(epgKeys: [String]) async throws -> [Channel] {
        guard !epgKeys.isEmpty else { return [] }
        return try await writer.read { db in
            var result: [Channel] = []
            for chunk in epgKeys.chunked(500) {
                let marks = databaseQuestionMarks(count: chunk.count)
                result += try Channel.fetchAll(db, sql: Self.channelSelect + " WHERE c.epgKey IN (\(marks)) AND COALESCE(p.isHidden, 0) = 0 AND COALESCE(cp.isHidden, 0) = 0", arguments: StatementArguments(chunk))
            }
            return result
        }
    }

    /// Other channels carrying the same programme (same EPG key, tvg-id or normalised name) — failover candidates.
    public func alternateChannels(for channel: Channel) async throws -> [Channel] {
        try await writer.read { db in
            let normalized = ChannelNameNormalizer.normalize(channel.name)
            var conditions = ["c.normalizedName = ?"]
            var args: [any DatabaseValueConvertible] = [channel.id, normalized]
            if let key = channel.epgKey { conditions.append("c.epgKey = ?"); args.append(key) }
            if let tvg = channel.tvgId?.nilIfEmpty { conditions.append("c.tvgId = ?"); args.append(tvg) }
            let sql = Self.channelSelect + " WHERE c.id <> ? AND (\(conditions.joined(separator: " OR "))) AND COALESCE(p.isHidden, 0) = 0 ORDER BY s.sortIndex, c.providerOrder LIMIT 20"
            return try Channel.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: Categories

    public func categories(kind: CategoryKind, sourceId: String? = nil, includeHidden: Bool = false) async throws -> [Category] {
        try await writer.read { db in
            let itemTable = kind == .live ? "channel" : (kind == .movie ? "movie" : "series")
            var sql = """
                SELECT cat.*, cp.isHidden, cp.alias, cp.sortIndex,
                    (SELECT COUNT(*) FROM \(itemTable) i WHERE i.categoryId = cat.id) AS itemCount
                FROM category cat
                JOIN source s ON s.id = cat.sourceId AND s.enabled = 1
                LEFT JOIN categoryPref cp ON cp.categoryId = cat.id
                WHERE cat.kind = ?
                """
            var args: [any DatabaseValueConvertible] = [kind]
            if let sourceId { sql += " AND cat.sourceId = ?"; args.append(sourceId) }
            if !includeHidden { sql += " AND COALESCE(cp.isHidden, 0) = 0" }
            sql += " ORDER BY s.sortIndex, s.createdAt, cp.sortIndex IS NULL, cp.sortIndex, cat.providerOrder"
            return try Category.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// One category by id, with the user's alias (detail pages show where a title sits in its playlist).
    public func category(id: String) async throws -> Category? {
        try await writer.read { db in
            try Category.fetchOne(db, sql: """
                SELECT cat.*, cp.isHidden, cp.alias, cp.sortIndex
                FROM category cat
                LEFT JOIN categoryPref cp ON cp.categoryId = cat.id
                WHERE cat.id = ?
                """, arguments: [id])
        }
    }

    /// How many of a source's channels have guide data (resolved EPG key).
    public func guideCoverage(sourceId: String) async throws -> (channels: Int, withGuide: Int) {
        try await writer.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, COUNT(epgKey) AS m FROM channel WHERE sourceId = ?", arguments: [sourceId])
            return (row?["n"] ?? 0, row?["m"] ?? 0)
        }
    }

    public func favoriteCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM channelPref p JOIN channel c ON c.id = p.channelId WHERE p.isFavorite = 1") ?? 0
        }
    }

    // MARK: Guide

    /// Programmes overlapping `[from, to)` grouped by EPG key, sorted by start, overlaps trimmed.
    public func programs(epgKeys: [String], from: Date, to: Date) async throws -> [String: [Program]] {
        guard !epgKeys.isEmpty else { return [:] }
        return try await writer.read { db in
            var map: [String: [Program]] = [:]
            let lo = Int64(from.timeIntervalSince1970)
            let hi = Int64(to.timeIntervalSince1970)
            for chunk in Array(Set(epgKeys)).chunked(400) {
                let marks = databaseQuestionMarks(count: chunk.count)
                var args = StatementArguments(chunk)
                args += [hi, lo]
                let rows = try Program.fetchAll(db, sql: "SELECT * FROM program WHERE epgKey IN (\(marks)) AND start < ? AND end > ? ORDER BY epgKey, start", arguments: args)
                for p in rows { map[p.epgKey, default: []].append(p) }
            }
            for (key, list) in map { map[key] = Self.trimOverlaps(list) }
            return map
        }
    }

    /// Clamps each programme's end to the next programme's start so cells never overlap.
    static func trimOverlaps(_ list: [Program]) -> [Program] {
        guard list.count > 1 else { return list }
        var out: [Program] = []
        out.reserveCapacity(list.count)
        for p in list {
            if var last = out.last {
                if p.start <= last.start { continue } // duplicate start: keep the first
                if last.end > p.start {
                    last.end = p.start
                    out[out.count - 1] = last
                }
            }
            out.append(p)
        }
        return out
    }

    public func searchPrograms(_ query: String, from: Date = Date(), hours: Double = 72, limit: Int = 200) async throws -> [Program] {
        let words = Self.searchWords(query)
        guard !words.isEmpty else { return [] }
        return try await writer.read { db in
            var sql = "SELECT * FROM program WHERE end > ? AND start < ?"
            var args: [any DatabaseValueConvertible] = [Int64(from.timeIntervalSince1970), Int64(from.addingTimeInterval(hours * 3600).timeIntervalSince1970)]
            for word in words {
                sql += " AND (title LIKE ? ESCAPE '\\' OR subtitle LIKE ? ESCAPE '\\')"
                let pattern = "%\(Self.escapeLike(word))%"
                args += [pattern, pattern]
            }
            sql += " AND epgKey IN (SELECT epgKey FROM channel WHERE epgKey IS NOT NULL) ORDER BY start LIMIT \(limit)"
            return try Program.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// The guide key smart guide matching picked for a channel (nil when its guide came from an exact match or none).
    public func guideAutoMatch(channelId: String) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT epgKey FROM epgAutoMatch WHERE channelId = ?", arguments: [channelId])
        }
    }

    func hasGuideAutoMatches() async throws -> Bool {
        try await writer.read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM epgAutoMatch)") ?? false }
    }

    public func epgChannels(matching query: String, limit: Int = 50) async throws -> [EPGChannel] {
        try await writer.read { db in
            let pattern = "%\(Self.escapeLike(query))%"
            return try EPGChannel.fetchAll(db, sql: "SELECT * FROM epgChannel WHERE (displayName LIKE ? ESCAPE '\\' OR xmltvId LIKE ? ESCAPE '\\') ORDER BY programCount > 0 DESC, displayName LIMIT \(limit)", arguments: [pattern, pattern])
        }
    }

    // MARK: VOD

    public func movies(categoryId: String? = nil, sourceId: String? = nil, search: String? = nil, sort: VODSort = .added, limit: Int = 200, offset: Int = 0) async throws -> [Movie] {
        try await writer.read { db in
            var sql = """
                SELECT m.* FROM movie m
                JOIN source s ON s.id = m.sourceId AND s.enabled = 1 AND s.includeVOD = 1
                LEFT JOIN categoryPref cp ON cp.categoryId = m.categoryId
                WHERE COALESCE(cp.isHidden, 0) = 0
                """
            var args: [any DatabaseValueConvertible] = []
            if let categoryId { sql += " AND m.categoryId = ?"; args.append(categoryId) }
            if let sourceId { sql += " AND m.sourceId = ?"; args.append(sourceId) }
            for word in Self.searchWords(search) {
                sql += " AND m.name LIKE ? ESCAPE '\\'"
                args.append("%\(Self.escapeLike(word))%")
            }
            sql += " ORDER BY " + Self.vodOrder(sort, alias: "m") + " LIMIT \(limit) OFFSET \(offset)"
            return try Movie.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    public func series(categoryId: String? = nil, sourceId: String? = nil, search: String? = nil, sort: VODSort = .added, limit: Int = 200, offset: Int = 0) async throws -> [Series] {
        try await writer.read { db in
            var sql = """
                SELECT m.* FROM series m
                JOIN source s ON s.id = m.sourceId AND s.enabled = 1 AND s.includeVOD = 1
                LEFT JOIN categoryPref cp ON cp.categoryId = m.categoryId
                WHERE COALESCE(cp.isHidden, 0) = 0
                """
            var args: [any DatabaseValueConvertible] = []
            if let categoryId { sql += " AND m.categoryId = ?"; args.append(categoryId) }
            if let sourceId { sql += " AND m.sourceId = ?"; args.append(sourceId) }
            for word in Self.searchWords(search) {
                sql += " AND m.name LIKE ? ESCAPE '\\'"
                args.append("%\(Self.escapeLike(word))%")
            }
            sql += " ORDER BY " + Self.vodOrder(sort, alias: "m") + " LIMIT \(limit) OFFSET \(offset)"
            return try Series.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    static func vodOrder(_ sort: VODSort, alias a: String) -> String {
        switch sort {
        case .added: "\(a).addedAt IS NULL, \(a).addedAt DESC, \(a).providerOrder"
        case .name: "\(a).name COLLATE NOCASE"
        case .year: "\(a).year IS NULL, \(a).year DESC, \(a).name COLLATE NOCASE"
        case .rating: "\(a).rating IS NULL, \(a).rating DESC, \(a).name COLLATE NOCASE"
        case .provider: "\(a).providerOrder"
        }
    }

    public func movie(id: String) async throws -> Movie? {
        try await writer.read { db in try Movie.fetchOne(db, sql: "SELECT * FROM movie WHERE id = ?", arguments: [id]) }
    }

    public func series(id: String) async throws -> Series? {
        try await writer.read { db in try Series.fetchOne(db, sql: "SELECT * FROM series WHERE id = ?", arguments: [id]) }
    }

    public func episodes(seriesId: String) async throws -> [Episode] {
        try await writer.read { db in
            try Episode.fetchAll(db, sql: "SELECT * FROM episode WHERE seriesId = ? ORDER BY season, number", arguments: [seriesId])
        }
    }

    public func episode(id: String) async throws -> Episode? {
        try await writer.read { db in try Episode.fetchOne(db, sql: "SELECT * FROM episode WHERE id = ?", arguments: [id]) }
    }

    // MARK: Observation

    /// Emits whenever a transaction commits changes to any of `tables`.
    public func changes(in tables: [String]) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observation = DatabaseRegionObservation(tracking: tables.map { Table($0) })
            let cancellable = observation.start(in: writer) { _ in
                continuation.finish() // errors end the stream
            } onChange: { _ in
                continuation.yield()
            }
            let box = CancellableBox(cancellable)
            continuation.onTermination = { _ in box.cancel() }
        }
    }

    public func observeSources() -> AsyncStream<[Source]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                try Source.order(Column("sortIndex"), Column("createdAt")).fetchAll(db)
            }
            let cancellable = observation.start(in: writer, scheduling: .async(onQueue: .main)) { _ in
                continuation.finish()
            } onChange: { sources in
                continuation.yield(sources)
            }
            let box = CancellableBox(cancellable)
            continuation.onTermination = { _ in box.cancel() }
        }
    }

    // MARK: Helpers

    static func searchWords(_ search: String?) -> [String] {
        (search ?? "").split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}

final class CancellableBox: @unchecked Sendable {
    private let cancellable: AnyDatabaseCancellable
    init(_ c: AnyDatabaseCancellable) { cancellable = c }
    func cancel() { cancellable.cancel() }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
