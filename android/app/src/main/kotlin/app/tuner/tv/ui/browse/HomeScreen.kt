package app.tuner.tv.ui.browse

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Info
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import app.tuner.core.metadata.MediaMetadata
import app.tuner.core.models.Channel
import app.tuner.core.models.ContinueWatchingItem
import app.tuner.core.models.MediaKind
import app.tuner.core.models.Movie
import app.tuner.core.models.Program
import app.tuner.core.models.Series
import app.tuner.core.models.SmartContinueWatching
import app.tuner.core.models.VODFormat
import app.tuner.core.models.VODItem
import app.tuner.data.Change
import app.tuner.data.Library
import app.tuner.data.VODSort
import app.tuner.tv.TunerApplication
import app.tuner.tv.app
import app.tuner.tv.ui.CardSize
import app.tuner.tv.ui.Eyebrow
import app.tuner.tv.ui.PageStart
import app.tuner.tv.ui.PillButton
import app.tuner.tv.ui.Placeholder
import app.tuner.tv.ui.PlaybackItem
import app.tuner.tv.ui.PosterCard
import app.tuner.tv.ui.Shelf
import app.tuner.tv.ui.TunerColors
import app.tuner.tv.ui.WideCard
import app.tuner.tv.ui.artworkLayer
import app.tuner.tv.ui.BackdropImage
import app.tuner.tv.ui.initialFocus
import coil3.compose.AsyncImage
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

/** A favourite (or recently watched) channel with what's on it now, for the On Now row. */
private data class OnNow(val channel: Channel, val program: Program?)

