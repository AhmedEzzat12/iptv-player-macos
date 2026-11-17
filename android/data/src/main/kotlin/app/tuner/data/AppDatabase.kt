// Android counterpart of Sources/TunerCore/Database/AppDatabase.swift @ 666f598: Room with the same table and column
// names (appendix B). New schema changes are Room migrations; exported schemas live in data/schemas.
package app.tuner.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** What changed, so screens reload (Swift's libraryRevision / userRevision / guideRevision). */
public enum class Change { LIBRARY, USER, GUIDE }

@Database(
    version = 2,
    exportSchema = true,
    entities = [SourceEntity::class, CategoryEntity::class, CategoryPrefEntity::class, ChannelEntity::class, ChannelPrefEntity::class,
        MovieEntity::class, SeriesEntity::class, EpisodeEntity::class, WatchProgressEntity::class, VodFavoriteEntity::class,
        HistoryEntity::class, MediaMetadataEntity::class, SkipSegmentCacheEntity::class,
        EpgFeedEntity::class, EpgChannelEntity::class, ProgramEntity::class, CustomGroupEntity::class, CustomGroupMemberEntity::class],
)
public abstract class AppDatabase : RoomDatabase() {
    internal abstract fun sources(): SourceDao
    internal abstract fun library(): LibraryDao
    internal abstract fun user(): UserDao
    internal abstract fun caches(): CacheDao
    internal abstract fun guide(): GuideDao

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

        /**
         * Sort indexes Room can't declare (expressions, COLLATE), identical to the ORDER BY expressions in Library.
         * Room's check after a migration counts them as undeclared indexes and fails ("Migration didn't properly
         * handle: movie"), so every migration drops them first and onOpen, which runs after the check, recreates them.
         */
        private fun createSortIndexes(db: SupportSQLiteDatabase) {
            for (table in listOf("movie", "series")) {
                db.execSQL("CREATE INDEX IF NOT EXISTS ${table}_order_added ON $table(addedAt IS NULL, addedAt DESC, providerOrder)")
                db.execSQL("CREATE INDEX IF NOT EXISTS ${table}_order_name ON $table(name COLLATE NOCASE)")
                db.execSQL("CREATE INDEX IF NOT EXISTS ${table}_order_rating ON $table(rating IS NULL, rating DESC, name COLLATE NOCASE)")
            }
        }

        /** First step of every migration (see createSortIndexes). */
        private fun dropSortIndexes(db: SupportSQLiteDatabase) {
            for (table in listOf("movie", "series")) for (suffix in listOf("order_added", "order_name", "order_rating")) {
                db.execSQL("DROP INDEX IF EXISTS ${table}_$suffix")
            }
        }

        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                dropSortIndexes(db)
                db.execSQL("""CREATE TABLE IF NOT EXISTS `epgFeed` (`id` TEXT NOT NULL, `url` TEXT NOT NULL, `sourceId` TEXT, `priority` INTEGER NOT NULL, `lastFetchedAt` INTEGER, `lastError` TEXT, `channelCount` INTEGER NOT NULL, `programCount` INTEGER NOT NULL, PRIMARY KEY(`id`), FOREIGN KEY(`sourceId`) REFERENCES `source`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE)""")
                db.execSQL("CREATE INDEX IF NOT EXISTS `epgFeed_source` ON `epgFeed` (`sourceId`)")
                db.execSQL("""CREATE TABLE IF NOT EXISTS `epgChannel` (`key` TEXT NOT NULL, `feedId` TEXT NOT NULL, `xmltvId` TEXT NOT NULL, `displayName` TEXT NOT NULL, `normalizedName` TEXT NOT NULL, `iconURL` TEXT, `programCount` INTEGER NOT NULL, PRIMARY KEY(`key`), FOREIGN KEY(`feedId`) REFERENCES `epgFeed`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE)""")
                db.execSQL("CREATE INDEX IF NOT EXISTS `epgChannel_feed` ON `epgChannel` (`feedId`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `epgChannel_normalized` ON `epgChannel` (`normalizedName`)")
                db.execSQL("""CREATE TABLE IF NOT EXISTS `program` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `feedId` TEXT NOT NULL, `epgKey` TEXT NOT NULL, `start` INTEGER NOT NULL, `end` INTEGER NOT NULL, `title` TEXT NOT NULL, `subtitle` TEXT, `summary` TEXT, `category` TEXT, `iconURL` TEXT, `episode` TEXT, FOREIGN KEY(`feedId`) REFERENCES `epgFeed`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE)""")
                db.execSQL("CREATE INDEX IF NOT EXISTS `program_epgKey_start` ON `program` (`epgKey`, `start`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `program_end` ON `program` (`end`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `program_feed` ON `program` (`feedId`)")
                db.execSQL("""CREATE TABLE IF NOT EXISTS `customGroup` (`id` TEXT NOT NULL, `name` TEXT NOT NULL, `sortIndex` INTEGER NOT NULL, PRIMARY KEY(`id`))""")
                db.execSQL("""CREATE TABLE IF NOT EXISTS `customGroupMember` (`groupId` TEXT NOT NULL, `channelId` TEXT NOT NULL, `sortIndex` INTEGER NOT NULL, PRIMARY KEY(`groupId`, `channelId`), FOREIGN KEY(`groupId`) REFERENCES `customGroup`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE)""")
                db.execSQL("CREATE INDEX IF NOT EXISTS `customGroupMember_group` ON `customGroupMember` (`groupId`)")
            }
        }

        private fun build(builder: Builder<AppDatabase>): AppDatabase = builder
            .addMigrations(MIGRATION_1_2)
            // WAL explicitly: Room's automatic mode picks TRUNCATE on low-RAM devices, which includes many TV boxes.
            .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)
            .addCallback(object : Callback() {
                override fun onOpen(db: SupportSQLiteDatabase) {
                    createSortIndexes(db)
                    db.query("PRAGMA synchronous = NORMAL").close()
                    db.query("PRAGMA temp_store = MEMORY").close()
                    db.query("PRAGMA cache_size = -32000").close()
                }
            })
            .build()
    }
}
