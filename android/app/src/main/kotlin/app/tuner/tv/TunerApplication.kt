package app.tuner.tv

import android.app.Application
import app.tuner.core.metadata.MetadataService
import app.tuner.core.skip.SkipSegmentService
import app.tuner.data.AppDatabase
import app.tuner.data.Library
import app.tuner.data.StreamResolver
import app.tuner.data.SyncService
import app.tuner.tv.ui.ScreenMemory
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
    val metadata by lazy { MetadataService(library).apply { onLookup = { android.util.Log.i("Metadata", it) } } }
    val prefs by lazy { Prefs(this) }
    /** A title to play, from Google TV's Continue watching row (see WatchNext). */
    val playRequests = kotlinx.coroutines.flow.MutableStateFlow<android.net.Uri?>(null)
    val skips by lazy { SkipSegmentService(library.skipCache) }
    /** What each screen last showed, so coming back to it draws at once (see ScreenMemory). */
    val screens = ScreenMemory()

    /** Posters and logos dominate memory on TV boxes: a bounded memory cache. */
    override fun newImageLoader(context: PlatformContext): ImageLoader = ImageLoader.Builder(context)
        .memoryCache { MemoryCache.Builder().maxSizePercent(context, 0.15).build() }
        .crossfade(true)
        .build()
}

val android.content.Context.app: TunerApplication get() = applicationContext as TunerApplication
