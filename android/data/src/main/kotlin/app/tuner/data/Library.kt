// Android counterpart of AppDatabase+Library / +Queries / +User / +Metadata / +SkipSegments (Swift @ 666f598).
package app.tuner.data

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import app.tuner.core.metadata.MediaMetadata
import app.tuner.core.metadata.MetadataCache
import app.tuner.core.metadata.MetadataCacheEntry
import app.tuner.core.models.CatchupType
import app.tuner.core.models.Category
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Channel
import app.tuner.core.models.ContinueWatchingItem
import app.tuner.core.models.Episode
import app.tuner.core.models.MediaKind
import app.tuner.core.models.Movie
import app.tuner.core.models.Series
import app.tuner.core.models.SmartContinueWatching
import app.tuner.core.models.Source
import app.tuner.core.models.WatchProgress
import app.tuner.core.parsing.ChannelNameNormalizer
import app.tuner.core.skip.SkipSegment
import app.tuner.core.skip.SkipSegmentCache
import app.tuner.core.skip.SkipSegmentCacheEntry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.time.Instant

public enum class VODSort { ADDED, NAME, RATING }

public class Library(private val database: AppDatabase) : MetadataCache {
    private val json = Json { ignoreUnknownKeys = true }

    private suspend fun <T> read(block: (SQLiteDatabase) -> T): T = withContext(Dispatchers.IO) { block(database.readableDatabase) }

    private suspend fun <T> write(change: Change?, block: (SQLiteDatabase) -> T): T = withContext(Dispatchers.IO) {
        val db = database.writableDatabase
        db.beginTransaction()
        try {
            block(db).also { db.setTransactionSuccessful() }
        } finally {
            db.endTransaction()
            if (change != null) database.changed(change)
        }
    }

    // Sources (passwords encrypted at rest)

    public suspend fun sources(): List<Source> = read { db ->
        db.rawQuery("SELECT * FROM source ORDER BY sortIndex, createdAt", null).use { c -> c.map { source(it) } }
    }

    public suspend fun source(id: String): Source? = read { db ->
        db.rawQuery("SELECT * FROM source WHERE id = ?", arrayOf(id)).use { c -> if (c.moveToFirst()) source(c) else null }
    }

    public suspend fun save(source: Source): Unit = write(Change.LIBRARY) { db ->
        val v = ContentValues().apply {
            put("id", source.id); put("name", source.name); put("kind", source.kind.raw); put("url", source.url)
            put("username", source.username); put("password", source.password?.takeIf { it.isNotEmpty() }?.let { Secrets.encrypt(it) })
            put("mac", source.mac); put("epgURL", source.epgURL); put("autoLoadEPG", source.autoLoadEPG)
            put("extraEPGURLs", json.encodeToString(ListSerializer(String.serializer()), source.extraEPGURLs))
            put("epgTimeshiftHours", source.epgTimeshiftHours); put("userAgent", source.userAgent)
            put("backupURLs", json.encodeToString(ListSerializer(String.serializer()), source.backupURLs))
            put("enabled", source.enabled); put("includeLive", source.includeLive); put("includeVOD", source.includeVOD)
            put("refreshHours", source.refreshHours); put("sortIndex", source.sortIndex); put("createdAt", source.createdAt.toEpochMilli())
            put("lastSyncedAt", source.lastSyncedAt?.toEpochMilli()); put("lastVODSyncedAt", source.lastVODSyncedAt?.toEpochMilli())
            put("lastError", source.lastError); put("expiresAt", source.expiresAt?.toEpochMilli())
            put("activeConnections", source.activeConnections); put("maxConnections", source.maxConnections)
            put("discoveredEPGURL", source.discoveredEPGURL); put("channelCount", source.channelCount)
            put("movieCount", source.movieCount); put("seriesCount", source.seriesCount); put("needsPassword", source.needsPassword)
        }
        db.insertWithOnConflict("source", null, v, SQLiteDatabase.CONFLICT_REPLACE)
    }

    public suspend fun deleteSource(id: String): Unit = write(Change.LIBRARY) { db -> db.delete("source", "id = ?", arrayOf(id)) }

    /** Updates sync status fields without touching configuration edited meanwhile. */
    public suspend fun updateStatus(id: String, values: ContentValues): Unit = write(Change.LIBRARY) { db -> db.update("source", values, "id = ?", arrayOf(id)) }

