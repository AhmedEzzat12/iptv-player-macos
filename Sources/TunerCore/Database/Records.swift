import Foundation
import GRDB

// Codable records map 1:1 to their tables.
extension Source: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "source"
}

extension Source.Kind: DatabaseValueConvertible {}
extension CategoryKind: DatabaseValueConvertible {}
extension CatchupType: DatabaseValueConvertible {}
extension MediaKind: DatabaseValueConvertible {}
extension Recording.Status: DatabaseValueConvertible {}

extension EPGFeed: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "epgFeed"
}

extension WatchProgress: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "watchProgress"
}

extension Reminder: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "reminder"
}

extension Recording: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "recording"
}

extension CustomGroup: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "customGroup"
}

// Provider rows are decoded by hand: they are joined with preference tables and use
// epoch-second columns, and these paths are hot (tens of thousands of rows).

extension Category: FetchableRecord {
    public init(row: Row) {
        self.init(id: row["id"], sourceId: row["sourceId"], kind: row["kind"], name: row["name"], providerOrder: row["providerOrder"])
        isHidden = row["isHidden"] ?? false
        alias = row["alias"]
        sortIndex = row["sortIndex"]
        itemCount = row["itemCount"] ?? 0
    }
}

extension Channel: FetchableRecord {
    public init(row: Row) {
        self.init(
            id: row["id"],
            sourceId: row["sourceId"],
            categoryId: row["categoryId"],
            name: row["name"],
            number: row["number"],
            providerOrder: row["providerOrder"],
            logoURL: row["logoURL"],
            tvgId: row["tvgId"],
            streamURL: row["streamURL"],
            providerStreamId: row["providerStreamId"],
            catchupType: row["catchupType"],
            catchupSource: row["catchupSource"],
            catchupDays: row["catchupDays"],
            userAgent: row["userAgent"],
            referrer: row["referrer"],
            isAdult: row["isAdult"]
        )
        epgKey = row["epgKey"]
        isFavorite = row["isFavorite"] ?? false
        favoriteOrder = row["favoriteOrder"]
        isHidden = row["isHidden"] ?? false
        alias = row["alias"]
        epgIdOverride = row["epgIdOverride"]
    }
}

extension Movie: FetchableRecord {
    public init(row: Row) {
        self.init(id: row["id"], sourceId: row["sourceId"], categoryId: row["categoryId"], name: row["name"], providerId: row["providerId"], streamURL: row["streamURL"], providerOrder: row["providerOrder"])
        year = row["year"]
        posterURL = row["posterURL"]
        backdropURL = row["backdropURL"]
        containerExtension = row["containerExtension"]
        rating = row["rating"]
        plot = row["plot"]
        genre = row["genre"]
        cast = row["cast"]
        director = row["director"]
        releaseDate = row["releaseDate"]
        durationSeconds = row["durationSeconds"]
        addedAt = (row["addedAt"] as Double?).map { Date(timeIntervalSince1970: $0) }
        trailer = row["trailer"]
        tmdbId = row["tmdbId"]
    }
}

extension Series: FetchableRecord {
    public init(row: Row) {
        self.init(id: row["id"], sourceId: row["sourceId"], categoryId: row["categoryId"], name: row["name"], providerId: row["providerId"], streamURL: row["streamURL"], providerOrder: row["providerOrder"])
        year = row["year"]
        coverURL = row["coverURL"]
        backdropURL = row["backdropURL"]
        rating = row["rating"]
        plot = row["plot"]
        genre = row["genre"]
        cast = row["cast"]
        director = row["director"]
        releaseDate = row["releaseDate"]
        addedAt = (row["addedAt"] as Double?).map { Date(timeIntervalSince1970: $0) }
        lastModified = (row["lastModified"] as Double?).map { Date(timeIntervalSince1970: $0) }
        trailer = row["trailer"]
    }
}

extension Episode: FetchableRecord {
    public init(row: Row) {
        self.init(id: row["id"], seriesId: row["seriesId"], sourceId: row["sourceId"], season: row["season"], number: row["number"], title: row["title"], providerId: row["providerId"], streamURL: row["streamURL"])
        plot = row["plot"]
        imageURL = row["imageURL"]
        durationSeconds = row["durationSeconds"]
        containerExtension = row["containerExtension"]
        airDate = row["airDate"]
    }
}

extension Program: FetchableRecord {
    public init(row: Row) {
        self.init(
            id: row["id"],
            epgKey: row["epgKey"],
            start: Date(timeIntervalSince1970: TimeInterval(row["start"] as Int64)),
            end: Date(timeIntervalSince1970: TimeInterval(row["end"] as Int64)),
            title: row["title"],
            subtitle: row["subtitle"],
            summary: row["summary"],
            category: row["category"],
            iconURL: row["iconURL"],
            episode: row["episode"]
        )
    }
}

extension EPGChannel: FetchableRecord {
    public init(row: Row) {
        self.init(feedId: row["feedId"], xmltvId: row["xmltvId"], displayName: row["displayName"], iconURL: row["iconURL"])
        normalizedName = row["normalizedName"]
    }
}
