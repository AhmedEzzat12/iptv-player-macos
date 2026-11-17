// Android counterpart of AppDatabase+Library / +Queries / +User / +Metadata / +SkipSegments (Swift @ 666f598).
package app.tuner.data

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import androidx.room.withTransaction
import androidx.sqlite.db.SimpleSQLiteQuery
import app.tuner.core.metadata.MediaMetadata
import app.tuner.core.metadata.MetadataCache
import app.tuner.core.metadata.MetadataCacheEntry
import app.tuner.core.models.CatchupType
import app.tuner.core.models.Category
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Channel
import app.tuner.core.models.ContinueWatchingItem
import app.tuner.core.models.EPGChannel
import app.tuner.core.models.EPGFeed
import app.tuner.core.models.Episode
import app.tuner.core.models.MediaKind
import app.tuner.core.models.Movie
import app.tuner.core.models.Program
import app.tuner.core.models.Series
import app.tuner.core.models.SmartContinueWatching
import app.tuner.core.models.Source
import app.tuner.core.models.WatchProgress
import app.tuner.core.parsing.ChannelNameNormalizer
import app.tuner.core.services.GuideParse
import app.tuner.core.skip.SkipSegment
import app.tuner.core.skip.SkipSegmentCache
import app.tuner.core.skip.SkipSegmentCacheEntry
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.time.Instant

public enum class VODSort { ADDED, NAME, RATING }

public class Library(private val database: AppDatabase) : MetadataCache {
    private val json = Json { ignoreUnknownKeys = true }
    private val sourcesDao get() = database.sources()
    private val lib get() = database.library()
    private val user get() = database.user()
    private val caches get() = database.caches()
    private val guideDao get() = database.guide()

    /** Runs `block` in one transaction, then tells screens what changed. */
    private suspend fun <T> write(change: Change?, block: suspend () -> T): T =
        database.withTransaction { block() }.also { if (change != null) database.changed(change) }

    // Sources (passwords encrypted at rest)

    public suspend fun sources(): List<Source> = sourcesDao.all().map { source(it) }

    public suspend fun source(id: String): Source? = sourcesDao.get(id)?.let { source(it) }

    public suspend fun save(source: Source): Unit = write(Change.LIBRARY) {
        sourcesDao.upsert(SourceEntity(
            id = source.id, name = source.name, kind = source.kind.raw, url = source.url, username = source.username,
            password = source.password?.takeIf { it.isNotEmpty() }?.let { Secrets.encrypt(it) }, mac = source.mac, epgURL = source.epgURL,
            autoLoadEPG = source.autoLoadEPG, extraEPGURLs = json.encodeToString(ListSerializer(String.serializer()), source.extraEPGURLs),
            epgTimeshiftHours = source.epgTimeshiftHours, userAgent = source.userAgent,
            backupURLs = json.encodeToString(ListSerializer(String.serializer()), source.backupURLs), enabled = source.enabled,
            includeLive = source.includeLive, includeVOD = source.includeVOD, refreshHours = source.refreshHours, sortIndex = source.sortIndex,
            createdAt = source.createdAt.toEpochMilli(), lastSyncedAt = source.lastSyncedAt?.toEpochMilli(),
            lastVODSyncedAt = source.lastVODSyncedAt?.toEpochMilli(), lastError = source.lastError, expiresAt = source.expiresAt?.toEpochMilli(),
            activeConnections = source.activeConnections, maxConnections = source.maxConnections, discoveredEPGURL = source.discoveredEPGURL,
            channelCount = source.channelCount, movieCount = source.movieCount, seriesCount = source.seriesCount, needsPassword = source.needsPassword,
        ))
    }

    public suspend fun deleteSource(id: String): Unit = write(Change.LIBRARY) { sourcesDao.delete(id) }

    /** Updates sync status fields (given as column → value) without touching configuration edited meanwhile. */
    public suspend fun updateStatus(id: String, values: ContentValues): Unit = write(Change.LIBRARY) {
        database.openHelper.writableDatabase.update("source", SQLiteDatabase.CONFLICT_NONE, values, "id = ?", arrayOf(id))
    }

