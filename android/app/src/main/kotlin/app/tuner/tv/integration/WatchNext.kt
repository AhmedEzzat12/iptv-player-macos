package app.tuner.tv.integration

import android.annotation.SuppressLint
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import app.tuner.core.models.ContinueWatchingItem
import app.tuner.core.models.MediaKind
import app.tuner.tv.MainActivity
import app.tuner.tv.TunerApplication
import app.tuner.tv.ui.PlaybackItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Google TV's "Continue watching" row (Watch Next): the app's own Continue Watching items, kept in step after every
 * playback and at launch. Each entry opens the player at its resume point (an explicit intent to MainActivity, so
 * the right build answers when several are installed). Entries the viewer removed from the row stay removed until
 * the title is watched again.
 */
object WatchNext {
    private const val TAG = "WatchNext"
    private const val LIMIT = 10
    private val lock = Mutex()

    /** `antenna:movie/<id>` or `antenna:episode/<seriesId>/<id>`; carried as the intent's data. */
    fun link(kind: MediaKind, mediaId: String, seriesId: String?): Uri =
        if (kind == MediaKind.MOVIE) Uri.parse("antenna:movie/" + Uri.encode(mediaId))
        else Uri.parse("antenna:episode/" + Uri.encode(seriesId ?: "") + "/" + Uri.encode(mediaId))

    suspend fun sync(app: TunerApplication) = lock.withLock {
        withContext(Dispatchers.IO) {
            runCatching { syncNow(app) }.onFailure { Log.w(TAG, "Watch Next update failed: ${it.javaClass.simpleName}") }
            // The app's own row follows the same moments (launch, after playback).
            runCatching { HomeChannel.syncNow(app, app.library.continueWatching(LIMIT)) }
                .onFailure { Log.w(TAG, "Home channel update failed: ${it.javaClass.simpleName}") }
        }
    }

    @SuppressLint("RestrictedApi")
    private suspend fun syncNow(app: TunerApplication) {
        val resolver = app.contentResolver
        val wanted = app.library.continueWatching(LIMIT)
        // Our existing rows: internal provider id → (row id, still shown, last engagement).
        data class Row(val id: Long, val browsable: Boolean, val engaged: Long)
        val existing = HashMap<String, Row>()
        resolver.query(TvContractCompat.WatchNextPrograms.CONTENT_URI, WatchNextProgram.PROJECTION, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val p = WatchNextProgram.fromCursor(c)
                val key = p.internalProviderId ?: continue
                existing[key] = Row(p.id, p.isBrowsable, p.lastEngagementTimeUtcMillis)
            }
        }
        val keep = HashSet<String>()
        var inserted = 0
        var refused = 0
        for (item in wanted) {
            val p = item.progress
            keep += p.mediaId
            val engaged = p.updatedAt.toEpochMilli()
            val old = existing[p.mediaId]
            // Removed from the row by the viewer: leave it out until they watch it again.
            if (old != null && !old.browsable && old.engaged >= engaged) continue
            Log.d(TAG, "entry ${link(p.kind, p.mediaId, p.seriesId)}")
            val program = program(app, item).build()
            if (old == null || !old.browsable) {
                if (old != null) resolver.delete(TvContractCompat.buildWatchNextProgramUri(old.id), null, null)
                if (resolver.insert(TvContractCompat.WatchNextPrograms.CONTENT_URI, program.toContentValues()) == null) refused++ else inserted++
            } else {
                resolver.update(TvContractCompat.buildWatchNextProgramUri(old.id), program.toContentValues(), null, null)
            }
        }
        for ((key, row) in existing) {
            if (key !in keep) resolver.delete(ContentUris.withAppendedId(TvContractCompat.WatchNextPrograms.CONTENT_URI, row.id), null, null)
        }
        Log.i(TAG, "Watch Next: ${wanted.size} items, ${existing.size} existing, $inserted added, $refused refused")
    }

    @SuppressLint("RestrictedApi")
    private fun program(context: Context, item: ContinueWatchingItem): WatchNextProgram.Builder {
        val p = item.progress
        val episode = p.kind != MediaKind.MOVIE
        val intent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(link(p.kind, p.mediaId, p.seriesId))
        return WatchNextProgram.Builder()
            .setType(if (episode) TvContractCompat.PreviewPrograms.TYPE_TV_EPISODE else TvContractCompat.PreviewPrograms.TYPE_MOVIE)
            .setWatchNextType(
                if (item is ContinueWatchingItem.NextEpisode) TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_NEXT
                else TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE,
            )
            .setLastEngagementTimeUtcMillis(p.updatedAt.toEpochMilli())
            .setTitle(p.title)
            .apply { p.subtitle?.let { setEpisodeTitle(it) } }
            .apply { p.posterURL?.let { setPosterArtUri(Uri.parse(it)) } }
            .setPosterArtAspectRatio(if (episode) TvContractCompat.PreviewPrograms.ASPECT_RATIO_16_9 else TvContractCompat.PreviewPrograms.ASPECT_RATIO_2_3)
            .setLastPlaybackPositionMillis(if (item is ContinueWatchingItem.Resume) (p.position * 1000).toInt() else 0)
            .setDurationMillis((p.duration * 1000).toInt())
            .setInternalProviderId(p.mediaId)
            .setIntent(intent)
    }

    /** What a Watch Next (or home channel) link plays (null when the title is gone from the library). */
    suspend fun resolve(app: TunerApplication, uri: Uri): PlaybackItem? {
        if (uri.scheme != "antenna") return null
        val parts = uri.schemeSpecificPart.split('/').map { Uri.decode(it) }
        return when (parts.firstOrNull()) {
            "movie" -> {
                val movie = app.library.movie(parts.getOrNull(1) ?: return null) ?: return null
                val at = app.library.progress(movie.id)?.takeIf { !it.completed }?.position?.takeIf { it > 10 }
                PlaybackItem.MovieItem(movie, if (app.prefs.resumePlayback) at else null)
            }
            "episode" -> {
                val series = app.library.seriesItem(parts.getOrNull(1) ?: return null) ?: return null
                val episodes = app.library.episodes(series.id)
                val episode = episodes.firstOrNull { it.id == parts.getOrNull(2) } ?: return null
                val at = app.library.progress(episode.id)?.takeIf { !it.completed }?.position?.takeIf { it > 10 }
                PlaybackItem.EpisodeItem(episode, series, episodes, if (app.prefs.resumePlayback) at else null)
            }
            else -> null
        }
    }
}
