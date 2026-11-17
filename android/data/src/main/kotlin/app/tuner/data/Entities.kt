// Room entities: the same tables and columns as the Apple apps (appendix B). Instants are epoch ms (programme
// start/end epoch seconds); `addedAt`/`lastModified` are epoch seconds as REAL, as the providers give them.
package app.tuner.data

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(tableName = "source")
data class SourceEntity(
    @PrimaryKey val id: String, val name: String, val kind: String, val url: String,
    val username: String?, val password: String?, val mac: String?, val epgURL: String?,
    val autoLoadEPG: Boolean = true, val extraEPGURLs: String = "[]", val epgTimeshiftHours: Double = 0.0, val userAgent: String?,
    val backupURLs: String = "[]", val enabled: Boolean = true, val includeLive: Boolean = true, val includeVOD: Boolean = true,
    val refreshHours: Int?, val sortIndex: Int = 0, val createdAt: Long, val lastSyncedAt: Long?, val lastVODSyncedAt: Long?,
    val lastError: String?, val expiresAt: Long?, val activeConnections: Int?, val maxConnections: Int?, val discoveredEPGURL: String?,
    val channelCount: Int = 0, val movieCount: Int = 0, val seriesCount: Int = 0, val needsPassword: Boolean = false,
)

private const val CASCADE = ForeignKey.CASCADE

@Entity(tableName = "category", indices = [Index("sourceId", "kind", name = "category_source_kind")],
    foreignKeys = [ForeignKey(SourceEntity::class, ["id"], ["sourceId"], onDelete = CASCADE)])
data class CategoryEntity(@PrimaryKey val id: String, val sourceId: String, val kind: String, val name: String, val providerOrder: Int)

@Entity(tableName = "categoryPref")
data class CategoryPrefEntity(@PrimaryKey val categoryId: String, val isHidden: Boolean = false, val alias: String? = null, val sortIndex: Int? = null)

@Entity(tableName = "channel",
    indices = [Index("sourceId", "providerOrder", name = "channel_source"), Index("categoryId", "providerOrder", name = "channel_category"),
        Index("epgKey", name = "channel_epgKey"), Index("normalizedName", name = "channel_normalized"), Index("tvgId", name = "channel_tvgId")],
    foreignKeys = [ForeignKey(SourceEntity::class, ["id"], ["sourceId"], onDelete = CASCADE)])
data class ChannelEntity(
    @PrimaryKey val id: String, val sourceId: String, val categoryId: String?, val name: String, val normalizedName: String, val number: Int?,
    val providerOrder: Int, val logoURL: String?, val tvgId: String?, val streamURL: String, val providerStreamId: String?,
    val catchupType: String?, val catchupSource: String?, val catchupDays: Int?, val userAgent: String?, val referrer: String?,
    val isAdult: Boolean = false, val epgKey: String?,
)

@Entity(tableName = "channelPref")
data class ChannelPrefEntity(
    @PrimaryKey val channelId: String, val isFavorite: Boolean = false, val favoriteOrder: Int? = null, val isHidden: Boolean = false,
    val alias: String? = null, val epgIdOverride: String? = null,
)

/** A channel row with its user state (LEFT JOIN channelPref). */
data class ChannelRow(
    val id: String, val sourceId: String, val categoryId: String?, val name: String, val number: Int?, val providerOrder: Int,
    val logoURL: String?, val tvgId: String?, val streamURL: String, val providerStreamId: String?, val catchupType: String?,
    val catchupSource: String?, val catchupDays: Int?, val userAgent: String?, val referrer: String?, val isAdult: Boolean, val epgKey: String?,
    val isFavorite: Boolean?, val favoriteOrder: Int?, val isHidden: Boolean?, val alias: String?, val epgIdOverride: String?,
)

@Entity(tableName = "movie", indices = [Index("categoryId", name = "movie_category"), Index("sourceId", name = "movie_source")],
    foreignKeys = [ForeignKey(SourceEntity::class, ["id"], ["sourceId"], onDelete = CASCADE)])
data class MovieEntity(
    @PrimaryKey val id: String, val sourceId: String, val categoryId: String?, val name: String, val year: String?, val posterURL: String?,
    val backdropURL: String?, val providerId: String, val containerExtension: String?, val streamURL: String, val rating: Double?,
    val plot: String?, val genre: String?, val cast: String?, val director: String?, val releaseDate: String?, val durationSeconds: Int?,
    val addedAt: Double?, val providerOrder: Int, val trailer: String?, val tmdbId: String?,
)

@Entity(tableName = "series", indices = [Index("categoryId", name = "series_category"), Index("sourceId", name = "series_source")],
    foreignKeys = [ForeignKey(SourceEntity::class, ["id"], ["sourceId"], onDelete = CASCADE)])
data class SeriesEntity(
    @PrimaryKey val id: String, val sourceId: String, val categoryId: String?, val name: String, val year: String?, val coverURL: String?,
    val backdropURL: String?, val providerId: String, val rating: Double?, val plot: String?, val genre: String?, val cast: String?,
    val director: String?, val releaseDate: String?, val addedAt: Double?, val lastModified: Double?, val providerOrder: Int,
    val trailer: String?, val streamURL: String = "",
)

@Entity(tableName = "episode", indices = [Index("seriesId", "season", "number", name = "episode_series")],
    foreignKeys = [ForeignKey(SourceEntity::class, ["id"], ["sourceId"], onDelete = CASCADE)])
data class EpisodeEntity(
    @PrimaryKey val id: String, val seriesId: String, val sourceId: String, val season: Int, val number: Int, val title: String,
    val plot: String?, val imageURL: String?, val durationSeconds: Int?, val providerId: String, val containerExtension: String?,
    val streamURL: String, val airDate: String?,
)

@Entity(tableName = "watchProgress", indices = [Index("updatedAt", name = "watchProgress_updated"), Index("seriesId", name = "watchProgress_series")])
data class WatchProgressEntity(
    @PrimaryKey val mediaId: String, val kind: String, val sourceId: String, val seriesId: String?, val title: String, val subtitle: String?,
    val posterURL: String?, val position: Double, val duration: Double, val completed: Boolean = false, val updatedAt: Long,
)

@Entity(tableName = "vodFavorite")
data class VodFavoriteEntity(@PrimaryKey val mediaId: String, val kind: String, val addedAt: Long)

@Entity(tableName = "history")
data class HistoryEntity(@PrimaryKey val channelId: String, val watchedAt: Long)

@Entity(tableName = "mediaMetadata")
data class MediaMetadataEntity(@PrimaryKey val mediaId: String, val kind: String, val json: String?, val notFound: Boolean = false, val fetchedAt: Long)

@Entity(tableName = "skipSegmentCache")
data class SkipSegmentCacheEntity(@PrimaryKey val mediaId: String, val json: String, val fetchedAt: Long)