    private fun source(e: SourceEntity): Source {
        val password = e.password?.let { Secrets.decrypt(it) }
        return Source(
            id = e.id, name = e.name, kind = Source.Kind.of(e.kind) ?: Source.Kind.M3U, url = e.url, username = e.username, password = password,
            mac = e.mac, epgURL = e.epgURL, autoLoadEPG = e.autoLoadEPG, extraEPGURLs = list(e.extraEPGURLs), epgTimeshiftHours = e.epgTimeshiftHours,
            userAgent = e.userAgent, backupURLs = list(e.backupURLs), enabled = e.enabled, includeLive = e.includeLive, includeVOD = e.includeVOD,
            refreshHours = e.refreshHours, sortIndex = e.sortIndex, createdAt = Instant.ofEpochMilli(e.createdAt),
            // A password that can't be decrypted here (restored from another device's backup) has to be entered again.
            needsPassword = e.needsPassword || (e.password != null && password == null),
            lastSyncedAt = e.lastSyncedAt?.let(Instant::ofEpochMilli), lastVODSyncedAt = e.lastVODSyncedAt?.let(Instant::ofEpochMilli),
            lastError = e.lastError, expiresAt = e.expiresAt?.let(Instant::ofEpochMilli), activeConnections = e.activeConnections,
            maxConnections = e.maxConnections, discoveredEPGURL = e.discoveredEPGURL, channelCount = e.channelCount,
            movieCount = e.movieCount, seriesCount = e.seriesCount,
        )
    }

    private fun list(s: String?): List<String> = s?.let { runCatching { json.decodeFromString(ListSerializer(String.serializer()), it) }.getOrNull() } ?: emptyList()

    // Provider data: replaced per source in one transaction (user state lives elsewhere)

    public suspend fun replaceLive(sourceId: String, categories: List<Category>, channels: List<Channel>): Unit = write(Change.LIBRARY) {
        val oldKeys = lib.epgKeys(sourceId).associate { it.id to it.epgKey }
        lib.deleteChannels(sourceId)
        lib.deleteCategories(sourceId, "live")
        lib.insertCategories(categories.map(::categoryEntity))
        lib.insertChannels(channels.map { ch ->
            ChannelEntity(ch.id, ch.sourceId, ch.categoryId, ch.name, ChannelNameNormalizer.normalize(ch.name), ch.number, ch.providerOrder,
                ch.logoURL, ch.tvgId, ch.streamURL, ch.providerStreamId, ch.catchupType?.raw, ch.catchupSource, ch.catchupDays,
                ch.userAgent, ch.referrer, ch.isAdult, oldKeys[ch.id])
        })
    }

    public suspend fun replaceMovies(sourceId: String, categories: List<Category>, movies: List<Movie>): Unit = write(Change.LIBRARY) {
        lib.deleteMovies(sourceId)
        lib.deleteCategories(sourceId, "movie")
        lib.insertCategories(categories.map(::categoryEntity))
        lib.insertMovies(movies.map(::movieEntity))
    }

    public suspend fun replaceSeries(sourceId: String, categories: List<Category>, series: List<Series>): Unit = write(Change.LIBRARY) {
        lib.deleteSeries(sourceId)
        lib.deleteCategories(sourceId, "series")
        lib.insertCategories(categories.map(::categoryEntity))
        lib.insertSeries(series.map(::seriesEntity))
    }

    /** Adds items of one lazily loaded (Stalker) category without touching others. */
    public suspend fun appendVOD(movies: List<Movie>, series: List<Series>): Unit = write(Change.LIBRARY) {
        lib.insertMovies(movies.map(::movieEntity))
        lib.insertSeries(series.map(::seriesEntity))
    }

    /** Episodes for many shows in one transaction. */
    public suspend fun replaceEpisodes(bySeries: Map<String, List<Episode>>): Unit = write(Change.LIBRARY) {
        for ((seriesId, episodes) in bySeries) {
            lib.deleteEpisodes(seriesId)
            lib.insertEpisodes(episodes.map { e ->
                EpisodeEntity(e.id, e.seriesId, e.sourceId, e.season, e.number, e.title, e.plot, e.imageURL, e.durationSeconds, e.providerId,
                    e.containerExtension, e.streamURL, e.airDate)
            })
        }
    }

    private fun categoryEntity(c: Category) = CategoryEntity(c.id, c.sourceId, c.kind.raw, c.name, c.providerOrder)