/**
 * Home, like the Apple TV app's: a full-screen hero rotating through recently added movies and shows (artwork behind
 * the whole page, title, details, Play and More Info), then rows that rise over the artwork as focus moves down:
 * Continue Watching (plays directly), On Now (favourite channels with the programme on), Recently Added Movies and
 * Shows, and Top Rated. Rows follow HomeView.swift; each is hidden when empty.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun HomeScreen(onPlay: (PlaybackItem) -> Unit, onOpenMovie: (String) -> Unit, onOpenSeries: (String) -> Unit, onAddPlaylist: () -> Unit) {
    val app = LocalContext.current.app
    val scope = rememberCoroutineScope()
    var cw by remember { mutableStateOf<List<ContinueWatchingItem>>(emptyList()) }
    var onNow by remember { mutableStateOf<List<OnNow>>(emptyList()) }
    var onNowFavorites by remember { mutableStateOf(true) }
    var movies by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var shows by remember { mutableStateOf<List<Series>>(emptyList()) }
    var topRated by remember { mutableStateOf<List<VODItem>>(emptyList()) }
    var hero by remember { mutableStateOf<List<VODItem>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var hasSources by remember { mutableStateOf(true) }
    var revision by remember { mutableIntStateOf(0) }
    var guideRevision by remember { mutableIntStateOf(0) }
    // Provider details and online metadata for the hero titles, fetched once per title (not on every reload).
    val heroDetails = remember { mutableStateMapOf<String, VODItem>() }
    val heroMeta = remember { mutableStateMapOf<String, MediaMetadata?>() }

    LaunchedEffect(Unit) { app.database.changes.collect { if (it == Change.GUIDE) guideRevision++ else revision++ } }
    LaunchedEffect(revision) {
        hasSources = app.library.sources().isNotEmpty()
        cw = app.library.continueWatching()
        movies = app.library.movies(limit = 24)
        shows = app.library.series(limit = 24)
        val rated = app.library.movies(sort = VODSort.RATING, limit = 20).map { VODItem.MovieItem(it) } +
            app.library.series(sort = VODSort.RATING, limit = 20).map { VODItem.SeriesItem(it) }
        topRated = rated.filter { it.rating != null }.sortedByDescending { it.rating }.take(20)
        hero = VODItem.heroPicks(movies, shows)
        loaded = true
    }
    // The guide changes every few minutes; only On Now follows it (the rest of Home doesn't reload for it).
    LaunchedEffect(revision, guideRevision) {
        val favorites = app.library.channels(Library.ChannelScope.Favorites, limit = 20)
        onNowFavorites = favorites.isNotEmpty()
        val channels = favorites.ifEmpty { app.library.channels(Library.ChannelScope.Recent, limit = 20) }
        val now = Instant.now()
        val programs = channels.mapNotNull { it.epgKey }.takeIf { it.isNotEmpty() }?.let { app.library.programs(it, now, now.plusSeconds(60)) }.orEmpty()
        onNow = channels.map { ch -> OnNow(ch, ch.epgKey?.let { programs[it] }?.firstOrNull { it.isLive(now) }) }
    }
    LaunchedEffect(hero.map { it.id }) { enrichHero(app, hero, heroDetails, heroMeta) }

    if (!hasSources) {
        LaunchedEffect(Unit) { onAddPlaylist() }
        return Placeholder("Add a playlist to get started.")
    }
    if (!loaded) return

    val heroItems = hero.map { heroDetails[it.id] ?: it }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val screen = maxHeight
        val list = rememberLazyListState()
        val scrolled by remember { derivedStateOf { list.firstVisibleItemIndex > 0 || list.firstVisibleItemScrollOffset > 60 } }
        var index by rememberSaveable { mutableIntStateOf(0) }
        var tick by remember { mutableIntStateOf(0) }
        val current = heroItems.getOrNull(index.coerceAtMost(heroItems.lastIndex.coerceAtLeast(0)))

        // Auto-advance every 8 s while the hero is on screen; any press on the hero restarts the wait.
        LaunchedEffect(index, tick, scrolled, heroItems.size) {
            if (heroItems.size < 2 || scrolled) return@LaunchedEffect
            delay(8000)
            index = (index + 1) % heroItems.size
        }

        if (current != null) HeroBackdrop(current, heroMeta[current.id], dimmed = scrolled)

        // Down to a row brings it up to the top with its title showing (as in the Apple TV app). The rows' own
        // horizontal lists keep the usual scrolling (`RowScrolling`).
        val rowScrolling = androidx.compose.foundation.gestures.LocalBringIntoViewSpec.current
        val pivot = with(LocalDensity.current) { 46.dp.toPx() }
        val homeScrolling = remember(pivot) { object : androidx.compose.foundation.gestures.BringIntoViewSpec {
            override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float = offset - pivot
        } }
        val rows = Modifier
        androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides homeScrolling) {
            // Room under the last row so it can come up to the top like the others.
            LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(bottom = 260.dp)) {
                item(key = "hero") {
                    // Back up to the hero: all the way to the top, after the button's own scroll (which would cancel it).
                    Box(Modifier.fillMaxWidth().height(if (current != null) screen * 0.80f else 90.dp)
                        .onFocusChanged { if (it.hasFocus) scope.launch { delay(150); list.animateScrollToItem(0) } }) {
                        if (current != null) {
                            HeroDetails(
                                current, heroMeta[current.id], Modifier.align(Alignment.BottomStart).padding(start = PageStart, bottom = 28.dp),
                                onPlay = { scope.launch { playTitle(app, current, onPlay) } },
                                onMore = { if (current.isMovie) onOpenMovie(current.mediaId) else onOpenSeries(current.mediaId) },
                                onNext = { if (heroItems.size > 1) index = (index + 1) % heroItems.size },
                                onInput = { tick++ },
                            )
                            if (heroItems.size > 1) HeroDots(heroItems.size, index, Modifier.align(Alignment.BottomEnd).padding(end = 48.dp, bottom = 44.dp))
                        } else {
                            Text("Home", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(start = PageStart, top = 27.dp))
                        }
                    }
                }
                item(key = "cw") {
                    RowScrolling(rowScrolling, rows) {
                        Shelf("Continue Watching", cw, { it.id }, startInset = PageStart, focusFirst = current == null) { item ->
                            WideCard(item.progress.title, item.progress.subtitle, item.progress.posterURL,
                                progress = if (item is ContinueWatchingItem.Resume) item.progress.fraction else null,
                                badge = if (item is ContinueWatchingItem.NextEpisode) "UP NEXT" else null) { scope.launch { playContinue(app, item, onPlay) } }
                        }
                    }
                }
                item(key = "onNow") {
                    RowScrolling(rowScrolling, rows) {
                        Shelf("On Now", onNow, { it.channel.id }, startInset = PageStart, note = if (onNowFavorites) "Favorites" else "Recently Watched",
                            focusFirst = current == null && cw.isEmpty()) { (ch, program) ->
                            WideCard(program?.title ?: ch.displayName,
                                if (program != null) "${ch.displayName} · ${fmtClock(program.start)}–${fmtClock(program.end)}" else ch.number?.let { "Channel $it" },
                                program?.iconURL ?: ch.logoURL, progress = program?.progress(), width = CardSize.WIDE,
                                fitImage = program?.iconURL == null, badge = "LIVE") {
                                onPlay(PlaybackItem.Live(ch, onNow.map { it.channel }))
                            }
                        }
                    }
                }
                item(key = "movies") {
                    RowScrolling(rowScrolling, rows) {
                        Shelf("Recently Added Movies", movies, { it.id }, startInset = PageStart, focusFirst = current == null && cw.isEmpty() && onNow.isEmpty()) { m ->
                            PosterCard(m.name, m.posterURL, m.year) { onOpenMovie(m.id) }
                        }
                    }
                }
                item(key = "shows") {
                    RowScrolling(rowScrolling, rows) { Shelf("Recently Added Shows", shows, { it.id }, startInset = PageStart) { s -> PosterCard(s.name, s.coverURL, s.year) { onOpenSeries(s.id) } } }
                }
                item(key = "top") {
                    RowScrolling(rowScrolling, rows) {
                        Shelf("Top Rated", topRated, { it.id }, startInset = PageStart) { t ->
                            PosterCard(t.title, t.posterURL, t.rating?.let { "★ ${VODFormat.rating(it)}" }) {
                                if (t.isMovie) onOpenMovie(t.mediaId) else onOpenSeries(t.mediaId)
                            }
                        }
                    }
                }
            }
        }
        // Cards scrolled past the first fade out under the rail rather than crowding its icons.
        Box(Modifier.width(PageStart - 4.dp).fillMaxHeight().background(Brush.horizontalGradient(0f to TunerColors.background, 0.6f to TunerColors.background.copy(alpha = 0.88f), 1f to TunerColors.background.copy(alpha = 0f))))
    }
}

/**
 * The hero's artwork behind the whole page (under the rail too): online fan art first, then the provider's backdrop;
 * with neither, the poster stands on the right. Fades left and bottom keep the text readable; once the rows are
 * scrolled up it dims, so cards read over it.
 *
 * Drawn once into an offscreen layer (`ArtworkLayer`): TV GPUs redraw the whole screen every frame, and the picture
 * with its three full-screen fades made every Home frame take 80–100 ms on the TCL TV, even when only a card's focus
 * moved. The dimming fades the cached layer over the page background instead of adding another full-screen fill.
 */