    private fun source(c: Cursor): Source {
        val stored = c.str("password")
        val password = stored?.let { Secrets.decrypt(it) }
        return Source(
            id = c.str("id")!!, name = c.str("name")!!, kind = Source.Kind.of(c.str("kind")!!) ?: Source.Kind.M3U, url = c.str("url")!!,
            username = c.str("username"), password = password, mac = c.str("mac"), epgURL = c.str("epgURL"),
            autoLoadEPG = c.bool("autoLoadEPG"), extraEPGURLs = list(c.str("extraEPGURLs")), epgTimeshiftHours = c.double("epgTimeshiftHours") ?: 0.0,
            userAgent = c.str("userAgent"), backupURLs = list(c.str("backupURLs")), enabled = c.bool("enabled"),
            includeLive = c.bool("includeLive"), includeVOD = c.bool("includeVOD"), refreshHours = c.int("refreshHours"),
            sortIndex = c.int("sortIndex") ?: 0, createdAt = c.instant("createdAt") ?: Instant.now(),
            // A password that can't be decrypted here (restored from another device's backup) has to be entered again.
            needsPassword = c.bool("needsPassword") || (stored != null && password == null),
            lastSyncedAt = c.instant("lastSyncedAt"), lastVODSyncedAt = c.instant("lastVODSyncedAt"), lastError = c.str("lastError"),
            expiresAt = c.instant("expiresAt"), activeConnections = c.int("activeConnections"), maxConnections = c.int("maxConnections"),
            discoveredEPGURL = c.str("discoveredEPGURL"), channelCount = c.int("channelCount") ?: 0,
            movieCount = c.int("movieCount") ?: 0, seriesCount = c.int("seriesCount") ?: 0,
        )
    }

    private fun list(s: String?): List<String> = s?.let { runCatching { json.decodeFromString(ListSerializer(String.serializer()), it) }.getOrNull() } ?: emptyList()

    // Provider data: replaced per source in one transaction (user state lives elsewhere)

    public suspend fun replaceLive(sourceId: String, categories: List<Category>, channels: List<Channel>): Unit = write(Change.LIBRARY) { db ->
        val oldKeys = HashMap<String, String>()
        db.rawQuery("SELECT id, epgKey FROM channel WHERE sourceId = ? AND epgKey IS NOT NULL", arrayOf(sourceId)).use { c ->
            while (c.moveToNext()) oldKeys[c.getString(0)] = c.getString(1)
        }
        db.delete("channel", "sourceId = ?", arrayOf(sourceId))
        db.delete("category", "sourceId = ? AND kind = 'live'", arrayOf(sourceId))
        insertCategories(db, categories)
        val st = db.compileStatement("""INSERT OR REPLACE INTO channel (id, sourceId, categoryId, name, normalizedName, number, providerOrder,
            logoURL, tvgId, streamURL, providerStreamId, catchupType, catchupSource, catchupDays, userAgent, referrer, isAdult, epgKey)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""")
        for (ch in channels) {
            st.clearBindings()
            st.bindAll(ch.id, ch.sourceId, ch.categoryId, ch.name, ChannelNameNormalizer.normalize(ch.name), ch.number, ch.providerOrder,
                ch.logoURL, ch.tvgId, ch.streamURL, ch.providerStreamId, ch.catchupType?.raw, ch.catchupSource, ch.catchupDays,
                ch.userAgent, ch.referrer, ch.isAdult, oldKeys[ch.id])
            st.executeInsert()
        }
    }

    public suspend fun replaceMovies(sourceId: String, categories: List<Category>, movies: List<Movie>): Unit = write(Change.LIBRARY) { db ->
        db.delete("movie", "sourceId = ?", arrayOf(sourceId))
        db.delete("category", "sourceId = ? AND kind = 'movie'", arrayOf(sourceId))
        insertCategories(db, categories)
        insertMovies(db, movies)
    }

    public suspend fun replaceSeries(sourceId: String, categories: List<Category>, series: List<Series>): Unit = write(Change.LIBRARY) { db ->
        db.delete("series", "sourceId = ?", arrayOf(sourceId))
        db.delete("category", "sourceId = ? AND kind = 'series'", arrayOf(sourceId))
        insertCategories(db, categories)
        insertSeries(db, series)
    }