    private fun movieEntity(m: Movie) = MovieEntity(m.id, m.sourceId, m.categoryId, m.name, m.year, m.posterURL, m.backdropURL, m.providerId,
        m.containerExtension, m.streamURL, m.rating, m.plot, m.genre, m.cast, m.director, m.releaseDate, m.durationSeconds,
        m.addedAt?.let { it.toEpochMilli() / 1000.0 }, m.providerOrder, m.trailer, m.tmdbId)

    private fun seriesEntity(s: Series) = SeriesEntity(s.id, s.sourceId, s.categoryId, s.name, s.year, s.coverURL, s.backdropURL, s.providerId,
        s.rating, s.plot, s.genre, s.cast, s.director, s.releaseDate, s.addedAt?.let { it.toEpochMilli() / 1000.0 },
        s.lastModified?.let { it.toEpochMilli() / 1000.0 }, s.providerOrder, s.trailer, s.streamURL)

    // Reads

    public suspend fun categories(kind: CategoryKind): List<Category> {
        val count = when (kind) {
            CategoryKind.LIVE -> "(SELECT COUNT(*) FROM channel x WHERE x.categoryId = c.id)"
            CategoryKind.MOVIE -> "(SELECT COUNT(*) FROM movie x WHERE x.categoryId = c.id)"
            CategoryKind.SERIES -> "(SELECT COUNT(*) FROM series x WHERE x.categoryId = c.id)"
        }
        val rows = lib.categories(SimpleSQLiteQuery("""SELECT c.id, c.sourceId, c.kind, c.name, c.providerOrder, p.alias, p.sortIndex AS prefSort,
            $count AS n FROM category c JOIN source s ON s.id = c.sourceId LEFT JOIN categoryPref p ON p.categoryId = c.id
            WHERE c.kind = ? AND COALESCE(p.isHidden, 0) = 0 ORDER BY s.sortIndex, p.sortIndex IS NULL, p.sortIndex, c.providerOrder""", arrayOf(kind.raw)))
        return rows.map { Category(it.id, it.sourceId, kind, it.name, it.providerOrder, alias = it.alias, sortIndex = it.prefSort, itemCount = it.n) }
            .filter { it.itemCount > 0 || kind != CategoryKind.LIVE }
    }

    public sealed class ChannelScope {
        public object All : ChannelScope()
        public object Favorites : ChannelScope()
        public object Recent : ChannelScope()
        public data class InCategory(val id: String) : ChannelScope()
    }

    private val channelColumns = """c.id, c.sourceId, c.categoryId, c.name, c.number, c.providerOrder, c.logoURL, c.tvgId, c.streamURL, c.providerStreamId,
        c.catchupType, c.catchupSource, c.catchupDays, c.userAgent, c.referrer, c.isAdult, c.epgKey, p.isFavorite, p.favoriteOrder, p.isHidden,
        p.alias, p.epgIdOverride"""

    public suspend fun channels(scope: ChannelScope, search: String? = null, limit: Int? = null): List<Channel> {
        var sql = "SELECT $channelColumns FROM channel c JOIN source s ON s.id = c.sourceId LEFT JOIN channelPref p ON p.channelId = c.id"
        val args = mutableListOf<Any>()
        val where = mutableListOf("COALESCE(p.isHidden, 0) = 0")
        var order = "s.sortIndex, c.sourceId, c.providerOrder"
        when (scope) {
            ChannelScope.All -> Unit
            ChannelScope.Favorites -> { where.add("p.isFavorite = 1"); order = "p.favoriteOrder IS NULL, p.favoriteOrder, c.name COLLATE NOCASE" }
            ChannelScope.Recent -> { sql += " JOIN history h ON h.channelId = c.id"; order = "h.watchedAt DESC" }
            is ChannelScope.InCategory -> { where.add("c.categoryId = ?"); args.add(scope.id) }
        }
        for (word in words(search)) { where.add("(c.name LIKE ? OR p.alias LIKE ?)"); args.add("%$word%"); args.add("%$word%") }
        sql += " WHERE " + where.joinToString(" AND ") + " ORDER BY $order"
        (limit ?: if (scope == ChannelScope.Recent) 50 else null)?.let { sql += " LIMIT $it" }
        return lib.channels(SimpleSQLiteQuery(sql, args.toTypedArray())).map(::channel)
    }

