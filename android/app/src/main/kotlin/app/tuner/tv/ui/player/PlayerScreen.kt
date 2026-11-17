package app.tuner.tv.ui.player

import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import app.tuner.core.models.EndOfMediaStall
import app.tuner.core.models.EpisodeNavigation
import app.tuner.core.models.MediaKind
import app.tuner.core.models.Program
import app.tuner.core.models.UpNextCountdown
import app.tuner.core.models.WatchProgress
import app.tuner.core.net.HttpClient
import app.tuner.core.providers.XtreamURLs
import app.tuner.data.PlayableStream
import app.tuner.tv.app
import app.tuner.tv.ui.PlaybackItem
import app.tuner.tv.ui.TunerColors
import app.tuner.tv.ui.browse.fmtClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * Full-screen player (appendix C, first slice): ExoPlayer with per-stream headers; Xtream live asked as TS, retried as
 * M3U8 once; resume and progress saving as PlayerSlot.saveProgress; channel up/down; ±10 s seeks; Up Next for episodes;
 * a stall within 15 s of the end counts as the end. mpv fallback, tracks menu and Skip Intro come next.
 */
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(initial: PlaybackItem, onClose: () -> Unit) {
    val context = LocalContext.current
    val app = context.app
    val scope = rememberCoroutineScope()
    var item by remember { mutableStateOf(initial) }
    var message by remember { mutableStateOf<String?>(null) }
    var chromeVisible by remember { mutableStateOf(true) }
    var lastInput by remember { mutableIntStateOf(0) }
    var position by remember { mutableDoubleStateOf(0.0) }
    var duration by remember { mutableDoubleStateOf(0.0) }
    var buffering by remember { mutableStateOf(true) }
    var upNext by remember { mutableStateOf<Int?>(null) }
    var triedM3U8 by remember { mutableStateOf(false) }
    var liveNow by remember { mutableStateOf<Program?>(null) }
    var liveNext by remember { mutableStateOf<Program?>(null) }

    /** Now/next for the live chrome; reloaded when the current programme ends while watching. */
    suspend fun loadLiveGuide(channel: app.tuner.core.models.Channel) {
        val key = channel.epgKey ?: return
        val now = Instant.now()
        val progs = app.library.programs(listOf(key), now, now.plusSeconds(6 * 3600))[key].orEmpty()
        liveNow = progs.firstOrNull { it.isLive(now) }
        liveNext = progs.firstOrNull { !it.start.isBefore(liveNow?.end ?: now) && it != liveNow }
    }

    val focus = remember { FocusRequester() }

    val player = remember {
        ExoPlayer.Builder(context, DefaultRenderersFactory(context).setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON))
            .build().apply { playWhenReady = true }
    }

    fun mediaSource(stream: PlayableStream): MediaSource {
        val factory = OkHttpDataSource.Factory(HttpClient.shared).setUserAgent(stream.userAgent)
            .setDefaultRequestProperties(stream.referrer?.let { mapOf("Referer" to it) } ?: emptyMap())
        val mediaItem = MediaItem.fromUri(stream.url)
        val path = stream.url.substringBefore('?').lowercase()
        return if (path.endsWith(".m3u8") || path.contains("/hls/")) {
            HlsMediaSource.Factory(factory).setAllowChunklessPreparation(true).createMediaSource(mediaItem)
        } else {
            // IPTV TS often starts mid-GOP.
            val extractors = DefaultExtractorsFactory().setTsExtractorFlags(
                DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES or DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS)
            ProgressiveMediaSource.Factory(factory, extractors).createMediaSource(mediaItem)
        }
    }

    suspend fun saveProgress(completed: Boolean = false) {
        val d = player.duration.takeIf { it != C.TIME_UNSET && it > 0 }?.div(1000.0) ?: return
        val p = if (completed) d else player.currentPosition / 1000.0
        if (p <= 5 && !completed) return
        val record = when (val it = item) {
            is PlaybackItem.MovieItem -> WatchProgress(it.movie.id, MediaKind.MOVIE, it.movie.sourceId, title = it.movie.name,
                subtitle = it.movie.year, posterURL = it.movie.backdropURL ?: it.movie.posterURL, position = p, duration = d)
            is PlaybackItem.EpisodeItem -> WatchProgress(it.episode.id, MediaKind.EPISODE, it.episode.sourceId, seriesId = it.series.id,
                title = it.series.name, subtitle = "S${it.episode.season}, E${it.episode.number} · ${it.episode.title}",
                posterURL = it.episode.imageURL ?: it.series.backdropURL ?: it.series.coverURL, position = p, duration = d)
            is PlaybackItem.Live, is PlaybackItem.Catchup -> return
        }
        app.library.saveProgress(record)
    }

    suspend fun load(target: PlaybackItem, format: XtreamURLs.LiveFormat = XtreamURLs.LiveFormat.TS) {
        message = null
        buffering = true
        upNext = null
        liveNow = null
        liveNext = null
        player.stop() // close the old stream first: single-connection accounts refuse a second one
        try {
            val stream = when (target) {
                is PlaybackItem.Live -> {
                    loadLiveGuide(target.channel)
                    app.resolver.live(target.channel, format).also { app.library.recordWatched(target.channel.id) }
                }
                is PlaybackItem.Catchup -> app.resolver.catchup(target.channel, target.program).also { app.library.recordWatched(target.channel.id) }
                is PlaybackItem.MovieItem -> app.resolver.movie(target.movie)
                is PlaybackItem.EpisodeItem -> app.resolver.episode(target.episode)
            }
            val startAt = when (target) {
                is PlaybackItem.MovieItem -> target.startAt
                is PlaybackItem.EpisodeItem -> target.startAt
                is PlaybackItem.Live, is PlaybackItem.Catchup -> null
            }
            player.setMediaSource(mediaSource(stream))
            player.prepare()
            if (startAt != null && startAt > 10) player.seekTo((startAt * 1000).toLong())
            player.playWhenReady = true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            message = e.message ?: "This stream couldn't be opened"
            buffering = false
        }
    }

    fun switchTo(target: PlaybackItem, completedCurrent: Boolean = false) {
        scope.launch {
            saveProgress(completed = completedCurrent)
            item = target
            triedM3U8 = false
            load(target)
        }
    }

    fun zap(offset: Int) {
        val live = item as? PlaybackItem.Live ?: return
        val list = live.list.ifEmpty { listOf(live.channel) }
        val i = list.indexOfFirst { it.id == live.channel.id }.coerceAtLeast(0)
        switchTo(live.copy(channel = list[(i + offset).mod(list.size)]))
        chromeVisible = true
        lastInput++
    }

    fun nextEpisode(offset: Int, completedCurrent: Boolean = false): Boolean {
        val ep = item as? PlaybackItem.EpisodeItem ?: return false
        val next = EpisodeNavigation.neighbor(ep.episode.id, ep.episodes, offset) ?: return false
        switchTo(ep.copy(episode = next, startAt = null), completedCurrent = completedCurrent)
        return true
    }

    DisposableEffect(Unit) {
        val window = (context as? android.app.Activity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                buffering = state == Player.STATE_BUFFERING
                if (state == Player.STATE_ENDED) scope.launch {
                    saveProgress(completed = true)
                    if (!nextEpisode(1)) onClose()
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                val live = item as? PlaybackItem.Live
                // Xtream live is asked as TS first; retry once as HLS before giving up (docs/android-parity.md).
                if (live != null && !triedM3U8 && live.channel.providerStreamId != null) {
                    triedM3U8 = true
                    scope.launch { load(live, XtreamURLs.LiveFormat.M3U8) }
                    return
                }
                val status = (error.cause as? androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException)?.responseCode
                message = when (status) {
                    401, 403 -> "The provider refused this stream ($status). Check the account or its connection limit."
                    404 -> "The provider doesn't have this stream (404)."
                    503 -> "The provider has no playable copy of this title right now (503)."
                    null -> "Playback failed: ${error.errorCodeName}"
                    else -> "The provider answered with an error ($status)."
                }
            }
        }
        player.addListener(listener)
        onDispose {
            player.removeListener(listener)
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            player.release()
        }
    }

    LaunchedEffect(Unit) {
        load(item)
        focus.requestFocus()
    }

    // 0.5 s poll: time, progress saving (≤ every 9 s), Up Next, end-of-media stall.
    LaunchedEffect(Unit) {
        var ticks = 0
        var lastPos = -1.0
        var stalledSince = System.currentTimeMillis()
        while (true) {
            delay(500)
            ticks++
            position = player.currentPosition / 1000.0
            duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 }?.div(1000.0) ?: 0.0
            if (ticks % 18 == 0) saveProgress()
            (item as? PlaybackItem.Live)?.let { live ->
                val endsAt = liveNow?.end ?: liveNext?.start
                if (endsAt != null && !endsAt.isAfter(Instant.now())) loadLiveGuide(live.channel)
            }
            if (item !is PlaybackItem.Live && duration > 0) {
                if (item is PlaybackItem.EpisodeItem) upNext = UpNextCountdown.secondsLeft(position, duration, 10)
                if (position != lastPos || !player.playWhenReady) { lastPos = position; stalledSince = System.currentTimeMillis() }
                if (player.playWhenReady && EndOfMediaStall.hasEnded(position, duration, (System.currentTimeMillis() - stalledSince) / 1000.0)) {
                    saveProgress(completed = true)
                    if (!nextEpisode(1)) onClose()
                    stalledSince = System.currentTimeMillis()
                }
            }
        }
    }

    // Chrome auto-hides after 5 s while playing.
    LaunchedEffect(lastInput, chromeVisible) {
        if (chromeVisible) {
            delay(5000)
            if (player.isPlaying) chromeVisible = false
        }
    }

    BackHandler {
        if (chromeVisible && player.isPlaying) chromeVisible = false
        else scope.launch { saveProgress(); onClose() }
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black).focusRequester(focus).focusable()
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                lastInput++
                val live = item is PlaybackItem.Live
                when (event.nativeKeyEvent.keyCode) {
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                        if (upNext != null) { nextEpisode(1, completedCurrent = true) } else if (!live && chromeVisible) player.playWhenReady = !player.playWhenReady
                        chromeVisible = !chromeVisible || !player.playWhenReady; true
                    }
                    KeyEvent.KEYCODE_CHANNEL_UP, KeyEvent.KEYCODE_PAGE_UP -> { if (live) zap(-1) else nextEpisode(1); true }
                    KeyEvent.KEYCODE_CHANNEL_DOWN, KeyEvent.KEYCODE_PAGE_DOWN -> { if (live) zap(1) else nextEpisode(-1); true }
                    KeyEvent.KEYCODE_DPAD_UP -> { if (live) { zap(-1); true } else { chromeVisible = true; true } }
                    KeyEvent.KEYCODE_DPAD_DOWN -> { if (live) { zap(1); true } else { chromeVisible = true; true } }
                    KeyEvent.KEYCODE_DPAD_LEFT -> { if (!live) { player.seekTo((player.currentPosition - 10_000).coerceAtLeast(0)); chromeVisible = true }; true }
                    KeyEvent.KEYCODE_DPAD_RIGHT -> { if (!live) { player.seekTo(player.currentPosition + 10_000); chromeVisible = true }; true }
                    KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { if (!live) player.seekTo(player.currentPosition + 30_000); true }
                    KeyEvent.KEYCODE_MEDIA_REWIND -> { if (!live) player.seekTo((player.currentPosition - 30_000).coerceAtLeast(0)); true }
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> { player.playWhenReady = !player.playWhenReady; chromeVisible = true; true }
                    KeyEvent.KEYCODE_MEDIA_PLAY -> { player.playWhenReady = true; true }
                    KeyEvent.KEYCODE_MEDIA_PAUSE -> { player.playWhenReady = false; chromeVisible = true; true }
                    KeyEvent.KEYCODE_MEDIA_NEXT -> { if (live) zap(1) else nextEpisode(1); true }
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { if (live) zap(-1) else nextEpisode(-1); true }
                    else -> false
                }
            },
    ) {
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    useController = false
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                    this.player = player
                    setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
                }
            },
            modifier = Modifier.fillMaxSize(),
        )

        if (chromeVisible || message != null) Chrome(item, position, duration, buffering, player.playWhenReady, liveNow, liveNext)

        message?.let {
            Box(Modifier.align(Alignment.Center).background(TunerColors.surface.copy(alpha = 0.92f), androidx.compose.foundation.shape.RoundedCornerShape(16.dp)).padding(28.dp)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(it, style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(8.dp))
                    Text("Press Back to close" + if (item is PlaybackItem.Live) ", or change channel" else "", color = Color.White.copy(alpha = 0.7f))
                }
            }
        }

        upNext?.let { seconds ->
            Box(Modifier.align(Alignment.BottomEnd).padding(end = 56.dp, bottom = if (chromeVisible) 136.dp else 48.dp)
                .background(TunerColors.surface.copy(alpha = 0.95f), androidx.compose.foundation.shape.RoundedCornerShape(14.dp)).padding(20.dp)) {
                Text("Up Next in $seconds s · press OK to play now", style = MaterialTheme.typography.titleSmall)
            }
        }
    }
}