    /** Adds items of one lazily loaded (Stalker) category without touching others. */
    public suspend fun appendVOD(movies: List<Movie>, series: List<Series>): Unit = write(Change.LIBRARY) { db ->
        insertMovies(db, movies)
        insertSeries(db, series)
    }

    /** Episodes for many shows in one transaction. */
    public suspend fun replaceEpisodes(bySeries: Map<String, List<Episode>>): Unit = write(Change.LIBRARY) { db ->
        val st = db.compileStatement("""INSERT OR REPLACE INTO episode (id, seriesId, sourceId, season, number, title, plot, imageURL,
            durationSeconds, providerId, containerExtension, streamURL, airDate) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""")
        for ((seriesId, episodes) in bySeries) {
            db.delete("episode", "seriesId = ?", arrayOf(seriesId))
            for (e in episodes) {
                st.clearBindings()
                st.bindAll(e.id, e.seriesId, e.sourceId, e.season, e.number, e.title, e.plot, e.imageURL, e.durationSeconds, e.providerId,
                    e.containerExtension, e.streamURL, e.airDate)
                st.executeInsert()
            }
        }
    }

    private fun insertCategories(db: SQLiteDatabase, categories: List<Category>) {
        val st = db.compileStatement("INSERT OR REPLACE INTO category (id, sourceId, kind, name, providerOrder) VALUES (?,?,?,?,?)")
        for (c in categories) {
            st.clearBindings(); st.bindAll(c.id, c.sourceId, c.kind.raw, c.name, c.providerOrder); st.executeInsert()
        }
    }

    private fun insertMovies(db: SQLiteDatabase, movies: List<Movie>) {
        val st = db.compileStatement("""INSERT OR REPLACE INTO movie (id, sourceId, categoryId, name, year, posterURL, backdropURL, providerId,
            containerExtension, streamURL, rating, plot, genre, "cast", director, releaseDate, durationSeconds, addedAt, providerOrder, trailer, tmdbId)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""")
        for (m in movies) {
            st.clearBindings()
            st.bindAll(m.id, m.sourceId, m.categoryId, m.name, m.year, m.posterURL, m.backdropURL, m.providerId, m.containerExtension,
                m.streamURL, m.rating, m.plot, m.genre, m.cast, m.director, m.releaseDate, m.durationSeconds,
                m.addedAt?.let { it.toEpochMilli() / 1000.0 }, m.providerOrder, m.trailer, m.tmdbId)
            st.executeInsert()
        }
    }

    private fun insertSeries(db: SQLiteDatabase, series: List<Series>) {
        val st = db.compileStatement("""INSERT OR REPLACE INTO series (id, sourceId, categoryId, name, year, coverURL, backdropURL, providerId,
            rating, plot, genre, "cast", director, releaseDate, addedAt, lastModified, providerOrder, trailer, streamURL)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""")
        for (s in series) {
            st.clearBindings()
            st.bindAll(s.id, s.sourceId, s.categoryId, s.name, s.year, s.coverURL, s.backdropURL, s.providerId, s.rating, s.plot, s.genre,
                s.cast, s.director, s.releaseDate, s.addedAt?.let { it.toEpochMilli() / 1000.0 }, s.lastModified?.let { it.toEpochMilli() / 1000.0 },
                s.providerOrder, s.trailer, s.streamURL)
            st.executeInsert()
        }
    }

    // Reads

    public suspend fun categories(kind: CategoryKind): List<Category> = read { db ->
        val countSql = when (kind) {
            CategoryKind.LIVE -> "(SELECT COUNT(*) FROM channel x WHERE x.categoryId = c.id)"
            CategoryKind.MOVIE -> "(SELECT COUNT(*) FROM movie x WHERE x.categoryId = c.id)"
            CategoryKind.SERIES -> "(SELECT COUNT(*) FROM series x WHERE x.categoryId = c.id)"
        }
        db.rawQuery("""SELECT c.*, p.isHidden, p.alias, p.sortIndex AS prefSort, $countSql AS n FROM category c
            JOIN source s ON s.id = c.sourceId LEFT JOIN categoryPref p ON p.categoryId = c.id
            WHERE c.kind = ? AND COALESCE(p.isHidden, 0) = 0 ORDER BY s.sortIndex, p.sortIndex IS NULL, p.sortIndex, c.providerOrder""",
            arrayOf(kind.raw)).use { c ->
            c.map {
                Category(it.str("id")!!, it.str("sourceId")!!, kind, it.str("name")!!, it.int("providerOrder") ?: 0,
                    alias = it.str("alias"), sortIndex = it.int("prefSort"), itemCount = it.int("n") ?: 0)
            }.filter { it.itemCount > 0 || kind != CategoryKind.LIVE }
        }
    }