    /**
     * The same channel elsewhere (same normalised name, EPG key or tvg-id; visible, in an enabled playlist), for live
     * failover. Port of AppDatabase.alternateChannels (AppDatabase+Queries.swift).
     */
    public suspend fun alternateChannels(channel: Channel): List<Channel> {
        val conditions = mutableListOf("c.normalizedName = ?")
        val args = mutableListOf<Any>(channel.id, ChannelNameNormalizer.normalize(channel.name))
        channel.epgKey?.let { conditions += "c.epgKey = ?"; args += it }
        channel.tvgId?.takeIf { it.isNotEmpty() }?.let { conditions += "c.tvgId = ?"; args += it }
        val sql = "SELECT $channelColumns FROM channel c JOIN source s ON s.id = c.sourceId AND s.enabled = 1 " +
            "LEFT JOIN channelPref p ON p.channelId = c.id WHERE c.id <> ? AND (${conditions.joinToString(" OR ")}) " +
            "AND COALESCE(p.isHidden, 0) = 0 ORDER BY s.sortIndex, c.providerOrder LIMIT 20"
        return lib.channels(SimpleSQLiteQuery(sql, args.toTypedArray())).map(::channel)
    }

    public suspend fun channel(id: String): Channel? = lib.channels(SimpleSQLiteQuery(
        "SELECT $channelColumns FROM channel c LEFT JOIN channelPref p ON p.channelId = c.id WHERE c.id = ?", arrayOf(id))).firstOrNull()?.let(::channel)

    private fun channel(r: ChannelRow) = Channel(
        id = r.id, sourceId = r.sourceId, categoryId = r.categoryId, name = r.name, number = r.number, providerOrder = r.providerOrder,
        logoURL = r.logoURL, tvgId = r.tvgId, streamURL = r.streamURL, providerStreamId = r.providerStreamId,
        catchupType = r.catchupType?.let { CatchupType.of(it) }, catchupSource = r.catchupSource, catchupDays = r.catchupDays,
        userAgent = r.userAgent, referrer = r.referrer, isAdult = r.isAdult, epgKey = r.epgKey, isFavorite = r.isFavorite == true,
        favoriteOrder = r.favoriteOrder, isHidden = r.isHidden == true, alias = r.alias, epgIdOverride = r.epgIdOverride,
    )

    private fun words(search: String?) = search?.trim()?.split(Regex("\\s+"))?.filter { it.isNotEmpty() } ?: emptyList()

    private fun vodOrder(sort: VODSort) = when (sort) {
        VODSort.ADDED -> "addedAt IS NULL, addedAt DESC, providerOrder"
        VODSort.NAME -> "name COLLATE NOCASE"
        VODSort.RATING -> "rating IS NULL, rating DESC, name COLLATE NOCASE"
    }

    private fun vodQuery(table: String, categoryId: String?, search: String?, sort: VODSort, limit: Int, offset: Int): SimpleSQLiteQuery {
        val where = mutableListOf<String>()
        val args = mutableListOf<Any>()
        if (categoryId != null) { where.add("categoryId = ?"); args.add(categoryId) }
        for (word in words(search)) { where.add("name LIKE ?"); args.add("%$word%") }
        val clause = if (where.isEmpty()) "" else "WHERE " + where.joinToString(" AND ")
        return SimpleSQLiteQuery("SELECT * FROM $table $clause ORDER BY ${vodOrder(sort)} LIMIT $limit OFFSET $offset", args.toTypedArray())
    }

    public suspend fun movies(categoryId: String? = null, search: String? = null, sort: VODSort = VODSort.ADDED, limit: Int = 200, offset: Int = 0): List<Movie> =
        lib.movies(vodQuery("movie", categoryId, search, sort, limit, offset)).map(::movie)

    public suspend fun series(categoryId: String? = null, search: String? = null, sort: VODSort = VODSort.ADDED, limit: Int = 200, offset: Int = 0): List<Series> =
        lib.series(vodQuery("series", categoryId, search, sort, limit, offset)).map(::series)

    public suspend fun movie(id: String): Movie? = lib.movie(id)?.let(::movie)

