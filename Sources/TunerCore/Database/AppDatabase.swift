import Foundation
import GRDB

/// SQLite storage for everything Tuner knows. Reads run concurrently (WAL); writes are serialised.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk database in `~/Library/Application Support/Tuner/tuner.sqlite`.
    public static func onDisk(directory: URL? = nil) throws -> AppDatabase {
        let fm = FileManager.default
        let dir = try directory ?? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Tuner", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA cache_size = -32000")
        }
        let path = dir.appendingPathComponent("tuner.sqlite").path
        let pool = try DatabasePool(path: path, configuration: config)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return try AppDatabase(pool)
    }

    /// In-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "source") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("url", .text).notNull()
                t.column("username", .text)
                t.column("password", .text)
                t.column("mac", .text)
                t.column("epgURL", .text)
                t.column("autoLoadEPG", .boolean).notNull().defaults(to: true)
                t.column("extraEPGURLs", .jsonText).notNull().defaults(to: "[]")
                t.column("epgTimeshiftHours", .double).notNull().defaults(to: 0)
                t.column("userAgent", .text)
                t.column("backupURLs", .jsonText).notNull().defaults(to: "[]")
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("includeLive", .boolean).notNull().defaults(to: true)
                t.column("includeVOD", .boolean).notNull().defaults(to: true)
                t.column("refreshHours", .integer)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("lastSyncedAt", .datetime)
                t.column("lastVODSyncedAt", .datetime)
                t.column("lastError", .text)
                t.column("expiresAt", .datetime)
                t.column("activeConnections", .integer)
                t.column("maxConnections", .integer)
                t.column("discoveredEPGURL", .text)
                t.column("channelCount", .integer).notNull().defaults(to: 0)
                t.column("movieCount", .integer).notNull().defaults(to: 0)
                t.column("seriesCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "category") { t in
                t.primaryKey("id", .text)
                t.column("sourceId", .text).notNull().references("source", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("providerOrder", .integer).notNull()
            }
            try db.create(index: "category_source_kind", on: "category", columns: ["sourceId", "kind"])

            try db.create(table: "categoryPref") { t in
                t.primaryKey("categoryId", .text)
                t.column("isHidden", .boolean).notNull().defaults(to: false)
                t.column("alias", .text)
                t.column("sortIndex", .integer)
            }

            try db.create(table: "channel") { t in
                t.primaryKey("id", .text)
                t.column("sourceId", .text).notNull().references("source", onDelete: .cascade)
                t.column("categoryId", .text)
                t.column("name", .text).notNull()
                t.column("normalizedName", .text).notNull()
                t.column("number", .integer)
                t.column("providerOrder", .integer).notNull()
                t.column("logoURL", .text)
                t.column("tvgId", .text)
                t.column("streamURL", .text).notNull()
                t.column("providerStreamId", .text)
                t.column("catchupType", .text)
                t.column("catchupSource", .text)
                t.column("catchupDays", .integer)
                t.column("userAgent", .text)
                t.column("referrer", .text)
                t.column("isAdult", .boolean).notNull().defaults(to: false)
                t.column("epgKey", .text)
            }
            try db.create(index: "channel_source", on: "channel", columns: ["sourceId", "providerOrder"])
            try db.create(index: "channel_category", on: "channel", columns: ["categoryId", "providerOrder"])
            try db.create(index: "channel_epgKey", on: "channel", columns: ["epgKey"])
            try db.create(index: "channel_normalized", on: "channel", columns: ["normalizedName"])
            try db.create(index: "channel_tvgId", on: "channel", columns: ["tvgId"])

            try db.create(table: "channelPref") { t in
                t.primaryKey("channelId", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("favoriteOrder", .integer)
                t.column("isHidden", .boolean).notNull().defaults(to: false)
                t.column("alias", .text)
                t.column("epgIdOverride", .text)
            }

            try db.create(table: "movie") { t in
                t.primaryKey("id", .text)
                t.column("sourceId", .text).notNull().references("source", onDelete: .cascade)
                t.column("categoryId", .text)
                t.column("name", .text).notNull()
                t.column("year", .text)
                t.column("posterURL", .text)
                t.column("backdropURL", .text)
                t.column("providerId", .text).notNull()
                t.column("containerExtension", .text)
                t.column("streamURL", .text).notNull()
                t.column("rating", .double)
                t.column("plot", .text)
                t.column("genre", .text)
                t.column("cast", .text)
                t.column("director", .text)
                t.column("releaseDate", .text)
                t.column("durationSeconds", .integer)
                t.column("addedAt", .double)
                t.column("providerOrder", .integer).notNull()
                t.column("trailer", .text)
                t.column("tmdbId", .text)
            }
            try db.create(index: "movie_category", on: "movie", columns: ["categoryId"])
            try db.create(index: "movie_source", on: "movie", columns: ["sourceId"])
            try db.create(index: "movie_added", on: "movie", columns: ["addedAt"])

            try db.create(table: "series") { t in
                t.primaryKey("id", .text)
                t.column("sourceId", .text).notNull().references("source", onDelete: .cascade)
                t.column("categoryId", .text)
                t.column("name", .text).notNull()
                t.column("year", .text)
                t.column("coverURL", .text)
                t.column("backdropURL", .text)
                t.column("providerId", .text).notNull()
                t.column("rating", .double)
                t.column("plot", .text)
                t.column("genre", .text)
                t.column("cast", .text)
                t.column("director", .text)
                t.column("releaseDate", .text)
                t.column("addedAt", .double)
                t.column("lastModified", .double)
                t.column("providerOrder", .integer).notNull()
                t.column("trailer", .text)
                t.column("streamURL", .text).notNull().defaults(to: "")
            }
            try db.create(index: "series_category", on: "series", columns: ["categoryId"])
            try db.create(index: "series_source", on: "series", columns: ["sourceId"])

            try db.create(table: "episode") { t in
                t.primaryKey("id", .text)
                t.column("seriesId", .text).notNull()
                t.column("sourceId", .text).notNull().references("source", onDelete: .cascade)
                t.column("season", .integer).notNull()
                t.column("number", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("plot", .text)
                t.column("imageURL", .text)
                t.column("durationSeconds", .integer)
                t.column("providerId", .text).notNull()
                t.column("containerExtension", .text)
                t.column("streamURL", .text).notNull()
                t.column("airDate", .text)
            }
            try db.create(index: "episode_series", on: "episode", columns: ["seriesId", "season", "number"])

            try db.create(table: "epgFeed") { t in
                t.primaryKey("id", .text)
                t.column("url", .text).notNull()
                t.column("sourceId", .text).references("source", onDelete: .cascade)
                t.column("priority", .integer).notNull()
                t.column("lastFetchedAt", .datetime)
                t.column("lastError", .text)
                t.column("channelCount", .integer).notNull().defaults(to: 0)
                t.column("programCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "epgChannel") { t in
                t.primaryKey("key", .text)
                t.column("feedId", .text).notNull().references("epgFeed", onDelete: .cascade)
                t.column("xmltvId", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("normalizedName", .text).notNull()
                t.column("iconURL", .text)
                t.column("programCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "epgChannel_feed", on: "epgChannel", columns: ["feedId"])
            try db.create(index: "epgChannel_normalized", on: "epgChannel", columns: ["normalizedName"])

            try db.create(table: "program") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("feedId", .text).notNull().references("epgFeed", onDelete: .cascade)
                t.column("epgKey", .text).notNull()
                t.column("start", .integer).notNull()
                t.column("end", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("summary", .text)
                t.column("category", .text)
                t.column("iconURL", .text)
                t.column("episode", .text)
            }
            try db.create(index: "program_key_start", on: "program", columns: ["epgKey", "start"])
            try db.create(index: "program_end", on: "program", columns: ["end"])
            try db.create(index: "program_feed", on: "program", columns: ["feedId"])

            try db.create(table: "watchProgress") { t in
                t.primaryKey("mediaId", .text)
                t.column("kind", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.column("seriesId", .text)
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("posterURL", .text)
                t.column("position", .double).notNull()
                t.column("duration", .double).notNull()
                t.column("completed", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "watchProgress_updated", on: "watchProgress", columns: ["updatedAt"])
            try db.create(index: "watchProgress_series", on: "watchProgress", columns: ["seriesId"])

            try db.create(table: "vodFavorite") { t in
                t.primaryKey("mediaId", .text)
                t.column("kind", .text).notNull()
                t.column("addedAt", .datetime).notNull()
            }

            try db.create(table: "history") { t in
                t.primaryKey("channelId", .text)
                t.column("watchedAt", .datetime).notNull()
            }

            try db.create(table: "customGroup") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sortIndex", .integer).notNull()
            }
            try db.create(table: "customGroupMember") { t in
                t.column("groupId", .text).notNull().references("customGroup", onDelete: .cascade)
                t.column("channelId", .text).notNull()
                t.column("sortIndex", .integer).notNull()
                t.primaryKey(["groupId", "channelId"])
            }

            try db.create(table: "reminder") { t in
                t.primaryKey("id", .text)
                t.column("channelId", .text).notNull()
                t.column("channelName", .text).notNull()
                t.column("programKey", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("start", .datetime).notNull()
                t.column("end", .datetime).notNull()
                t.column("autoSwitch", .boolean).notNull()
                t.column("notified", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "recording") { t in
                t.primaryKey("id", .text)
                t.column("channelId", .text).notNull()
                t.column("channelName", .text).notNull()
                t.column("title", .text).notNull()
                t.column("start", .datetime).notNull()
                t.column("end", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("filePath", .text)
                t.column("error", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }

        // Online metadata cache (Cinemeta/TMDB): one row per movie/series id, including "not found" results.
        m.registerMigration("v2") { db in
            try db.create(table: "mediaMetadata") { t in
                t.primaryKey("mediaId", .text)
                t.column("kind", .text).notNull()
                t.column("json", .text)
                t.column("notFound", .boolean).notNull().defaults(to: false)
                t.column("fetchedAt", .datetime).notNull()
            }
        }

        // Series lookups now add TVmaze episode pictures: refetch cached series matches (shown meanwhile) the
        // next time they're opened, instead of waiting out the 30-day cache.
        m.registerMigration("v3") { db in
            try db.execute(sql: "UPDATE mediaMetadata SET fetchedAt = ? WHERE kind = 'series' AND notFound = 0",
                           arguments: [Date(timeIntervalSince1970: 0)])
        }

        // IMDb episode ratings (from IMDb's datasets) per series IMDb id; `imdbRatingScan` also remembers series
        // that were scanned and have no rated episodes.
        m.registerMigration("v4") { db in
            try db.create(table: "imdbEpisodeRating") { t in
                t.column("seriesId", .text).notNull()
                t.column("season", .integer).notNull()
                t.column("episode", .integer).notNull()
                t.column("rating", .double).notNull()
                t.column("votes", .integer).notNull()
                t.primaryKey(["seriesId", "season", "episode"])
            }
            try db.create(table: "imdbRatingScan") { t in
                t.primaryKey("seriesId", .text)
                t.column("scannedAt", .datetime).notNull()
            }
        }

        // Downloads for offline viewing (`DownloadItem`), one row per movie/episode id. No stream URLs (Xtream URLs
        // carry the account's password; they're resolved when a transfer starts) and no foreign keys: a download
        // outlives a resync that drops the title or a removed playlist, and stays playable.
        m.registerMigration("v5") { db in
            try db.create(table: "download") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.column("seriesId", .text)
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("season", .integer)
                t.column("episode", .integer)
                t.column("artworkURL", .text)
                t.column("state", .text).notNull()
                t.column("receivedBytes", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer)
                t.column("filePath", .text)
                t.column("error", .text)
                t.column("pausedByUser", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // The queue (state = 'queued' ORDER BY createdAt), a show's downloads, and file-name collision checks.
            try db.create(index: "download_state_created", on: "download", columns: ["state", "createdAt"])
            try db.create(index: "download_series", on: "download", columns: ["seriesId"])
            try db.create(index: "download_filePath", on: "download", columns: ["filePath"])
        }

        // Smart guide matching (Settings › AI): the guide key picked by name for a channel with no exact match, and
        // its score. Rewritten by every key resolution, emptied while the feature is off. No foreign key: like
        // `channel.epgKey` it outlives a resync.
        m.registerMigration("v6-epgAutoMatch") { db in
            try db.create(table: "epgAutoMatch") { t in
                t.primaryKey("channelId", .text)
                t.column("epgKey", .text).notNull()
                t.column("score", .double).notNull()
            }
        }
        return m
    }
}