@Composable
private fun Chrome(
    item: PlaybackItem,
    position: Double,
    duration: Double,
    buffering: Boolean,
    playing: Boolean,
    liveNow: Program?,
    liveNext: Program?,
) {
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.85f))))
                .padding(start = 56.dp, end = 56.dp, bottom = 40.dp, top = 60.dp),
        ) {
            Text(item.title, style = MaterialTheme.typography.headlineMedium)
            item.subtitle?.let { Text(it, color = Color.White.copy(alpha = 0.7f)) }
            if (item is PlaybackItem.Live && liveNow != null) {
                Spacer(Modifier.height(6.dp))
                Text("${liveNow.title}  ·  ${fmtClock(liveNow.start)}–${fmtClock(liveNow.end)}" +
                    (liveNext?.let { "   ·   Next: ${it.title}" } ?: ""), color = Color.White.copy(alpha = 0.82f))
                Spacer(Modifier.height(6.dp))
                Box(Modifier.fillMaxWidth().height(4.dp).background(Color.White.copy(alpha = 0.25f))) {
                    Box(Modifier.fillMaxWidth(liveNow.progress().toFloat()).height(4.dp).background(TunerColors.accent))
                }
            }
            Spacer(Modifier.height(14.dp))
            if (item is PlaybackItem.Live) {
                Text(if (buffering) "Loading…" else "LIVE  ·  ▲▼ change channel", color = TunerColors.accent)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(if (buffering) "…" else if (playing) "▶" else "❚❚", style = MaterialTheme.typography.titleMedium)
                    Text(time(position))
                    Box(Modifier.weight(1f).height(5.dp).background(Color.White.copy(alpha = 0.25f))) {
                        if (duration > 0) Box(Modifier.fillMaxWidth((position / duration).toFloat().coerceIn(0f, 1f)).height(5.dp).background(TunerColors.accent))
                    }
                    Text(if (duration > 0) "-" + time(duration - position) else "")
                }
            }
        }
    }
}

private fun time(seconds: Double): String {
    val s = seconds.toLong().coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}
