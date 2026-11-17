// Android counterpart of Sources/TunerCore/Database/AppDatabase.swift @ 666f598: same table and column names
// (appendix B), Android's SQLite directly (no Room: less setup, prepared-statement bulk inserts).
package app.tuner.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** What changed, so screens reload (Swift's libraryRevision / userRevision / guideRevision). */
public enum class Change { LIBRARY, USER, GUIDE }

public class AppDatabase private constructor(context: Context, name: String?) :
    SQLiteOpenHelper(context, name, null, MIGRATIONS.size) {

    private val _changes = MutableSharedFlow<Change>(extraBufferCapacity = 16)
    public val changes: SharedFlow<Change> = _changes.asSharedFlow()

    internal fun changed(change: Change) {
        _changes.tryEmit(change)
    }

    init {
        // WAL explicitly: Android picks TRUNCATE on low-RAM devices, which includes many TV boxes.
        setWriteAheadLoggingEnabled(true)
    }

    override fun onConfigure(db: SQLiteDatabase) {
        db.setForeignKeyConstraintsEnabled(true)
        db.execSQL("PRAGMA synchronous = NORMAL")
        db.execSQL("PRAGMA temp_store = MEMORY")
        db.execSQL("PRAGMA cache_size = -32000")
    }

    override fun onCreate(db: SQLiteDatabase): Unit = onUpgrade(db, 0, MIGRATIONS.size)

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        for (v in oldVersion until newVersion) MIGRATIONS[v].forEach(db::execSQL)
    }

    public companion object {
        @Volatile private var instance: AppDatabase? = null

        public fun get(context: Context): AppDatabase =
            instance ?: synchronized(this) { instance ?: AppDatabase(context.applicationContext, "tuner.sqlite").also { instance = it } }

        /** In-memory database for tests. */
        public fun inMemory(context: Context): AppDatabase = AppDatabase(context, null)

        /** Append-only: never edit an old migration. Instants are epoch ms; programme start/end epoch seconds. */
        private val MIGRATIONS: List<List<String>> = listOf(
            listOf(
                """CREATE TABLE source (id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, url TEXT NOT NULL,
                    username TEXT, password TEXT, mac TEXT, epgURL TEXT, autoLoadEPG INTEGER NOT NULL DEFAULT 1,
                    extraEPGURLs TEXT NOT NULL DEFAULT '[]', epgTimeshiftHours REAL NOT NULL DEFAULT 0, userAgent TEXT,
                    backupURLs TEXT NOT NULL DEFAULT '[]', enabled INTEGER NOT NULL DEFAULT 1, includeLive INTEGER NOT NULL DEFAULT 1,
                    includeVOD INTEGER NOT NULL DEFAULT 1, refreshHours INTEGER, sortIndex INTEGER NOT NULL DEFAULT 0,
                    createdAt INTEGER NOT NULL, lastSyncedAt INTEGER, lastVODSyncedAt INTEGER, lastError TEXT, expiresAt INTEGER,
                    activeConnections INTEGER, maxConnections INTEGER, discoveredEPGURL TEXT, channelCount INTEGER NOT NULL DEFAULT 0,
                    movieCount INTEGER NOT NULL DEFAULT 0, seriesCount INTEGER NOT NULL DEFAULT 0, needsPassword INTEGER NOT NULL DEFAULT 0)""",
                """CREATE TABLE category (id TEXT PRIMARY KEY, sourceId TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, name TEXT NOT NULL, providerOrder INTEGER NOT NULL)""",
                "CREATE INDEX category_source_kind ON category(sourceId, kind)",
                "CREATE TABLE categoryPref (categoryId TEXT PRIMARY KEY, isHidden INTEGER NOT NULL DEFAULT 0, alias TEXT, sortIndex INTEGER)",
                """CREATE TABLE channel (id TEXT PRIMARY KEY, sourceId TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    categoryId TEXT, name TEXT NOT NULL, normalizedName TEXT NOT NULL, number INTEGER, providerOrder INTEGER NOT NULL,
                    logoURL TEXT, tvgId TEXT, streamURL TEXT NOT NULL, providerStreamId TEXT, catchupType TEXT, catchupSource TEXT,
                    catchupDays INTEGER, userAgent TEXT, referrer TEXT, isAdult INTEGER NOT NULL DEFAULT 0, epgKey TEXT)""",
                "CREATE INDEX channel_source ON channel(sourceId, providerOrder)",
                "CREATE INDEX channel_category ON channel(categoryId, providerOrder)",
                "CREATE INDEX channel_epgKey ON channel(epgKey)",
                "CREATE INDEX channel_normalized ON channel(normalizedName)",
                "CREATE INDEX channel_tvgId ON channel(tvgId)",
                """CREATE TABLE channelPref (channelId TEXT PRIMARY KEY, isFavorite INTEGER NOT NULL DEFAULT 0, favoriteOrder INTEGER,
                    isHidden INTEGER NOT NULL DEFAULT 0, alias TEXT, epgIdOverride TEXT)""",
                """CREATE TABLE movie (id TEXT PRIMARY KEY, sourceId TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE, categoryId TEXT,
                    name TEXT NOT NULL, year TEXT, posterURL TEXT, backdropURL TEXT, providerId TEXT NOT NULL, containerExtension TEXT,
                    streamURL TEXT NOT NULL, rating REAL, plot TEXT, genre TEXT, "cast" TEXT, director TEXT, releaseDate TEXT,
                    durationSeconds INTEGER, addedAt REAL, providerOrder INTEGER NOT NULL, trailer TEXT, tmdbId TEXT)""",
                "CREATE INDEX movie_category ON movie(categoryId)",
                "CREATE INDEX movie_source ON movie(sourceId)",
                "CREATE INDEX movie_order_added ON movie(addedAt IS NULL, addedAt DESC, providerOrder)",
                "CREATE INDEX movie_order_name ON movie(name COLLATE NOCASE)",
                "CREATE INDEX movie_order_rating ON movie(rating IS NULL, rating DESC, name COLLATE NOCASE)",
                """CREATE TABLE series (id TEXT PRIMARY KEY, sourceId TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE, categoryId TEXT,
                    name TEXT NOT NULL, year TEXT, coverURL TEXT, backdropURL TEXT, providerId TEXT NOT NULL, rating REAL, plot TEXT,
                    genre TEXT, "cast" TEXT, director TEXT, releaseDate TEXT, addedAt REAL, lastModified REAL,
                    providerOrder INTEGER NOT NULL, trailer TEXT, streamURL TEXT NOT NULL DEFAULT '')""",
                "CREATE INDEX series_category ON series(categoryId)",
                "CREATE INDEX series_source ON series(sourceId)",
                "CREATE INDEX series_order_added ON series(addedAt IS NULL, addedAt DESC, providerOrder)",
                "CREATE INDEX series_order_name ON series(name COLLATE NOCASE)",
                """CREATE TABLE episode (id TEXT PRIMARY KEY, seriesId TEXT NOT NULL, sourceId TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    season INTEGER NOT NULL, number INTEGER NOT NULL, title TEXT NOT NULL, plot TEXT, imageURL TEXT, durationSeconds INTEGER,
                    providerId TEXT NOT NULL, containerExtension TEXT, streamURL TEXT NOT NULL, airDate TEXT)""",
                "CREATE INDEX episode_series ON episode(seriesId, season, number)",
                """CREATE TABLE watchProgress (mediaId TEXT PRIMARY KEY, kind TEXT NOT NULL, sourceId TEXT NOT NULL, seriesId TEXT,
                    title TEXT NOT NULL, subtitle TEXT, posterURL TEXT, position REAL NOT NULL, duration REAL NOT NULL,
                    completed INTEGER NOT NULL DEFAULT 0, updatedAt INTEGER NOT NULL)""",
                "CREATE INDEX watchProgress_updated ON watchProgress(updatedAt)",
                "CREATE INDEX watchProgress_series ON watchProgress(seriesId)",
                "CREATE TABLE vodFavorite (mediaId TEXT PRIMARY KEY, kind TEXT NOT NULL, addedAt INTEGER NOT NULL)",
                "CREATE TABLE history (channelId TEXT PRIMARY KEY, watchedAt INTEGER NOT NULL)",
                """CREATE TABLE mediaMetadata (mediaId TEXT PRIMARY KEY, kind TEXT NOT NULL, json TEXT, notFound INTEGER NOT NULL DEFAULT 0,
                    fetchedAt INTEGER NOT NULL)""",
                "CREATE TABLE skipSegmentCache (mediaId TEXT PRIMARY KEY, json TEXT NOT NULL, fetchedAt INTEGER NOT NULL)",
            ),
        )
    }
}
