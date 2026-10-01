import Foundation
import GRDB

/// Provider-data writes performed by sync. Each replaces a source's rows atomically;
/// user state lives in `channelPref`/`categoryPref`/`watchProgress`, so it is untouched.
extension AppDatabase {
    // MARK: Sources

    public func sources() async throws -> [Source] {
        try await writer.read { db in try Source.order(Column("sortIndex"), Column("createdAt")).fetchAll(db) }
    }

    public func source(id: String) async throws -> Source? {
        try await writer.read { db in try Source.fetchOne(db, key: id) }
    }

    public func save(_ source: Source) async throws {
        try await writer.write { db in try source.save(db) }
    }

    public func deleteSource(id: String) async throws {
        try await writer.write { db in
            _ = try Source.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM channelPref WHERE channelId LIKE ? ESCAPE '\\'", arguments: [Self.likePrefix(id)])
            try db.execute(sql: "DELETE FROM categoryPref WHERE categoryId LIKE ? ESCAPE '\\'", arguments: [Self.likePrefix(id)])
            try db.execute(sql: "DELETE FROM watchProgress WHERE sourceId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM history WHERE channelId LIKE ? ESCAPE '\\'", arguments: [Self.likePrefix(id)])
        }
    }

    static func likePrefix(_ id: String) -> String {
        id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "\\_%"
    }

    /// Updates sync status fields without clobbering configuration edits made meanwhile.
    public func updateSyncStatus(sourceId: String, _ update: @escaping @Sendable (inout Source) -> Void) async throws {
        try await writer.write { db in
            guard var s = try Source.fetchOne(db, key: sourceId) else { return }
            update(&s)
            try s.update(db)
        }
    }

    // MARK: Live

    public func replaceLive(sourceId: String, categories: [Category], channels: [Channel]) async throws {
        try await writer.write { db in
            // Keep resolved guide keys so the guide doesn't blank out until the next EPG pass.
            var oldKeys: [String: String] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT id, epgKey FROM channel WHERE sourceId = ? AND epgKey IS NOT NULL", arguments: [sourceId])
            while let row = try rows.next() { oldKeys[row["id"]] = row["epgKey"] }

            try db.execute(sql: "DELETE FROM channel WHERE sourceId = ?", arguments: [sourceId])
            try db.execute(sql: "DELETE FROM category WHERE sourceId = ? AND kind = 'live'", arguments: [sourceId])

            let catStmt = try db.makeStatement(sql: "INSERT OR REPLACE INTO category (id, sourceId, kind, name, providerOrder) VALUES (?, ?, ?, ?, ?)")
            for c in categories {
                try catStmt.execute(arguments: [c.id, c.sourceId, c.kind, c.name, c.providerOrder])
            }

            let chStmt = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO channel (id, sourceId, categoryId, name, normalizedName, number, providerOrder, logoURL, tvgId,
                    streamURL, providerStreamId, catchupType, catchupSource, catchupDays, userAgent, referrer, isAdult, epgKey)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for ch in channels {
                try chStmt.execute(arguments: [
                    ch.id, ch.sourceId, ch.categoryId, ch.name, ChannelNameNormalizer.normalize(ch.name), ch.number, ch.providerOrder,
                    ch.logoURL, ch.tvgId, ch.streamURL, ch.providerStreamId, ch.catchupType, ch.catchupSource, ch.catchupDays,
                    ch.userAgent, ch.referrer, ch.isAdult, oldKeys[ch.id],
                ])
            }
        }
    }

    // MARK: VOD