    public suspend fun seriesItem(id: String): Series? = lib.seriesItem(id)?.let(::series)

    public suspend fun episodes(seriesId: String): List<Episode> = lib.episodes(seriesId).map { e ->
        Episode(id = e.id, seriesId = e.seriesId, sourceId = e.sourceId, season = e.season, number = e.number, title = e.title,
            providerId = e.providerId, streamURL = e.streamURL, plot = e.plot, imageURL = e.imageURL, durationSeconds = e.durationSeconds,
            containerExtension = e.containerExtension, airDate = e.airDate)
    }

    private fun movie(m: MovieEntity) = Movie(
        id = m.id, sourceId = m.sourceId, categoryId = m.categoryId, name = m.name, providerId = m.providerId, streamURL = m.streamURL,
        providerOrder = m.providerOrder, year = m.year, posterURL = m.posterURL, backdropURL = m.backdropURL, containerExtension = m.containerExtension,
        rating = m.rating, plot = m.plot, genre = m.genre, cast = m.cast, director = m.director, releaseDate = m.releaseDate,
        durationSeconds = m.durationSeconds, addedAt = m.addedAt?.let { Instant.ofEpochMilli((it * 1000).toLong()) }, trailer = m.trailer, tmdbId = m.tmdbId,
    )

    private fun series(s: SeriesEntity) = Series(
        id = s.id, sourceId = s.sourceId, categoryId = s.categoryId, name = s.name, providerId = s.providerId, streamURL = s.streamURL,
        providerOrder = s.providerOrder, year = s.year, coverURL = s.coverURL, backdropURL = s.backdropURL, rating = s.rating, plot = s.plot,
        genre = s.genre, cast = s.cast, director = s.director, releaseDate = s.releaseDate,
        addedAt = s.addedAt?.let { Instant.ofEpochMilli((it * 1000).toLong()) }, trailer = s.trailer,
    )

    // User state

    public suspend fun setFavorite(channelId: String, favorite: Boolean): Unit = write(Change.USER) { user.setFavorite(channelId, favorite) }

    public suspend fun recordWatched(channelId: String): Unit = write(Change.USER) { user.recordWatched(HistoryEntity(channelId, System.currentTimeMillis())) }

    public suspend fun progress(mediaId: String): WatchProgress? = user.progress(mediaId)?.let(::progress)

    public suspend fun progress(seriesId: String, forSeries: Boolean): Map<String, WatchProgress> =
        user.seriesProgress(seriesId).map(::progress).associateBy { it.mediaId }

    /** Saves a resume point; ignores zero-length media so a failed load can't wipe progress. */
    public suspend fun saveProgress(p: WatchProgress) {
        if (p.duration <= 0) return
        write(Change.USER) {
            user.saveProgress(WatchProgressEntity(p.mediaId, p.kind.raw, p.sourceId, p.seriesId, p.title, p.subtitle, p.posterURL, p.position,
                p.duration, WatchProgress.isComplete(p.position, p.duration), p.updatedAt.toEpochMilli()))
        }
    }

    private fun progress(e: WatchProgressEntity) = WatchProgress(
        mediaId = e.mediaId, kind = MediaKind.of(e.kind) ?: MediaKind.MOVIE, sourceId = e.sourceId, seriesId = e.seriesId, title = e.title,
        subtitle = e.subtitle, posterURL = e.posterURL, position = e.position, duration = e.duration, completed = e.completed,
        updatedAt = Instant.ofEpochMilli(e.updatedAt),
    )

    /** Resume points plus the next cached episode of shows whose latest episode was finished (SmartContinueWatching). */
    public suspend fun continueWatching(limit: Int = 20): List<ContinueWatchingItem> {
        val records = user.continueWatchingCandidates().map(::progress)
        val episodes = SmartContinueWatching.showsNeedingEpisodes(records).associateWith { episodes(it) }
        return SmartContinueWatching.rank(records, episodes, Instant.now(), limit).map { entry ->
            when (entry) {
                is SmartContinueWatching.Entry.Resume -> ContinueWatchingItem.Resume(entry.progress)
                is SmartContinueWatching.Entry.NextEpisode -> ContinueWatchingItem.NextEpisode(entry.episode,
                    SmartContinueWatching.nextEpisodeRecord(entry.episode, seriesItem(entry.episode.seriesId), entry.after))
            }
        }
    }