    public sealed class ChannelScope {
        public object All : ChannelScope()
        public object Favorites : ChannelScope()
        public object Recent : ChannelScope()
        public data class InCategory(val id: String) : ChannelScope()
    }

    public suspend fun channels(scope: ChannelScope, search: String? = null, limit: Int? = null): List<Channel> = read { db ->
        var sql = """SELECT c.*, p.isFavorite, p.favoriteOrder, p.isHidden, p.alias, p.epgIdOverride FROM channel c
            JOIN source s ON s.id = c.sourceId LEFT JOIN channelPref p ON p.channelId = c.id"""
        val args = mutableListOf<String>()
        val where = mutableListOf("COALESCE(p.isHidden, 0) = 0")
        var order = "s.sortIndex, c.sourceId, c.providerOrder"
        when (scope) {
            ChannelScope.All -> Unit
            ChannelScope.Favorites -> { where.add("p.isFavorite = 1"); order = "p.favoriteOrder IS NULL, p.favoriteOrder, c.name COLLATE NOCASE" }
            ChannelScope.Recent -> { sql += " JOIN history h ON h.channelId = c.id"; order = "h.watchedAt DESC" }
            is ChannelScope.InCategory -> { where.add("c.categoryId = ?"); args.add(scope.id) }
        }
        for (word in search?.trim()?.split(Regex("\\s+"))?.filter { it.isNotEmpty() } ?: emptyList()) {
            where.add("(c.name LIKE ? OR p.alias LIKE ?)"); args.add("%$word%"); args.add("%$word%")
        }
        sql += " WHERE " + where.joinToString(" AND ") + " ORDER BY $order"
        val cap = limit ?: if (scope == ChannelScope.Recent) 50 else null
        if (cap != null) sql += " LIMIT $cap"
        db.rawQuery(sql, args.toTypedArray()).use { c -> c.map { channel(it) } }
    }

    public suspend fun channel(id: String): Channel? = read { db ->
        db.rawQuery("""SELECT c.*, p.isFavorite, p.favoriteOrder, p.isHidden, p.alias, p.epgIdOverride FROM channel c
            LEFT JOIN channelPref p ON p.channelId = c.id WHERE c.id = ?""", arrayOf(id)).use { c -> if (c.moveToFirst()) channel(c) else null }
    }

    private fun channel(c: Cursor) = Channel(
        id = c.str("id")!!, sourceId = c.str("sourceId")!!, categoryId = c.str("categoryId"), name = c.str("name")!!, number = c.int("number"),
        providerOrder = c.int("providerOrder") ?: 0, logoURL = c.str("logoURL"), tvgId = c.str("tvgId"), streamURL = c.str("streamURL")!!,
        providerStreamId = c.str("providerStreamId"), catchupType = c.str("catchupType")?.let { CatchupType.of(it) },
        catchupSource = c.str("catchupSource"), catchupDays = c.int("catchupDays"), userAgent = c.str("userAgent"), referrer = c.str("referrer"),
        isAdult = c.bool("isAdult"), epgKey = c.str("epgKey"), isFavorite = c.bool("isFavorite"), favoriteOrder = c.int("favoriteOrder"),
        isHidden = c.bool("isHidden"), alias = c.str("alias"), epgIdOverride = c.str("epgIdOverride"),
    )

    private fun vodOrder(sort: VODSort) = when (sort) {
        VODSort.ADDED -> "addedAt IS NULL, addedAt DESC, providerOrder"
        VODSort.NAME -> "name COLLATE NOCASE"
        VODSort.RATING -> "rating IS NULL, rating DESC, name COLLATE NOCASE"
    }

    public suspend fun movies(categoryId: String? = null, search: String? = null, sort: VODSort = VODSort.ADDED, limit: Int = 200, offset: Int = 0): List<Movie> = read { db ->
        val (where, args) = vodWhere(categoryId, search)
        db.rawQuery("SELECT * FROM movie $where ORDER BY ${vodOrder(sort)} LIMIT $limit OFFSET $offset", args).use { c -> c.map { movie(it) } }
    }