@Composable
private fun HeroBackdrop(item: VODItem, meta: MediaMetadata?, dimmed: Boolean) {
    val bg = TunerColors.background
    val dim by animateFloatAsState(if (dimmed) 0.78f else 0f, tween(400), label = "dim")
    // Each title's picture and fades get their own cached layer, so the 8-second crossfade only changes the two layers'
    // alpha; one layer around the crossfade had to be redrawn on every frame of it.
    Box(Modifier.fillMaxSize().graphicsLayer { alpha = 1f - dim }) {
        Crossfade(item.id to (meta?.backdropURL ?: item.backdropURL), animationSpec = tween(700), label = "backdrop") { (_, backdrop) ->
            Box(Modifier.artworkLayer()) {
                if (backdrop != null) {
                    BackdropImage(backdrop)
                } else (item.posterURL ?: meta?.posterURL)?.let { poster ->
                    AsyncImage(poster, null, Modifier.align(Alignment.TopEnd).padding(top = 40.dp, end = 72.dp).fillMaxHeight(0.62f)
                        .aspectRatio(2f / 3f).clip(RoundedCornerShape(14.dp)), contentScale = ContentScale.Crop)
                }
                Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to bg.copy(alpha = 0.92f), 0.45f to bg.copy(alpha = 0.55f), 0.8f to Color.Transparent)))
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.35f), 0.2f to Color.Transparent, 0.55f to Color.Transparent, 0.9f to bg)))
            }
        }
    }
}