    // Metadata cache

    override suspend fun entry(mediaId: String): MetadataCacheEntry? = caches.metadata(mediaId)?.let { e ->
        MetadataCacheEntry(mediaId, if (e.kind == "series") MediaMetadata.Kind.series else MediaMetadata.Kind.movie,
            e.json?.let { runCatching { json.decodeFromString(MediaMetadata.serializer(), it) }.getOrNull() }, e.notFound, e.fetchedAt)
    }

    override suspend fun cached(mediaIds: List<String>): Map<String, MediaMetadata> = mediaIds.mapNotNull { id -> entry(id)?.metadata?.let { id to it } }.toMap()

    override suspend fun save(metadata: MediaMetadata, mediaId: String) {
        caches.saveMetadata(MediaMetadataEntity(mediaId, metadata.kind.name, json.encodeToString(MediaMetadata.serializer(), metadata), false, metadata.fetchedAt))
    }

    override suspend fun saveNotFound(mediaId: String, kind: MediaMetadata.Kind, at: Long) {
        caches.saveMetadata(MediaMetadataEntity(mediaId, kind.name, null, true, at))
    }

    override suspend fun touch(mediaId: String, at: Long): Unit = caches.touchMetadata(mediaId, at)

    override suspend fun markAllStale(): Unit = caches.staleMetadata()

    override suspend fun clear(): Unit = caches.clearMetadata()

    /** The skipSegmentCache table. */
    public val skipCache: SkipSegmentCache = object : SkipSegmentCache {
        private val serializer = ListSerializer(SkipSegmentJson.serializer())

        override suspend fun entry(mediaId: String): SkipSegmentCacheEntry? = caches.skip(mediaId)?.let { e ->
            SkipSegmentCacheEntry(runCatching { json.decodeFromString(serializer, e.json).map { it.segment() } }.getOrDefault(emptyList()), e.fetchedAt)
        }

        override suspend fun save(segments: List<SkipSegment>, mediaId: String, at: Long) {
            caches.saveSkip(SkipSegmentCacheEntity(mediaId, json.encodeToString(serializer, segments.map(SkipSegmentJson::of)), at))
        }
    }

    // Guide (XMLTV / Stalker EPG)

    public suspend fun epgFeeds(): List<EPGFeed> = guideDao.feeds().map { e ->
        EPGFeed(e.id, e.url, e.sourceId, e.priority, e.lastFetchedAt?.let(Instant::ofEpochMilli), e.lastError, e.channelCount, e.programCount)
    }

    public suspend fun saveFeed(feed: EPGFeed): Unit = write(Change.GUIDE) {
        guideDao.upsertFeed(EpgFeedEntity(feed.id, feed.url, feed.sourceId, feed.priority, feed.lastFetchedAt?.toEpochMilli(),
            feed.lastError, feed.channelCount, feed.programCount))
    }

    public suspend fun recordFeedError(feedId: String, error: String): Unit = write(Change.GUIDE) {
        val values = ContentValues().apply { put("lastError", error); put("lastFetchedAt", System.currentTimeMillis()) }
        database.openHelper.writableDatabase.update("epgFeed", SQLiteDatabase.CONFLICT_NONE, values, "id = ?", arrayOf(feedId))
    }

    public suspend fun deleteFeed(id: String): Unit = write(Change.GUIDE) { guideDao.deleteFeed(id) }

    public suspend fun wantedGuideSet(): GuideParse.Wanted {
        val ids = HashSet<String>()
        val names = HashSet<String>()
        val db = database.openHelper.readableDatabase
        db.query("SELECT c.tvgId, c.normalizedName, p.epgIdOverride FROM channel c LEFT JOIN channelPref p ON p.channelId = c.id").use { cur ->
            while (cur.moveToNext()) {
                cur.getString(0)?.takeIf { it.isNotEmpty() }?.let { ids.add(it.lowercase()) }
                cur.getString(1)?.takeIf { it.isNotEmpty() }?.let { names.add(it) }
                cur.getString(2)?.takeIf { it.isNotEmpty() }?.let { ids.add(it.lowercase()) }
            }
        }
        return GuideParse.Wanted(ids, names)
    }