    public suspend fun series(categoryId: String? = null, search: String? = null, sort: VODSort = VODSort.ADDED, limit: Int = 200, offset: Int = 0): List<Series> = read { db ->
        val (where, args) = vodWhere(categoryId, search)
        db.rawQuery("SELECT * FROM series $where ORDER BY ${vodOrder(sort)} LIMIT $limit OFFSET $offset", args).use { c -> c.map { series(it) } }
    }

    private fun vodWhere(categoryId: String?, search: String?): Pair<String, Array<String>> {
        val where = mutableListOf<String>()
        val args = mutableListOf<String>()
        if (categoryId != null) { where.add("categoryId = ?"); args.add(categoryId) }
        for (word in search?.trim()?.split(Regex("\\s+"))?.filter { it.isNotEmpty() } ?: emptyList()) { where.add("name LIKE ?"); args.add("%$word%") }
        return (if (where.isEmpty()) "" else "WHERE " + where.joinToString(" AND ")) to args.toTypedArray()
    }

    public suspend fun movie(id: String): Movie? = read { db -> db.rawQuery("SELECT * FROM movie WHERE id = ?", arrayOf(id)).use { c -> if (c.moveToFirst()) movie(c) else null } }

    public suspend fun seriesItem(id: String): Series? = read { db -> db.rawQuery("SELECT * FROM series WHERE id = ?", arrayOf(id)).use { c -> if (c.moveToFirst()) series(c) else null } }

    public suspend fun episodes(seriesId: String): List<Episode> = read { db ->
        db.rawQuery("SELECT * FROM episode WHERE seriesId = ? ORDER BY season, number", arrayOf(seriesId)).use { c -> c.map { episode(it) } }
    }

    private fun movie(c: Cursor) = Movie(
        id = c.str("id")!!, sourceId = c.str("sourceId")!!, categoryId = c.str("categoryId"), name = c.str("name")!!, providerId = c.str("providerId")!!,
        streamURL = c.str("streamURL")!!, providerOrder = c.int("providerOrder") ?: 0, year = c.str("year"), posterURL = c.str("posterURL"),
        backdropURL = c.str("backdropURL"), containerExtension = c.str("containerExtension"), rating = c.double("rating"), plot = c.str("plot"),
        genre = c.str("genre"), cast = c.str("cast"), director = c.str("director"), releaseDate = c.str("releaseDate"),
        durationSeconds = c.int("durationSeconds"), addedAt = c.double("addedAt")?.let { Instant.ofEpochMilli((it * 1000).toLong()) },
        trailer = c.str("trailer"), tmdbId = c.str("tmdbId"),
    )

    private fun series(c: Cursor) = Series(
        id = c.str("id")!!, sourceId = c.str("sourceId")!!, categoryId = c.str("categoryId"), name = c.str("name")!!, providerId = c.str("providerId")!!,
        streamURL = c.str("streamURL") ?: "", providerOrder = c.int("providerOrder") ?: 0, year = c.str("year"), coverURL = c.str("coverURL"),
        backdropURL = c.str("backdropURL"), rating = c.double("rating"), plot = c.str("plot"), genre = c.str("genre"), cast = c.str("cast"),
        director = c.str("director"), releaseDate = c.str("releaseDate"),
        addedAt = c.double("addedAt")?.let { Instant.ofEpochMilli((it * 1000).toLong()) }, trailer = c.str("trailer"),
    )

    private fun episode(c: Cursor) = Episode(
        id = c.str("id")!!, seriesId = c.str("seriesId")!!, sourceId = c.str("sourceId")!!, season = c.int("season") ?: 0, number = c.int("number") ?: 0,
        title = c.str("title")!!, providerId = c.str("providerId")!!, streamURL = c.str("streamURL")!!, plot = c.str("plot"), imageURL = c.str("imageURL"),
        durationSeconds = c.int("durationSeconds"), containerExtension = c.str("containerExtension"), airDate = c.str("airDate"),
    )

    // User state

    public suspend fun setFavorite(channelId: String, favorite: Boolean): Unit = write(Change.USER) { db ->
        db.execSQL("INSERT INTO channelPref (channelId, isFavorite) VALUES (?, ?) ON CONFLICT(channelId) DO UPDATE SET isFavorite = excluded.isFavorite",
            arrayOf<Any>(channelId, if (favorite) 1 else 0))
    }

