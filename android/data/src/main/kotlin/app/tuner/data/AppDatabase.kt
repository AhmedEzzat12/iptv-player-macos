// Android counterpart of Sources/TunerCore/Database/AppDatabase.swift @ 666f598: Room with the same table and column
// names (appendix B). New schema changes are Room migrations; exported schemas live in data/schemas.
package app.tuner.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** What changed, so screens reload (Swift's libraryRevision / userRevision / guideRevision). */
public enum class Change { LIBRARY, USER, GUIDE }

@Database(
    version = 1,
    exportSchema = true,
    entities = [SourceEntity::class, CategoryEntity::class, CategoryPrefEntity::class, ChannelEntity::class, ChannelPrefEntity::class,
        MovieEntity::class, SeriesEntity::class, EpisodeEntity::class, WatchProgressEntity::class, VodFavoriteEntity::class,
        HistoryEntity::class, MediaMetadataEntity::class, SkipSegmentCacheEntity::class],
)
public abstract class AppDatabase : RoomDatabase() {
    internal abstract fun sources(): SourceDao
    internal abstract fun library(): LibraryDao
    internal abstract fun user(): UserDao
    internal abstract fun caches(): CacheDao

    private val _changes = MutableSharedFlow<Change>(extraBufferCapacity = 16)
    public val changes: SharedFlow<Change> get() = _changes.asSharedFlow()

    internal fun changed(change: Change) {
        _changes.tryEmit(change)
    }

    public companion object {
        @Volatile private var instance: AppDatabase? = null

        public fun get(context: Context): AppDatabase = instance ?: synchronized(this) {
            instance ?: build(Room.databaseBuilder(context.applicationContext, AppDatabase::class.java, "tuner.sqlite")).also { instance = it }
        }

        /** In-memory database for tests. */
        public fun inMemory(context: Context): AppDatabase = build(Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java))

        private fun build(builder: Builder<AppDatabase>): AppDatabase = builder
            // WAL explicitly: Room's automatic mode picks TRUNCATE on low-RAM devices, which includes many TV boxes.
            .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)
            .addCallback(object : Callback() {
                override fun onCreate(db: SupportSQLiteDatabase) {
                    // Expression indexes (Room can't declare them); identical to the ORDER BY expressions in Library.
                    for (table in listOf("movie", "series")) {
                        db.execSQL("CREATE INDEX ${table}_order_added ON $table(addedAt IS NULL, addedAt DESC, providerOrder)")
                        db.execSQL("CREATE INDEX ${table}_order_name ON $table(name COLLATE NOCASE)")
                        db.execSQL("CREATE INDEX ${table}_order_rating ON $table(rating IS NULL, rating DESC, name COLLATE NOCASE)")
                    }
                }

                override fun onOpen(db: SupportSQLiteDatabase) {
                    db.query("PRAGMA synchronous = NORMAL").close()
                    db.query("PRAGMA temp_store = MEMORY").close()
                    db.query("PRAGMA cache_size = -32000").close()
                }
            })
            .build()
    }
}
