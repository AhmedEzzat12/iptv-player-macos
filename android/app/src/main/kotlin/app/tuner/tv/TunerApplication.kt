package app.tuner.tv

import android.app.Application
import app.tuner.core.metadata.MetadataService
import app.tuner.core.skip.SkipSegmentService
import app.tuner.data.AppDatabase
import app.tuner.data.Library
import app.tuner.data.StreamResolver
import app.tuner.data.SyncService
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.memory.MemoryCache
import coil3.request.crossfade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** App-wide services (one database, one sync service), created once. */
class TunerApplication : Application(), SingletonImageLoader.Factory {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val database by lazy { AppDatabase.get(this) }
    val library by lazy { Library(database) }
    val sync by lazy { SyncService(library, cacheDir) }
    val resolver by lazy { StreamResolver(library, sync) }
    val metadata by lazy { MetadataService(library) }
    val prefs by lazy { Prefs(this) }
    val skips by lazy { SkipSegmentService(library.skipCache) }

    /** Posters and logos dominate memory on TV boxes: a bounded memory cache. */
    override fun newImageLoader(context: PlatformContext): ImageLoader = ImageLoader.Builder(context)
        .memoryCache { MemoryCache.Builder().maxSizePercent(context, 0.15).build() }
        .crossfade(true)
        .build()
}

val android.content.Context.app: TunerApplication get() = applicationContext as TunerApplication