    public suspend fun recordWatched(channelId: String): Unit = write(Change.USER) { db ->
        db.execSQL("INSERT OR REPLACE INTO history (channelId, watchedAt) VALUES (?, ?)", arrayOf<Any>(channelId, System.currentTimeMillis()))
    }

    public suspend fun progress(mediaId: String): WatchProgress? = read { db ->
        db.rawQuery("SELECT * FROM watchProgress WHERE mediaId = ?", arrayOf(mediaId)).use { c -> if (c.moveToFirst()) progress(c) else null }
    }

    public suspend fun progress(seriesId: String, forSeries: Boolean): Map<String, WatchProgress> = read { db ->
        db.rawQuery("SELECT * FROM watchProgress WHERE seriesId = ?", arrayOf(seriesId)).use { c -> c.map { progress(it) }.associateBy { it.mediaId } }
    }

    /** Saves a resume point; ignores zero-length media so a failed load can't wipe progress. */
    public suspend fun saveProgress(p: WatchProgress) {
        if (p.duration <= 0) return
        write(Change.USER) { db ->
            val v = ContentValues().apply {
                put("mediaId", p.mediaId); put("kind", p.kind.raw); put("sourceId", p.sourceId); put("seriesId", p.seriesId)
                put("title", p.title); put("subtitle", p.subtitle); put("posterURL", p.posterURL); put("position", p.position)
                put("duration", p.duration); put("completed", WatchProgress.isComplete(p.position, p.duration))
                put("updatedAt", p.updatedAt.toEpochMilli())
            }
            db.insertWithOnConflict("watchProgress", null, v, SQLiteDatabase.CONFLICT_REPLACE)
        }
    }

    private fun progress(c: Cursor) = WatchProgress(
        mediaId = c.str("mediaId")!!, kind = MediaKind.of(c.str("kind")!!) ?: MediaKind.MOVIE, sourceId = c.str("sourceId")!!, seriesId = c.str("seriesId"),
        title = c.str("title")!!, subtitle = c.str("subtitle"), posterURL = c.str("posterURL"), position = c.double("position") ?: 0.0,
        duration = c.double("duration") ?: 0.0, completed = c.bool("completed"), updatedAt = c.instant("updatedAt") ?: Instant.EPOCH,
    )

    /** Resume points plus the next cached episode of shows whose latest episode was finished (SmartContinueWatching). */
    public suspend fun continueWatching(limit: Int = 20): List<ContinueWatchingItem> {
        val records = read { db ->
            db.rawQuery("""SELECT * FROM watchProgress WHERE kind IN ('movie','episode') AND (seriesId IS NOT NULL OR (completed = 0 AND position > 10))
                ORDER BY updatedAt DESC LIMIT 500""", null).use { c -> c.map { progress(it) } }
        }
        val needed = SmartContinueWatching.showsNeedingEpisodes(records)
        val episodes = needed.associateWith { episodes(it) }
        return SmartContinueWatching.rank(records, episodes, Instant.now(), limit).map { entry ->
            when (entry) {
                is SmartContinueWatching.Entry.Resume -> ContinueWatchingItem.Resume(entry.progress)
                is SmartContinueWatching.Entry.NextEpisode ->
                    ContinueWatchingItem.NextEpisode(entry.episode, SmartContinueWatching.nextEpisodeRecord(entry.episode, seriesItem(entry.episode.seriesId), entry.after))
            }
        }
    }

    // Metadata cache

    override suspend fun entry(mediaId: String): MetadataCacheEntry? = read { db ->
        db.rawQuery("SELECT * FROM mediaMetadata WHERE mediaId = ?", arrayOf(mediaId)).use { c ->
            if (!c.moveToFirst()) null else MetadataCacheEntry(mediaId, if (c.str("kind") == "series") MediaMetadata.Kind.series else MediaMetadata.Kind.movie,
                c.str("json")?.let { runCatching { json.decodeFromString(MediaMetadata.serializer(), it) }.getOrNull() }, c.bool("notFound"), c.long("fetchedAt") ?: 0)
        }
    }

    override suspend fun cached(mediaIds: List<String>): Map<String, MediaMetadata> = mediaIds.mapNotNull { id -> entry(id)?.metadata?.let { id to it } }.toMap()

