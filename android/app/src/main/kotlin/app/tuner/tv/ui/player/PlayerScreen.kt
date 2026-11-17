package app.tuner.tv.ui.player

import app.tuner.tv.integration.WatchNext
import app.tuner.core.services.LiveWatchdog
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import app.tuner.core.audio.SleepTimer
import app.tuner.core.skip.SkipMode
import app.tuner.core.skip.SkipSegment
import app.tuner.core.skip.SkipSegmentService
import app.tuner.core.skip.SkipSegments
import app.tuner.core.skip.SkipTracker
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
    // Options panel (audio, subtitles, picture, sleep timer) and Skip Intro/Credits.
    var optionsOpen by remember { mutableStateOf(false) }
    var tracks by remember { mutableStateOf(androidx.media3.common.Tracks.EMPTY) }
    var aspect by remember { mutableStateOf(VideoAspect.FIT) }
    var sleep by remember { mutableStateOf<SleepTimer?>(null) }
    var sleepRemaining by remember { mutableStateOf<Double?>(null) }
    val skipTracker = remember { SkipTracker() }
    var skipRaw by remember { mutableStateOf<List<SkipSegment>?>(null) }
    var skipApplied by remember { mutableStateOf(false) }
    var skipPrompt by remember { mutableStateOf<SkipTracker.Prompt?>(null) }
    // Live watchdog: a stalled stream fails over to the same channel in another playlist, else reconnects.
    val watchdog = remember { LiveWatchdog() }
    var originalChannel by remember { mutableStateOf<app.tuner.core.models.Channel?>(null) }
    val failoverTried = remember { HashSet<String>() }
    var recovering by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    // Seeking: Left/Right move a scrub target; playback jumps there when the keys pause (Apple TV style).
    var buffered by remember { mutableDoubleStateOf(0.0) }
    var scrubTo by remember { mutableStateOf<Double?>(null) }
    var scrubInput by remember { mutableIntStateOf(0) }
    var flash by remember { mutableStateOf<Boolean?>(null) }
    var flashKey by remember { mutableIntStateOf(0) }
    // OK acts on release, so holding it only opens the options (and doesn't first pause or skip).
    var okLongPressed by remember { mutableStateOf(false) }

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

    // Assistant ("pause", "resume"), remote media keys and the system's now-playing controls act on this player.
    val session = remember {
        androidx.media3.session.MediaSession.Builder(context, player).setId("antenna-player").apply {
            (context as? android.app.Activity)?.let { activity ->
                setSessionActivity(android.app.PendingIntent.getActivity(activity, 0,
                    android.content.Intent(activity, activity.javaClass).addFlags(android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    android.app.PendingIntent.FLAG_IMMUTABLE))
            }
        }.build()
    }

    fun mediaSource(stream: PlayableStream): MediaSource {
        val factory = OkHttpDataSource.Factory(HttpClient.shared).setUserAgent(stream.userAgent)
            .setDefaultRequestProperties(stream.referrer?.let { mapOf("Referer" to it) } ?: emptyMap())
        // Title and artwork for the system's now-playing UI (never the URL, which can hold the account).
        val meta = androidx.media3.common.MediaMetadata.Builder().setTitle(item.title).setArtist(item.subtitle).apply {
            when (val i = item) {
                is PlaybackItem.MovieItem -> i.movie.posterURL
                is PlaybackItem.EpisodeItem -> i.series.coverURL
                is PlaybackItem.Live -> i.channel.logoURL
                is PlaybackItem.Catchup -> i.channel.logoURL
            }?.let { setArtworkUri(android.net.Uri.parse(it)) }
        }.build()
        val mediaItem = MediaItem.Builder().setUri(stream.url).setMediaMetadata(meta).build()
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

    /** Intro/credits timings for a movie or episode (cached; looked up online by IMDb/TMDb id from its metadata). */
    fun loadSkipSegments(target: PlaybackItem) {
        val lookup: suspend () -> SkipSegmentService.Lookup? = when (target) {
            is PlaybackItem.MovieItem -> suspend {
                val meta = runCatching { app.metadata.metadata(target.movie) }.getOrNull()
                SkipSegmentService.Lookup(target.movie.id, meta?.imdbId, meta?.tmdbId ?: target.movie.tmdbId)
            }
            is PlaybackItem.EpisodeItem -> suspend {
                val meta = runCatching { app.metadata.metadata(target.series) }.getOrNull()
                SkipSegmentService.Lookup(target.episode.id, meta?.imdbId, meta?.tmdbId,
                    season = target.episode.season, episode = target.episode.number)
            }
            else -> return
        }
        scope.launch {
            val found = runCatching { lookup()?.let { app.skips.segments(it, allowNetwork = true) } }.getOrNull().orEmpty()
            if (item == target) skipRaw = found
        }
    }

    suspend fun load(target: PlaybackItem, requestedFormat: XtreamURLs.LiveFormat? = null, automatic: Boolean = false) {
        // Settings → Playback → Live stream format: TS first (HLS if it fails), or HLS only.
        if (requestedFormat == null && app.prefs.liveFormat == "hls") triedM3U8 = true
        val format = requestedFormat ?: if (triedM3U8) XtreamURLs.LiveFormat.M3U8 else XtreamURLs.LiveFormat.TS
        if (target is PlaybackItem.Live) {
            if (!automatic) { originalChannel = target.channel; failoverTried.clear(); failoverTried += target.channel.id; status = null }
            watchdog.started(System.currentTimeMillis() / 1000.0, isRetry = automatic)
        } else status = null
        message = null
        buffering = true
        upNext = null
        liveNow = null
        liveNext = null
        skipRaw = null
        skipApplied = false
        skipPrompt = null
        skipTracker.setSegments(emptyList())
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
            val startAt = if (!app.prefs.resumePlayback) null else when (target) {
                is PlaybackItem.MovieItem -> target.startAt
                is PlaybackItem.EpisodeItem -> target.startAt
                is PlaybackItem.Live, is PlaybackItem.Catchup -> null
            }
            loadSkipSegments(target)
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

    /** Live stream died: try the same channel in another playlist, else reconnect with backoff (PlayerSlot.streamDied). */
    fun streamDied(reason: String) {
        val live = item as? PlaybackItem.Live ?: return
        if (recovering) return
        recovering = true
        player.stop()
        scope.launch {
            try {
                val base = originalChannel ?: live.channel
                val alternates = if (!app.prefs.autoFailover) emptyList() else runCatching { app.library.alternateChannels(base) }.getOrDefault(emptyList())
                val next = (listOf(base) + alternates).firstOrNull { it.id !in failoverTried }
                if (next != null) {
                    failoverTried += next.id
                    status = "Switching to ${next.displayName}…"
                    item = live.copy(channel = next)
                    load(item, automatic = true)
                    return@launch
                }
                val attempt = watchdog.nextRetry()
                if (attempt > LiveWatchdog.MAX_RETRIES) {
                    status = null
                    message = "This channel isn't responding. ${reason.trimEnd('.')}."
                    return@launch
                }
                status = "Reconnecting ($attempt/${LiveWatchdog.MAX_RETRIES})…"
                buffering = true
                delay(watchdog.backoffSeconds(attempt) * 1000L)
                if (item !is PlaybackItem.Live) return@launch
                // Copies in other playlists get another chance after the reconnect; the channel itself isn't a "switch".
                failoverTried.clear()
                failoverTried += base.id
                item = live.copy(channel = base)
                load(item, automatic = true)
            } finally {
                recovering = false
            }
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
                // A live stream never ends: the connection dropped, so recover instead of closing.
                if (state == Player.STATE_ENDED && item is PlaybackItem.Live) { streamDied("The stream ended"); return }
                if (state == Player.STATE_ENDED) scope.launch {
                    saveProgress(completed = true)
                    if (sleep?.isEndOfItem == true || !app.prefs.autoplayNextEpisode || !nextEpisode(1)) onClose()
                }
            }

            override fun onTracksChanged(newTracks: androidx.media3.common.Tracks) { tracks = newTracks }

            override fun onPlayerError(error: PlaybackException) {
                val live = item as? PlaybackItem.Live
                // Xtream live is asked as TS first; retry once as HLS before giving up (docs/android-parity.md).
                if (live != null && !triedM3U8 && live.channel.providerStreamId != null) {
                    triedM3U8 = true
                    // An internal retry: keep the failover state (original channel, tried copies, attempt count).
                    scope.launch { load(live, XtreamURLs.LiveFormat.M3U8, automatic = true) }
                    return
                }
                val code = (error.cause as? androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException)?.responseCode
                // A dropped connection on live TV is worth reconnecting; a refusal from the provider isn't.
                if (live != null && code == null) { streamDied("Playback failed: ${error.errorCodeName}"); return }
                message = when (code) {
                    401, 403 -> "The provider refused this stream ($code). Check the account or its connection limit."
                    404 -> "The provider doesn't have this stream (404)."
                    503 -> "The provider has no playable copy of this title right now (503)."
                    null -> "Playback failed: ${error.errorCodeName}"
                    else -> "The provider answered with an error ($code)."
                }
            }
        }
        player.addListener(listener)
        onDispose {
            player.removeListener(listener)
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            session.release()
            player.release()
            // Google TV's Continue watching row follows what was just watched (after the last progress save).
            app.scope.launch { delay(1500); WatchNext.sync(app) }
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
            buffered = player.bufferedPosition / 1000.0
            if (ticks % 18 == 0) saveProgress()
            sleep?.let { timer ->
                val itemLeft = if (item is PlaybackItem.Live) liveNow?.end?.let { (it.toEpochMilli() - System.currentTimeMillis()) / 1000.0 }
                    else SleepTimer.itemTimeLeft(position, duration.takeIf { it > 0 }, player.playbackParameters.speed.toDouble())
                val left = timer.remaining(itemTimeLeft = itemLeft)
                sleepRemaining = left
                player.volume = SleepTimer.volumeFactor(left).toFloat()
                if (timer.shouldFire(left, isLive = item is PlaybackItem.Live)) {
                    sleep = null; sleepRemaining = null; player.volume = 1f
                    saveProgress(); onClose()
                }
            }
            skipRaw?.let { raw ->
                if (!skipApplied && duration > 0) { skipTracker.setSegments(SkipSegments.merge(raw, duration)); skipApplied = true }
                if (skipApplied) {
                    val (prompt, action) = skipTracker.update(position, duration, app.prefs.skipSegments, autoSkipCredits = false)
                    skipPrompt = prompt
                    if (action is SkipTracker.Action.AutoSkip) {
                        player.seekTo((action.segment.resolvedEnd(duration) * 1000).toLong())
                        status = when (action.segment.kind) { SkipSegment.Kind.CREDITS -> "Skipped credits"; SkipSegment.Kind.RECAP -> "Skipped recap"; else -> "Skipped intro" }
                    }
                } else skipPrompt = null
            }
            if (ticks % 2 == 0 && item is PlaybackItem.Live && message == null && !recovering) {
                val state = player.playbackState
                when (watchdog.tick(System.currentTimeMillis() / 1000.0, player.currentPosition / 1000.0, player.bufferedPosition / 1000.0,
                    ended = state == Player.STATE_ENDED, idle = state == Player.STATE_IDLE, paused = !player.playWhenReady)) {
                    LiveWatchdog.Result.DIED -> streamDied("Stream stopped responding")
                    LiveWatchdog.Result.RECOVERED -> status = null
                    LiveWatchdog.Result.OK -> if (status != null && state == Player.STATE_READY && player.isPlaying) status = null
                }
            }
            (item as? PlaybackItem.Live)?.let { live ->
                val endsAt = liveNow?.end ?: liveNext?.start
                if (endsAt != null && !endsAt.isAfter(Instant.now())) loadLiveGuide(live.channel)
            }
            if (item !is PlaybackItem.Live && duration > 0) {
                if (item is PlaybackItem.EpisodeItem) upNext = if (sleep?.isEndOfItem == true || !app.prefs.autoplayNextEpisode || app.prefs.upNextCountdown == 0) null
                    else UpNextCountdown.secondsLeft(position, duration, app.prefs.upNextCountdown)
                if (position != lastPos || !player.playWhenReady) { lastPos = position; stalledSince = System.currentTimeMillis() }
                if (player.playWhenReady && EndOfMediaStall.hasEnded(position, duration, (System.currentTimeMillis() - stalledSince) / 1000.0)) {
                    saveProgress(completed = true)
                    if (sleep?.isEndOfItem == true || !app.prefs.autoplayNextEpisode || !nextEpisode(1)) onClose()
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

    fun commitScrub() {
        val to = scrubTo ?: return
        scrubTo = null
        player.seekTo((to * 1000).toLong())
        skipTracker.userSeeked(to, duration.takeIf { it > 0 })
    }

    /** One scrub step; holding the key speeds up from 10 s to 30 s to 60 s steps. */
    fun scrub(direction: Int, repeat: Int, base: Long = 10) {
        val step = when { repeat < 5 -> base; repeat < 15 -> base * 3; else -> base * 6 }
        val from = scrubTo ?: position
        val max = if (duration > 0) duration - 1 else Double.MAX_VALUE
        scrubTo = (from + direction * step).coerceIn(0.0, max)
        chromeVisible = true
        scrubInput++
    }

    LaunchedEffect(scrubInput) {
        if (scrubTo != null) { delay(700); commitScrub() }
    }

    fun togglePlay() {
        player.playWhenReady = !player.playWhenReady
        flash = player.playWhenReady
        flashKey++
    }

    LaunchedEffect(flashKey) {
        if (flash != null) { delay(650); flash = null }
    }

    // A notice on a movie or episode ("Skipped intro") goes away by itself; live notices clear when playback resumes.
    LaunchedEffect(status) {
        if (status != null && item !is PlaybackItem.Live) { delay(3000); status = null }
    }

    fun okPressed() {
        lastInput++
        val live = item is PlaybackItem.Live
        val prompt = skipPrompt
        // Skip only when the button is on screen (it shows for a few seconds, then only with the controls).
        if (prompt != null && prompt.isFresh && !chromeVisible && upNext == null) {
            player.seekTo((prompt.segment.resolvedEnd(duration.takeIf { it > 0 }) * 1000).toLong())
            skipPrompt = null
            return
        }
        when {
            scrubTo != null -> commitScrub()
            upNext != null -> nextEpisode(1, completedCurrent = true)
            !live && chromeVisible -> togglePlay()
        }
        chromeVisible = !chromeVisible || !player.playWhenReady || scrubTo != null
    }

    BackHandler {
        if (optionsOpen) { optionsOpen = false; focus.requestFocus() }
        else if (chromeVisible && player.isPlaying) chromeVisible = false
        else scope.launch { saveProgress(); onClose() }
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black).focusRequester(focus).focusable()
            .onPreviewKeyEvent { event ->
                val ok = event.nativeKeyEvent.keyCode.let { it == KeyEvent.KEYCODE_DPAD_CENTER || it == KeyEvent.KEYCODE_ENTER }
                if (ok && event.type == KeyEventType.KeyUp) {
                    // The release that ends a long press (the panel is open by then) does nothing else.
                    if (okLongPressed) { okLongPressed = false; return@onPreviewKeyEvent true }
                    if (!optionsOpen) { okPressed(); return@onPreviewKeyEvent true }
                }
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                lastInput++
                // The panel's rows take the D-pad while it's open. Back closes it here: left to the panel, Compose would
                // only move focus out of it and keep it open.
                if (optionsOpen) {
                    if (event.nativeKeyEvent.keyCode != KeyEvent.KEYCODE_BACK) return@onPreviewKeyEvent false
                    optionsOpen = false
                    focus.requestFocus()
                    return@onPreviewKeyEvent true
                }
                val live = item is PlaybackItem.Live
                val code = event.nativeKeyEvent.keyCode
                val openOptions = code == KeyEvent.KEYCODE_MENU || code == KeyEvent.KEYCODE_INFO || code == KeyEvent.KEYCODE_CAPTIONS ||
                    ((code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER) && event.nativeKeyEvent.repeatCount == 1) ||
                    (code == KeyEvent.KEYCODE_DPAD_DOWN && !live && chromeVisible)
                if (openOptions) {
                    if (ok) okLongPressed = true
                    optionsOpen = true; chromeVisible = false; return@onPreviewKeyEvent true
                }
                // OK itself acts on release (see above).
                if (ok) return@onPreviewKeyEvent true
                when (code) {
                    KeyEvent.KEYCODE_CHANNEL_UP, KeyEvent.KEYCODE_PAGE_UP -> { if (live) zap(-1) else nextEpisode(1); true }
                    KeyEvent.KEYCODE_CHANNEL_DOWN, KeyEvent.KEYCODE_PAGE_DOWN -> { if (live) zap(1) else nextEpisode(-1); true }
                    KeyEvent.KEYCODE_DPAD_UP -> { if (live) { zap(-1); true } else { chromeVisible = true; true } }
                    KeyEvent.KEYCODE_DPAD_DOWN -> { if (live) { zap(1); true } else { chromeVisible = true; true } }
                    KeyEvent.KEYCODE_DPAD_LEFT -> { if (!live) scrub(-1, event.nativeKeyEvent.repeatCount); true }
                    KeyEvent.KEYCODE_DPAD_RIGHT -> { if (!live) scrub(1, event.nativeKeyEvent.repeatCount); true }
                    KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { if (!live) scrub(1, event.nativeKeyEvent.repeatCount, base = 30); true }
                    KeyEvent.KEYCODE_MEDIA_REWIND -> { if (!live) scrub(-1, event.nativeKeyEvent.repeatCount, base = 30); true }
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> { togglePlay(); chromeVisible = true; true }
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
            update = { it.resizeMode = aspect.resizeMode },
            modifier = aspect.frameRatio?.let { Modifier.align(Alignment.Center).fillMaxHeight().aspectRatio(it, matchHeightConstraintsFirst = true) }
                ?: Modifier.fillMaxSize(),
        )

        if (message == null && status == null) {
            PlayerCenterIndicator(buffering = buffering && scrubTo == null, paused = !player.playWhenReady && !buffering && flash == null && item !is PlaybackItem.Live)
        }
        flash?.let { PlayPauseFlash(it) }
        if ((chromeVisible || message != null) && !optionsOpen) PlayerChrome(item, position, duration, buffered, scrubTo, liveNow, liveNext)

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

        status?.let {
            Box(Modifier.align(Alignment.TopCenter).padding(top = 40.dp)
                .background(TunerColors.surface.copy(alpha = 0.92f), androidx.compose.foundation.shape.RoundedCornerShape(50)).padding(horizontal = 22.dp, vertical = 10.dp)) {
                Text(it, style = MaterialTheme.typography.titleSmall)
            }
        }

        // Like the Apple player: the button stays for a few seconds after entering an intro/credits, then only with
        // the controls showing.
        skipPrompt?.takeIf { (it.isFresh || chromeVisible) && upNext == null && !optionsOpen }?.let { prompt ->
            Box(Modifier.align(Alignment.BottomEnd).padding(end = 56.dp, bottom = if (chromeVisible) 136.dp else 48.dp)
                .background(Color.White, androidx.compose.foundation.shape.RoundedCornerShape(12.dp)).padding(horizontal = 22.dp, vertical = 14.dp)) {
                Text(if (prompt.segment.kind == SkipSegment.Kind.CREDITS) "Skip Credits" else if (prompt.segment.kind == SkipSegment.Kind.RECAP) "Skip Recap" else "Skip Intro",
                    color = Color.Black, style = MaterialTheme.typography.titleSmall)
            }
        }

        if (optionsOpen) {
            PlayerOptionsPanel(
                tracks = tracks, aspect = aspect, sleep = sleep, sleepRemaining = sleepRemaining,
                isLive = item is PlaybackItem.Live,
                onAudio = { player.selectTrack(it) },
                onSubtitle = { c -> if (c == null) player.subtitlesOff() else player.selectTrack(c) },
                onAspect = { aspect = it },
                onSleep = { o -> sleep = o?.let { SleepTimer(it) }; if (o == null) { sleepRemaining = null; player.volume = 1f } },
            )
        }
    }
}