    public suspend fun replaceGuide(
        feedId: String,
        channels: List<EPGChannel>,
        programmes: List<Program>,
        counts: Map<String, Int>,
    ): Unit = write(Change.GUIDE) {
        guideDao.deleteProgrammes(feedId)
        guideDao.deleteEpgChannels(feedId)
        guideDao.insertEpgChannels(channels.map { c ->
            EpgChannelEntity(c.key, feedId, c.xmltvId, c.displayName, c.normalizedName, c.iconURL, counts[c.key] ?: 0)
        })
        for (chunk in programmes.chunked(5_000)) {
            guideDao.insertProgrammes(chunk.map { p ->
                ProgramEntity(0, feedId, p.epgKey, p.start.epochSecond, p.end.epochSecond, p.title, p.subtitle, p.summary, p.category, p.iconURL, p.episode)
            })
        }
        val values = ContentValues().apply {
            put("lastFetchedAt", System.currentTimeMillis())
            putNull("lastError")
            put("channelCount", channels.size)
            put("programCount", programmes.size)
        }
        database.openHelper.writableDatabase.update("epgFeed", SQLiteDatabase.CONFLICT_NONE, values, "id = ?", arrayOf(feedId))
    }

    /** Recomputes `channel.epgKey`: override → Stalker native → tvg-id → normalised name, preferring keys with programmes and own-source feeds. */
    public suspend fun resolveEPGKeys(): Unit = write(Change.GUIDE) {
        val db = database.openHelper.writableDatabase
        data class Candidate(val key: String, val feedId: String, val hasPrograms: Boolean)
        val feedSource = HashMap<String, String?>()
        val feedPriority = HashMap<String, Int>()
        db.query("SELECT id, sourceId, priority FROM epgFeed").use { cur ->
            while (cur.moveToNext()) {
                val id = cur.getString(0)
                feedSource[id] = if (cur.isNull(1)) null else cur.getString(1)
                feedPriority[id] = cur.getInt(2)
            }
        }
        val byId = HashMap<String, MutableList<Candidate>>()
        val byName = HashMap<String, MutableList<Candidate>>()
        val stalkerKeys = HashSet<String>()
        db.query("SELECT key, feedId, xmltvId, normalizedName, programCount FROM epgChannel").use { cur ->
            while (cur.moveToNext()) {
                val key = cur.getString(0)
                val feedId = cur.getString(1)
                val xmltvId = cur.getString(2)
                val norm = cur.getString(3)
                val c = Candidate(key, feedId, cur.getInt(4) > 0)
                byId.getOrPut(xmltvId.lowercase()) { mutableListOf() }.add(c)
                if (norm.isNotEmpty()) byName.getOrPut(norm) { mutableListOf() }.add(c)
                if (feedId.endsWith("#stalker")) stalkerKeys.add(key)
            }
        }
        fun rank(c: Candidate, sourceId: String): Int {
            val owner = feedSource[c.feedId]
            val tier = when (owner) { sourceId -> 0; null -> 1; else -> 2 }
            return (if (c.hasPrograms) 0 else 100_000) + tier * 10_000 + (feedPriority[c.feedId] ?: 99)
        }
        fun best(list: List<Candidate>?, sourceId: String): String? = list?.minByOrNull { rank(it, sourceId) }?.key

        val updates = mutableListOf<Pair<String, String?>>()
        db.query("""SELECT c.id, c.sourceId, c.tvgId, c.normalizedName, c.providerStreamId, c.epgKey, p.epgIdOverride
            FROM channel c LEFT JOIN channelPref p ON p.channelId = c.id""").use { cur ->
            while (cur.moveToNext()) {
                val id = cur.getString(0)
                val sourceId = cur.getString(1)
                val tvgId = if (cur.isNull(2)) null else cur.getString(2)
                val norm = cur.getString(3)
                val sid = if (cur.isNull(4)) null else cur.getString(4)
                val oldKey = if (cur.isNull(5)) null else cur.getString(5)
                val override = if (cur.isNull(6)) null else cur.getString(6)
                var key: String? = null
                if (!override.isNullOrEmpty()) key = best(byId[override.lowercase()], sourceId) ?: if ('|' in override) override else null
                if (key == null && !sid.isNullOrEmpty()) {
                    val sk = "$sourceId#stalker|$sid"
                    if (sk in stalkerKeys) key = sk
                }
                if (key == null && !tvgId.isNullOrBlank()) key = best(byId[tvgId.lowercase()], sourceId)
                if (key == null) key = best(byName[norm], sourceId)
                if (key != oldKey) updates.add(id to key)
            }
        }
        if (updates.isNotEmpty()) {
            val stmt = db.compileStatement("UPDATE channel SET epgKey = ? WHERE id = ?")
            for ((id, key) in updates) {
                if (key == null) stmt.bindNull(1) else stmt.bindString(1, key)
                stmt.bindString(2, id)
                stmt.executeUpdateDelete()
            }
        }
    }