    override suspend fun save(metadata: MediaMetadata, mediaId: String): Unit = write(null) { db ->
        db.execSQL("INSERT OR REPLACE INTO mediaMetadata (mediaId, kind, json, notFound, fetchedAt) VALUES (?,?,?,0,?)",
            arrayOf<Any>(mediaId, metadata.kind.name, json.encodeToString(MediaMetadata.serializer(), metadata), metadata.fetchedAt))
    }

    override suspend fun saveNotFound(mediaId: String, kind: MediaMetadata.Kind, at: Long): Unit = write(null) { db ->
        db.execSQL("INSERT OR REPLACE INTO mediaMetadata (mediaId, kind, json, notFound, fetchedAt) VALUES (?,?,NULL,1,?)", arrayOf<Any>(mediaId, kind.name, at))
    }

    override suspend fun touch(mediaId: String, at: Long): Unit = write(null) { db ->
        db.execSQL("UPDATE mediaMetadata SET fetchedAt = ? WHERE mediaId = ?", arrayOf<Any>(at, mediaId))
    }

    override suspend fun markAllStale(): Unit = write(null) { db -> db.execSQL("UPDATE mediaMetadata SET fetchedAt = 0") }

    override suspend fun clear(): Unit = write(null) { db -> db.execSQL("DELETE FROM mediaMetadata") }

    /** The skipSegmentCache table. */
    public val skipCache: SkipSegmentCache = object : SkipSegmentCache {
        private val serializer = ListSerializer(SkipSegmentJson.serializer())

        override suspend fun entry(mediaId: String): SkipSegmentCacheEntry? = read { db ->
            db.rawQuery("SELECT json, fetchedAt FROM skipSegmentCache WHERE mediaId = ?", arrayOf(mediaId)).use { c ->
                if (!c.moveToFirst()) null else SkipSegmentCacheEntry(
                    runCatching { json.decodeFromString(serializer, c.getString(0)).map { it.segment() } }.getOrDefault(emptyList()), c.getLong(1))
            }
        }

        override suspend fun save(segments: List<SkipSegment>, mediaId: String, at: Long): Unit = write(null) { db ->
            db.execSQL("INSERT OR REPLACE INTO skipSegmentCache (mediaId, json, fetchedAt) VALUES (?,?,?)",
                arrayOf<Any>(mediaId, json.encodeToString(serializer, segments.map(SkipSegmentJson::of)), at))
        }
    }
}

@kotlinx.serialization.Serializable
internal data class SkipSegmentJson(val kind: String, val start: Double, val end: Double?, val source: String, val mayAutoSkip: Boolean) {
    fun segment() = SkipSegment(SkipSegment.Kind.entries.first { it.raw == kind }, start, end, SkipSegment.Source.entries.first { it.raw == source }, mayAutoSkip)

    companion object {
        fun of(s: SkipSegment) = SkipSegmentJson(s.kind.raw, s.start, s.end, s.source.raw, s.mayAutoSkip)
    }
}

// Cursor and statement helpers

internal fun <T> Cursor.map(transform: (Cursor) -> T): List<T> {
    val out = ArrayList<T>(count)
    while (moveToNext()) out.add(transform(this))
    return out
}

internal fun Cursor.idx(name: String) = getColumnIndex(name)
internal fun Cursor.str(name: String): String? = idx(name).let { if (it < 0 || isNull(it)) null else getString(it) }
internal fun Cursor.int(name: String): Int? = idx(name).let { if (it < 0 || isNull(it)) null else getInt(it) }
internal fun Cursor.long(name: String): Long? = idx(name).let { if (it < 0 || isNull(it)) null else getLong(it) }
internal fun Cursor.double(name: String): Double? = idx(name).let { if (it < 0 || isNull(it)) null else getDouble(it) }
internal fun Cursor.bool(name: String): Boolean = (int(name) ?: 0) != 0
internal fun Cursor.instant(name: String): Instant? = long(name)?.let { Instant.ofEpochMilli(it) }

internal fun android.database.sqlite.SQLiteStatement.bindAll(vararg values: Any?) {
    values.forEachIndexed { i, v ->
        val n = i + 1
        when (v) {
            null -> bindNull(n)
            is String -> bindString(n, v)
            is Int -> bindLong(n, v.toLong())
            is Long -> bindLong(n, v)
            is Double -> bindDouble(n, v)
            is Boolean -> bindLong(n, if (v) 1 else 0)
            else -> bindString(n, v.toString())
        }
    }
}
