package app.tuner.tv.ui.browse

import app.tuner.tv.ui.PageTitle
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import app.tuner.core.models.Channel
import app.tuner.core.models.ContinueWatchingItem
import app.tuner.core.models.MediaKind
import app.tuner.core.models.Movie
import app.tuner.core.models.Series
import androidx.compose.ui.unit.dp
import androidx.compose.ui.focus.onFocusChanged
import app.tuner.data.Change
import app.tuner.data.Library
import app.tuner.tv.app
import app.tuner.tv.ui.PlaybackItem
import app.tuner.tv.ui.Placeholder
import app.tuner.tv.ui.PosterCard
import app.tuner.tv.ui.Shelf
import app.tuner.tv.ui.WideCard
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope

/** Home (first slice): Continue Watching (plays directly), favourite channels, recently added movies and shows. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun HomeScreen(onPlay: (PlaybackItem) -> Unit, onOpenMovie: (String) -> Unit, onOpenSeries: (String) -> Unit, onAddPlaylist: () -> Unit) {
    val app = LocalContext.current.app
    val scope = rememberCoroutineScope()
    var cw by remember { mutableStateOf<List<ContinueWatchingItem>>(emptyList()) }
    var favorites by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var movies by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var shows by remember { mutableStateOf<List<Series>>(emptyList()) }
    var hasSources by remember { mutableStateOf(true) }
    var revision by remember { mutableStateOf(0) }
    // Guide updates don't change Home (they came every few minutes and reloaded every row).
    LaunchedEffect(Unit) { app.database.changes.collect { if (it != Change.GUIDE) revision++ } }
    LaunchedEffect(revision) {
        hasSources = app.library.sources().isNotEmpty()
        cw = app.library.continueWatching()
        favorites = app.library.channels(Library.ChannelScope.Favorites, limit = 30).ifEmpty { app.library.channels(Library.ChannelScope.Recent, limit = 20) }
        movies = app.library.movies(limit = 30)
        shows = app.library.series(limit = 30)
    }

    fun play(item: ContinueWatchingItem) = scope.launch {
        val p = item.progress
        if (p.kind == MediaKind.MOVIE) {
            app.library.movie(p.mediaId)?.let { onPlay(PlaybackItem.MovieItem(it, p.position.takeIf { pos -> pos > 10 })) }
        } else {
            val series = p.seriesId?.let { app.library.seriesItem(it) } ?: return@launch
            val episodes = app.library.episodes(series.id)
            val episode = (item as? ContinueWatchingItem.NextEpisode)?.episode?.let { e -> episodes.firstOrNull { it.id == e.id } }
                ?: episodes.firstOrNull { it.id == p.mediaId } ?: return@launch
            onPlay(PlaybackItem.EpisodeItem(episode, series, episodes, if (item is ContinueWatchingItem.Resume) p.position else null))
        }
    }

    if (!hasSources) {
        LaunchedEffect(Unit) { onAddPlaylist() }
        return Placeholder("Add a playlist to get started.")
    }
    // Down to another row brings it up to the top with its title showing (as in the Apple TV app); scrolling just
    // enough left the row above cut in half at the top of the screen. Rows inside keep the usual horizontal scrolling.
    val rowScrolling = androidx.compose.foundation.gestures.LocalBringIntoViewSpec.current
    val pivot = with(androidx.compose.ui.platform.LocalDensity.current) { 46.dp.toPx() }
    val homeScrolling = remember(pivot) { object : androidx.compose.foundation.gestures.BringIntoViewSpec {
        override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float = offset - pivot
    } }
    @OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
    androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides homeScrolling) {
    val list = androidx.compose.foundation.lazy.rememberLazyListState()
    // Room under the last row so it can come up to the top like the others (the list stopped at its end, leaving the
    // row above cut in half).
    LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 260.dp)) {
        item { PageTitle("Home") }
        item {
            // Back on the first row: all the way to the top, so the page title shows again. After the card's own
            // scroll, which would cancel this one.
            RowScrolling(rowScrolling, Modifier.onFocusChanged { if (it.hasFocus) scope.launch { kotlinx.coroutines.delay(200); list.animateScrollToItem(0) } }) {
                Shelf("Continue Watching", cw, { it.id }, focusFirst = true) { item ->
                    WideCard(item.progress.title, item.progress.subtitle, item.progress.posterURL,
                        progress = if (item is ContinueWatchingItem.Resume) item.progress.fraction else null) { play(item) }
                }
            }
        }
        item {
            RowScrolling(rowScrolling) {
                Shelf("Channels", favorites, { it.id }, focusFirst = cw.isEmpty()) { ch ->
                    WideCard(ch.displayName, ch.number?.let { "Channel $it" }, ch.logoURL, width = 220, fitImage = true) { onPlay(PlaybackItem.Live(ch, favorites)) }
                }
            }
        }
        item { RowScrolling(rowScrolling) { Shelf("Recently Added Movies", movies, { it.id }, focusFirst = cw.isEmpty() && favorites.isEmpty()) { m -> PosterCard(m.name, m.posterURL, m.year) { onOpenMovie(m.id) } } } }
        item { RowScrolling(rowScrolling) { Shelf("Recently Added Shows", shows, { it.id }) { s -> PosterCard(s.name, s.coverURL, s.year) { onOpenSeries(s.id) } } } }
    }
    }
}

/** Restores the usual scrolling for a row's own (horizontal) list inside Home's column. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun RowScrolling(spec: androidx.compose.foundation.gestures.BringIntoViewSpec, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides spec) {
        androidx.compose.foundation.layout.Box(modifier) { content() }
    }
}