/** The hero's text and buttons. Right from More Info shows the next title (the Apple TV app's swipe). */
@Composable
private fun HeroDetails(item: VODItem, meta: MediaMetadata?, modifier: Modifier, onPlay: () -> Unit, onMore: () -> Unit, onNext: () -> Unit, onInput: () -> Unit) {
    var tookFocus by rememberSaveable { mutableStateOf(false) }
    Column(modifier.widthIn(max = 560.dp)) {
        AnimatedContent(item.id, transitionSpec = { (fadeIn(tween(500)) + slideInVertically(tween(500)) { it / 12 }) togetherWith fadeOut(tween(250)) }, label = "hero") { _ ->
            Column {
                Text(item.kindLabel.uppercase(), style = Eyebrow, color = TunerColors.secondary)
                Spacer(Modifier.height(10.dp))
                if (meta?.logoURL != null) {
                    AsyncImage(meta.logoURL, item.title, Modifier.height(96.dp).widthIn(max = 400.dp), contentScale = ContentScale.Fit, alignment = Alignment.BottomStart)
                } else {
                    Text(item.title, style = MaterialTheme.typography.displaySmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                val line = item.metadataLine.ifEmpty { meta?.let { m -> listOfNotNull(m.year, m.genres.take(2).joinToString(", ").ifEmpty { null }).joinToString(" · ") }.orEmpty() }
                if (line.isNotEmpty()) {
                    Spacer(Modifier.height(10.dp))
                    Text(line, style = MaterialTheme.typography.bodyLarge, color = Color.White.copy(alpha = 0.85f), maxLines = 1)
                }
                (item.plot ?: meta?.overview)?.takeIf { it.isNotBlank() }?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(it, style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.8f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        Spacer(Modifier.height(20.dp))
        Row(Modifier.focusGroup().onPreviewKeyEvent { if (it.type == KeyEventType.KeyDown) onInput(); false }, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            PillButton("Play", icon = Icons.Filled.PlayArrow, onClick = onPlay,
                modifier = if (!tookFocus) Modifier.initialFocus().onFocusChanged { if (it.hasFocus) tookFocus = true } else Modifier)
            PillButton("More Info", icon = Icons.Outlined.Info, onClick = onMore, modifier = Modifier.onPreviewKeyEvent {
                if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionRight) { onNext(); true } else false
            })
        }
    }
}

/** Page dots: the current title's dot is a wider white pill. */
@Composable
private fun HeroDots(count: Int, index: Int, modifier: Modifier) {
    Row(modifier.background(Color.Black.copy(alpha = 0.3f), CircleShape).padding(horizontal = 10.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(count) { i ->
            val width by animateDpAsState(if (i == index) 18.dp else 6.dp, tween(300), label = "dot")
            Box(Modifier.width(width).height(6.dp).background(Color.White.copy(alpha = if (i == index) 1f else 0.45f), CircleShape))
        }
    }
}

/**
 * Hero titles without a backdrop or plot get the provider's details (Xtream `get_vod_info`), and every title its
 * online metadata (logo, fan art), side by side; each fades in as it arrives (HomeView.enrichHero/loadHeroMetadata).
 */
private suspend fun enrichHero(app: TunerApplication, hero: List<VODItem>, details: MutableMap<String, VODItem>, meta: MutableMap<String, MediaMetadata?>) = coroutineScope {
    hero.map { item ->
        async {
            if (item is VODItem.MovieItem && item.id !in details && (item.backdropURL == null || item.plot == null)) {
                val m = item.movie
                runCatching { app.sync.movieDetails(m) }.getOrNull()?.let { d ->
                    details[item.id] = VODItem.MovieItem(m.copy(backdropURL = d.backdropURL?.ifEmpty { null } ?: m.backdropURL,
                        posterURL = d.posterURL?.ifEmpty { null } ?: m.posterURL, plot = d.plot?.ifEmpty { null } ?: m.plot,
                        genre = d.genre?.ifEmpty { null } ?: m.genre, rating = d.rating?.takeIf { it > 0 } ?: m.rating,
                        releaseDate = d.releaseDate?.ifEmpty { null } ?: m.releaseDate))
                }
            }
            if (item.id !in meta) meta[item.id] = runCatching {
                when (item) { is VODItem.MovieItem -> app.metadata.metadata(item.movie); is VODItem.SeriesItem -> app.metadata.metadata(item.series) }
            }.getOrNull()
        }
    }.awaitAll()
}

/** Play from the hero: a movie resumes where it was left; a show plays the episode its page would offer first. */
private suspend fun playTitle(app: TunerApplication, item: VODItem, onPlay: (PlaybackItem) -> Unit) {
    when (item) {
        is VODItem.MovieItem -> {
            val p = app.library.progress(item.movie.id)
            onPlay(PlaybackItem.MovieItem(item.movie, p?.takeIf { !it.completed && it.position > 10 }?.position))
        }
        is VODItem.SeriesItem -> {
            val s = item.series
            val episodes = app.library.episodes(s.id).ifEmpty { runCatching { app.sync.episodes(s) }.getOrDefault(emptyList()) }
            if (episodes.isEmpty()) return
            val progress = app.library.progress(s.id, forSeries = true)
            when (val next = SmartContinueWatching.rank(progress.values.toList(), mapOf(s.id to episodes), Instant.now(), 1).firstOrNull()) {
                is SmartContinueWatching.Entry.Resume -> episodes.firstOrNull { it.id == next.progress.mediaId }?.let { onPlay(PlaybackItem.EpisodeItem(it, s, episodes, next.progress.position)) }
                is SmartContinueWatching.Entry.NextEpisode -> episodes.firstOrNull { it.id == next.episode.id }?.let { onPlay(PlaybackItem.EpisodeItem(it, s, episodes)) }
                null -> {
                    val first = episodes.minWith(compareBy({ if (it.season == 0) Int.MAX_VALUE else it.season }, { it.number }))
                    onPlay(PlaybackItem.EpisodeItem(first, s, episodes))
                }
            }
        }
    }
}

/** Continue Watching plays directly: a resume point resumes, a next episode starts from the beginning. */
private suspend fun playContinue(app: TunerApplication, item: ContinueWatchingItem, onPlay: (PlaybackItem) -> Unit) {
    val p = item.progress
    if (p.kind == MediaKind.MOVIE) {
        app.library.movie(p.mediaId)?.let { onPlay(PlaybackItem.MovieItem(it, p.position.takeIf { pos -> pos > 10 })) }
    } else {
        val series = p.seriesId?.let { app.library.seriesItem(it) } ?: return
        val episodes = app.library.episodes(series.id)
        val episode = (item as? ContinueWatchingItem.NextEpisode)?.episode?.let { e -> episodes.firstOrNull { it.id == e.id } }
            ?: episodes.firstOrNull { it.id == p.mediaId } ?: return
        onPlay(PlaybackItem.EpisodeItem(episode, series, episodes, if (item is ContinueWatchingItem.Resume) p.position else null))
    }
}

/** Restores the usual scrolling for a row's own (horizontal) list inside Home's column. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun RowScrolling(spec: androidx.compose.foundation.gestures.BringIntoViewSpec, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides spec) {
        Box(modifier) { content() }
    }
}