    public func replaceVOD(sourceId: String, movieCategories: [Category], movies: [Movie], seriesCategories: [Category], series: [Series]) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM movie WHERE sourceId = ?", arguments: [sourceId])
            try db.execute(sql: "DELETE FROM series WHERE sourceId = ?", arguments: [sourceId])
            try db.execute(sql: "DELETE FROM category WHERE sourceId = ? AND kind IN ('movie', 'series')", arguments: [sourceId])
            try Self.insertCategories(db, movieCategories + seriesCategories)
            try Self.insertMovies(db, movies)
            try Self.insertSeries(db, series)
        }
    }

    /// Replaces only a source's movies (and movie categories).
    public func replaceMovies(sourceId: String, categories: [Category], movies: [Movie]) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM movie WHERE sourceId = ?", arguments: [sourceId])
            try db.execute(sql: "DELETE FROM category WHERE sourceId = ? AND kind = 'movie'", arguments: [sourceId])
            try Self.insertCategories(db, categories)
            try Self.insertMovies(db, movies)
        }
    }

    /// Replaces only a source's series (and series categories).
    public func replaceSeries(sourceId: String, categories: [Category], series: [Series]) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM series WHERE sourceId = ?", arguments: [sourceId])
            try db.execute(sql: "DELETE FROM category WHERE sourceId = ? AND kind = 'series'", arguments: [sourceId])
            try Self.insertCategories(db, categories)
            try Self.insertSeries(db, series)
        }
    }

    /// Adds items for one lazily-loaded category (Stalker) without touching other categories.
    public func replaceVODCategoryItems(categoryId: String, movies: [Movie], series: [Series]) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM movie WHERE categoryId = ?", arguments: [categoryId])
            try db.execute(sql: "DELETE FROM series WHERE categoryId = ?", arguments: [categoryId])
            try Self.insertMovies(db, movies)
            try Self.insertSeries(db, series)
        }
    }

    public func replaceEpisodes(seriesId: String, episodes: [Episode]) async throws {
        guard !episodes.isEmpty else { return } // never wipe on an empty/failed response
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM episode WHERE seriesId = ?", arguments: [seriesId])
            let stmt = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO episode (id, seriesId, sourceId, season, number, title, plot, imageURL, durationSeconds,
                    providerId, containerExtension, streamURL, airDate) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for e in episodes {
                try stmt.execute(arguments: [e.id, e.seriesId, e.sourceId, e.season, e.number, e.title, e.plot, e.imageURL,
                                             e.durationSeconds, e.providerId, e.containerExtension, e.streamURL, e.airDate])
            }
        }
    }

    /// Persists lazily fetched details (plot, cast…) so the detail view is instant next time.
    public func updateMovieDetails(id: String, _ d: VODDetails) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE movie SET plot = COALESCE(?, plot), "cast" = COALESCE(?, "cast"), director = COALESCE(?, director),
                    genre = COALESCE(?, genre), releaseDate = COALESCE(?, releaseDate), rating = COALESCE(?, rating),
                    durationSeconds = COALESCE(?, durationSeconds), backdropURL = COALESCE(?, backdropURL),
                    trailer = COALESCE(?, trailer), containerExtension = COALESCE(?, containerExtension), tmdbId = COALESCE(?, tmdbId)
                WHERE id = ?
                """, arguments: [d.plot, d.cast, d.director, d.genre, d.releaseDate, d.rating, d.durationSeconds, d.backdropURL,
                                 d.trailer, d.containerExtension, d.tmdbId, id])
        }
    }

    public func updateSeriesDetails(id: String, _ d: VODDetails) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE series SET plot = COALESCE(?, plot), "cast" = COALESCE(?, "cast"), director = COALESCE(?, director),
                    genre = COALESCE(?, genre), releaseDate = COALESCE(?, releaseDate), rating = COALESCE(?, rating),
                    backdropURL = COALESCE(?, backdropURL), trailer = COALESCE(?, trailer)
                WHERE id = ?
                """, arguments: [d.plot, d.cast, d.director, d.genre, d.releaseDate, d.rating, d.backdropURL, d.trailer, id])
        }
    }

    static func insertCategories(_ db: Database, _ categories: [Category]) throws {
        let stmt = try db.makeStatement(sql: "INSERT OR REPLACE INTO category (id, sourceId, kind, name, providerOrder) VALUES (?, ?, ?, ?, ?)")
        for c in categories { try stmt.execute(arguments: [c.id, c.sourceId, c.kind, c.name, c.providerOrder]) }
    }

    static func insertMovies(_ db: Database, _ movies: [Movie]) throws {
        let stmt = try db.makeStatement(sql: """
            INSERT OR REPLACE INTO movie (id, sourceId, categoryId, name, year, posterURL, backdropURL, providerId, containerExtension,
                streamURL, rating, plot, genre, "cast", director, releaseDate, durationSeconds, addedAt, providerOrder, trailer, tmdbId)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        for m in movies {
            try stmt.execute(arguments: [
                m.id, m.sourceId, m.categoryId, m.name, m.year, m.posterURL, m.backdropURL, m.providerId, m.containerExtension,
                m.streamURL, m.rating, m.plot, m.genre, m.cast, m.director, m.releaseDate, m.durationSeconds,
                m.addedAt?.timeIntervalSince1970, m.providerOrder, m.trailer, m.tmdbId,
            ])
        }
    }

    static func insertSeries(_ db: Database, _ series: [Series]) throws {
        let stmt = try db.makeStatement(sql: """
            INSERT OR REPLACE INTO series (id, sourceId, categoryId, name, year, coverURL, backdropURL, providerId, rating, plot,
                genre, "cast", director, releaseDate, addedAt, lastModified, providerOrder, trailer, streamURL)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        for s in series {
            try stmt.execute(arguments: [
                s.id, s.sourceId, s.categoryId, s.name, s.year, s.coverURL, s.backdropURL, s.providerId, s.rating, s.plot,
                s.genre, s.cast, s.director, s.releaseDate, s.addedAt?.timeIntervalSince1970, s.lastModified?.timeIntervalSince1970,
                s.providerOrder, s.trailer, s.streamURL,
            ])
        }
    }

    // MARK: Guide

    public func epgFeeds() async throws -> [EPGFeed] {
        try await writer.read { db in try EPGFeed.order(Column("priority")).fetchAll(db) }
    }

    public func save(_ feed: EPGFeed) async throws {
        try await writer.write { db in try feed.save(db) }
    }

    public func deleteFeed(id: String) async throws {
        try await writer.write { db in _ = try EPGFeed.deleteOne(db, key: id) }
    }

    /// Replaces a feed's guide data in one transaction.
    public func replaceGuide(feedId: String, channels: [EPGChannel], programmes: [Program], programCounts: [String: Int]) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM program WHERE feedId = ?", arguments: [feedId])
            try db.execute(sql: "DELETE FROM epgChannel WHERE feedId = ?", arguments: [feedId])
            let chStmt = try db.makeStatement(sql: "INSERT OR REPLACE INTO epgChannel (key, feedId, xmltvId, displayName, normalizedName, iconURL, programCount) VALUES (?, ?, ?, ?, ?, ?, ?)")
            for c in channels {
                try chStmt.execute(arguments: [c.key, c.feedId, c.xmltvId, c.displayName, c.normalizedName, c.iconURL, programCounts[c.key] ?? 0])
            }
            let pStmt = try db.makeStatement(sql: "INSERT INTO program (feedId, epgKey, start, end, title, subtitle, summary, category, iconURL, episode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            for p in programmes {
                try pStmt.execute(arguments: [feedId, p.epgKey, Int64(p.start.timeIntervalSince1970), Int64(p.end.timeIntervalSince1970),
                                              p.title, p.subtitle, p.summary, p.category, p.iconURL, p.episode])
            }
            try db.execute(sql: "UPDATE epgFeed SET channelCount = ?, programCount = ?, lastFetchedAt = ?, lastError = NULL WHERE id = ?",
                           arguments: [channels.count, programmes.count, Date(), feedId])
        }
    }

    /// Drops programmes that ended before `cutoff` (keeps the catchup window, bounds DB size).
    public func pruneProgrammes(endedBefore cutoff: Date) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM program WHERE end < ?", arguments: [Int64(cutoff.timeIntervalSince1970)])
        }
    }
}
