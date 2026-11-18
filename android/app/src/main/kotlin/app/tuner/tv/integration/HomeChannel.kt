package app.tuner.tv.integration

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.tvprovider.media.tv.ChannelLogoUtils
import androidx.tvprovider.media.tv.PreviewChannel
import androidx.tvprovider.media.tv.PreviewChannelHelper
import androidx.tvprovider.media.tv.PreviewProgram
import androidx.tvprovider.media.tv.TvContractCompat
import app.tuner.core.models.ContinueWatchingItem
import app.tuner.core.models.MediaKind
import app.tuner.tv.MainActivity
import app.tuner.tv.R
import app.tuner.tv.TunerApplication
import app.tuner.tv.ui.Page

/**
 * The app's own row on the TV's home screen (a preview channel): Up Next and Continue Watching first, then recently
 * added shows and movies. The first channel an app makes is its default one, which the launcher shows without
 * asking. Where it appears depends on the launcher (Android TV: on Home; Google TV: under the app). Titles play from
 * their resume point; shows and movies open their page (`antenna:open/series/<id>`, `antenna:open/movie/<id>`).
 */
object HomeChannel {
    private const val TAG = "HomeChannel"
    private const val SHOWS = 12
    private const val MOVIES = 8

    /** The page an `antenna:open/…` link opens (null for anything else). */
    fun page(uri: Uri): Page? {
        if (uri.scheme != "antenna") return null
        val parts = uri.schemeSpecificPart.split('/').map { Uri.decode(it) }
        if (parts.firstOrNull() != "open") return null
        val id = parts.getOrNull(2)?.takeIf { it.isNotEmpty() } ?: return null
        return when (parts.getOrNull(1)) {
            "series" -> Page.SeriesDetail(id)
            "movie" -> Page.MovieDetail(id)
            else -> null
        }
    }

    private fun openLink(kind: String, id: String): Uri = Uri.parse("antenna:open/$kind/" + Uri.encode(id))

    /** Called from WatchNext.sync (same lock, IO dispatcher). */
    @SuppressLint("RestrictedApi")
    internal suspend fun syncNow(app: TunerApplication, watching: List<ContinueWatchingItem>) {
        val helper = PreviewChannelHelper(app)
        val channelId = channel(app, helper) ?: return
        val programs = buildList {
            for (item in watching) add(watchingProgram(app, channelId, item))
            for (s in app.library.series(limit = SHOWS)) {
                add(base(app, channelId, openLink("series", s.id), "series:" + s.id)
                    .setType(TvContractCompat.PreviewPrograms.TYPE_TV_SERIES).setTitle(s.name)
                    .apply { s.year?.let { setReleaseDate(it) } }
                    .apply { s.coverURL?.let { setPosterArtUri(Uri.parse(it)) } }
                    .setPosterArtAspectRatio(TvContractCompat.PreviewPrograms.ASPECT_RATIO_2_3).build())
            }
            for (m in app.library.movies(limit = MOVIES)) {
                add(base(app, channelId, openLink("movie", m.id), "movie:" + m.id)
                    .setType(TvContractCompat.PreviewPrograms.TYPE_MOVIE).setTitle(m.name)
                    .apply { m.year?.let { setReleaseDate(it) } }
                    .apply { m.posterURL?.let { setPosterArtUri(Uri.parse(it)) } }
                    .setPosterArtAspectRatio(TvContractCompat.PreviewPrograms.ASPECT_RATIO_2_3).build())
            }
        }.distinctBy { it.internalProviderId }
        // A couple of dozen rows: replacing them all is simpler than diffing and keeps the order right.
        app.contentResolver.delete(TvContractCompat.buildPreviewProgramsUriForChannel(channelId), null, null)
        var refused = 0
        for ((i, p) in programs.withIndex()) {
            val values = PreviewProgram.Builder(p).setWeight(programs.size - i).build().toContentValues()
            if (app.contentResolver.insert(TvContractCompat.PreviewPrograms.CONTENT_URI, values) == null) refused++
        }
        Log.i(TAG, "Home channel: ${programs.size} programs, $refused refused")
    }

    /** The channel's row id, creating it (with its logo) the first time; recreated if the viewer's system lost it. */
    @SuppressLint("RestrictedApi")
    private fun channel(app: TunerApplication, helper: PreviewChannelHelper): Long? {
        val saved = (app.prefs.homeChannelId.toLongOrNull() ?: 0L)
        if (saved > 0 && helper.getPreviewChannel(saved) != null) return saved
        val channel = PreviewChannel.Builder()
            .setDisplayName(app.getString(R.string.app_name))
            .setAppLinkIntent(Intent(app, MainActivity::class.java))
            .setInternalProviderId("home")
            .setLogo(logo(app))
            .build()
        val id = runCatching { helper.publishDefaultChannel(channel) }
            .onFailure { Log.w(TAG, "Couldn't publish the home channel: ${it.javaClass.simpleName}") }.getOrNull() ?: return null
        app.prefs.homeChannelId = id.toString()
        // The default channel shows without a prompt on launchers that honour the request.
        runCatching { TvContractCompat.requestChannelBrowsable(app, id) }
        runCatching { ChannelLogoUtils.storeChannelLogo(app, id, logo(app)) }
        return id
    }

    private fun logo(context: Context): Bitmap {
        val drawable = ContextCompat.getDrawable(context, R.drawable.ic_mark)!!
        val bitmap = Bitmap.createBitmap(160, 160, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, 160, 160)
        drawable.draw(Canvas(bitmap))
        return bitmap
    }

    @SuppressLint("RestrictedApi")
    private fun base(context: Context, channelId: Long, link: Uri, key: String): PreviewProgram.Builder =
        PreviewProgram.Builder()
            .setChannelId(channelId)
            .setInternalProviderId(key)
            .setIntent(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(link))

    @SuppressLint("RestrictedApi")
    private fun watchingProgram(context: Context, channelId: Long, item: ContinueWatchingItem): PreviewProgram {
        val p = item.progress
        val episode = p.kind != MediaKind.MOVIE
        return base(context, channelId, WatchNext.link(p.kind, p.mediaId, p.seriesId), "watch:" + p.mediaId)
            .setType(if (episode) TvContractCompat.PreviewPrograms.TYPE_TV_EPISODE else TvContractCompat.PreviewPrograms.TYPE_MOVIE)
            .setTitle(p.title)
            .apply { p.subtitle?.let { setEpisodeTitle(it) } }
            .apply { p.posterURL?.let { setPosterArtUri(Uri.parse(it)) } }
            .setPosterArtAspectRatio(if (episode) TvContractCompat.PreviewPrograms.ASPECT_RATIO_16_9 else TvContractCompat.PreviewPrograms.ASPECT_RATIO_2_3)
            .setLastPlaybackPositionMillis(if (item is ContinueWatchingItem.Resume) (p.position * 1000).toInt() else 0)
            .setDurationMillis((p.duration * 1000).toInt())
            .build()
    }
}
