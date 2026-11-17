package app.tuner.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.RawQuery
import androidx.room.Upsert
import androidx.sqlite.db.SupportSQLiteQuery

@Dao
interface SourceDao {
    @Query("SELECT * FROM source ORDER BY sortIndex, createdAt") suspend fun all(): List<SourceEntity>
    @Query("SELECT * FROM source WHERE id = :id") suspend fun get(id: String): SourceEntity?
    @Upsert suspend fun upsert(source: SourceEntity)
    @Query("DELETE FROM source WHERE id = :id") suspend fun delete(id: String)
}

@Dao
interface LibraryDao {
    @Query("SELECT id, epgKey FROM channel WHERE sourceId = :sourceId AND epgKey IS NOT NULL") suspend fun epgKeys(sourceId: String): List<IdKey>
    @Query("DELETE FROM channel WHERE sourceId = :sourceId") suspend fun deleteChannels(sourceId: String)
    @Query("DELETE FROM category WHERE sourceId = :sourceId AND kind = :kind") suspend fun deleteCategories(sourceId: String, kind: String)
    @Query("DELETE FROM movie WHERE sourceId = :sourceId") suspend fun deleteMovies(sourceId: String)
    @Query("DELETE FROM series WHERE sourceId = :sourceId") suspend fun deleteSeries(sourceId: String)
    @Query("DELETE FROM episode WHERE seriesId = :seriesId") suspend fun deleteEpisodes(seriesId: String)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun insertCategories(items: List<CategoryEntity>)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun insertChannels(items: List<ChannelEntity>)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun insertMovies(items: List<MovieEntity>)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun insertSeries(items: List<SeriesEntity>)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun insertEpisodes(items: List<EpisodeEntity>)

    @RawQuery suspend fun categories(query: SupportSQLiteQuery): List<CategoryRow>
    @RawQuery suspend fun channels(query: SupportSQLiteQuery): List<ChannelRow>
    @RawQuery suspend fun movies(query: SupportSQLiteQuery): List<MovieEntity>
    @RawQuery suspend fun series(query: SupportSQLiteQuery): List<SeriesEntity>
    @Query("SELECT * FROM movie WHERE id = :id") suspend fun movie(id: String): MovieEntity?
    @Query("SELECT * FROM series WHERE id = :id") suspend fun seriesItem(id: String): SeriesEntity?
    @Query("SELECT * FROM episode WHERE seriesId = :seriesId ORDER BY season, number") suspend fun episodes(seriesId: String): List<EpisodeEntity>
}

data class IdKey(val id: String, val epgKey: String)

data class CategoryRow(val id: String, val sourceId: String, val kind: String, val name: String, val providerOrder: Int,
                       val alias: String?, val prefSort: Int?, val n: Int)

@Dao
interface UserDao {
    @Query("INSERT INTO channelPref (channelId, isFavorite) VALUES (:channelId, :favorite) ON CONFLICT(channelId) DO UPDATE SET isFavorite = excluded.isFavorite")
    suspend fun setFavorite(channelId: String, favorite: Boolean)
    @Upsert suspend fun recordWatched(entry: HistoryEntity)
    @Query("SELECT * FROM watchProgress WHERE mediaId = :mediaId") suspend fun progress(mediaId: String): WatchProgressEntity?
    @Query("SELECT * FROM watchProgress WHERE seriesId = :seriesId") suspend fun seriesProgress(seriesId: String): List<WatchProgressEntity>
    @Upsert suspend fun saveProgress(p: WatchProgressEntity)
    @Query("""SELECT * FROM watchProgress WHERE kind IN ('movie','episode') AND (seriesId IS NOT NULL OR (completed = 0 AND position > 10))
        ORDER BY updatedAt DESC LIMIT 500""") suspend fun continueWatchingCandidates(): List<WatchProgressEntity>
}

@Dao
interface CacheDao {
    @Query("SELECT * FROM mediaMetadata WHERE mediaId = :mediaId") suspend fun metadata(mediaId: String): MediaMetadataEntity?
    @Upsert suspend fun saveMetadata(e: MediaMetadataEntity)
    @Query("UPDATE mediaMetadata SET fetchedAt = :at WHERE mediaId = :mediaId") suspend fun touchMetadata(mediaId: String, at: Long)
    @Query("UPDATE mediaMetadata SET fetchedAt = 0") suspend fun staleMetadata()
    @Query("DELETE FROM mediaMetadata") suspend fun clearMetadata()
    @Query("SELECT * FROM skipSegmentCache WHERE mediaId = :mediaId") suspend fun skip(mediaId: String): SkipSegmentCacheEntity?
    @Upsert suspend fun saveSkip(e: SkipSegmentCacheEntity)
}

@Dao
interface GuideDao {
    @Query("SELECT * FROM epgFeed ORDER BY sourceId IS NULL, priority, id") suspend fun feeds(): List<EpgFeedEntity>
    @Upsert suspend fun upsertFeed(feed: EpgFeedEntity)
    @Query("DELETE FROM epgFeed WHERE id = :id") suspend fun deleteFeed(id: String)
    @Query("DELETE FROM program WHERE feedId = :feedId") suspend fun deleteProgrammes(feedId: String)
    @Query("DELETE FROM epgChannel WHERE feedId = :feedId") suspend fun deleteEpgChannels(feedId: String)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun insertEpgChannels(items: List<EpgChannelEntity>)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun insertProgrammes(items: List<ProgramEntity>)
    @Query("DELETE FROM program WHERE end < :endedBefore") suspend fun pruneProgrammes(endedBefore: Long)
    @RawQuery suspend fun programmes(query: SupportSQLiteQuery): List<ProgramEntity>
    @Query("SELECT * FROM epgChannel WHERE displayName LIKE :pattern OR xmltvId LIKE :pattern ORDER BY programCount DESC, displayName COLLATE NOCASE LIMIT :limit")
    suspend fun searchEpgChannels(pattern: String, limit: Int): List<EpgChannelEntity>
}
