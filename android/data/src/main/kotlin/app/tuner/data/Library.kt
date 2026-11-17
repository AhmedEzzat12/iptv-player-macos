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
}

@kotlinx.serialization.Serializable
internal data class SkipSegmentJson(val kind: String, val start: Double, val end: Double?, val source: String, val mayAutoSkip: Boolean) {
    fun segment() = SkipSegment(SkipSegment.Kind.entries.first { it.raw == kind }, start, end, SkipSegment.Source.entries.first { it.raw == source }, mayAutoSkip)

    companion object {
        fun of(s: SkipSegment) = SkipSegmentJson(s.kind.raw, s.start, s.end, s.source.raw, s.mayAutoSkip)
    }
}