    public suspend fun pruneProgrammes(endedBefore: Instant): Unit = guideDao.pruneProgrammes(endedBefore.epochSecond)

    /** Programmes overlapping `[from, to)` grouped by EPG key, sorted by start, overlaps trimmed. */
    public suspend fun programs(epgKeys: List<String>, from: Instant, to: Instant): Map<String, List<Program>> {
        val unique = epgKeys.distinct().filter { it.isNotEmpty() }
        if (unique.isEmpty()) return emptyMap()
        val lo = from.epochSecond
        val hi = to.epochSecond
        val map = HashMap<String, MutableList<Program>>()
        for (chunk in unique.chunked(400)) {
            val marks = chunk.joinToString(",") { "?" }
            val args = Array<Any>(chunk.size + 2) { i -> if (i < chunk.size) chunk[i] else if (i == chunk.size) hi else lo }
            val rows = guideDao.programmes(SimpleSQLiteQuery(
                "SELECT * FROM program WHERE epgKey IN ($marks) AND start < ? AND end > ? ORDER BY epgKey, start", args))
            for (r in rows) map.getOrPut(r.epgKey) { mutableListOf() }.add(program(r))
        }
        return map.mapValues { (_, list) -> trimOverlaps(list) }
    }

    public suspend fun searchPrograms(query: String, from: Instant = Instant.now(), hours: Long = 72, limit: Int = 200): List<Program> {
        val w = words(query)
        if (w.isEmpty()) return emptyList()
        val args = mutableListOf<Any>(from.epochSecond, from.plusSeconds(hours * 3600).epochSecond)
        val conds = w.map { "(title LIKE ? OR subtitle LIKE ?)" }
        for (word in w) { args.add("%$word%"); args.add("%$word%") }
        val sql = "SELECT * FROM program WHERE end > ? AND start < ? AND ${conds.joinToString(" AND ")} AND epgKey IN (SELECT epgKey FROM channel WHERE epgKey IS NOT NULL) ORDER BY start LIMIT $limit"
        return guideDao.programmes(SimpleSQLiteQuery(sql, args.toTypedArray())).map(::program)
    }

    public suspend fun epgChannels(matching: String, limit: Int = 100): List<EPGChannel> =
        guideDao.searchEpgChannels("%${matching.trim()}%", limit).map { EPGChannel(it.feedId, it.xmltvId, it.displayName, it.iconURL) }

    private fun program(r: ProgramEntity) = Program(
        id = r.id, epgKey = r.epgKey, start = Instant.ofEpochSecond(r.start), end = Instant.ofEpochSecond(r.end),
        title = r.title, subtitle = r.subtitle, summary = r.summary, category = r.category, iconURL = r.iconURL, episode = r.episode,
    )

    public companion object {
        /** Clamps each programme's end to the next programme's start so cells never overlap. */
        public fun trimOverlaps(list: List<Program>): List<Program> = GuideParse.trimOverlaps(list)
    }
}

@kotlinx.serialization.Serializable
internal data class SkipSegmentJson(val kind: String, val start: Double, val end: Double?, val source: String, val mayAutoSkip: Boolean) {
    fun segment() = SkipSegment(SkipSegment.Kind.entries.first { it.raw == kind }, start, end, SkipSegment.Source.entries.first { it.raw == source }, mayAutoSkip)

    companion object {
        fun of(s: SkipSegment) = SkipSegmentJson(s.kind.raw, s.start, s.end, s.source.raw, s.mayAutoSkip)
    }
}

