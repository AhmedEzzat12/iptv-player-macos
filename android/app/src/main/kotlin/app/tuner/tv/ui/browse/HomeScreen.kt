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
    LaunchedEffect(Unit) { app.database.changes.collect { revision++ } }
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
    LazyColumn(Modifier.fillMaxSize()) {
        item { PageTitle("Home") }
        item {
            Shelf("Continue Watching", cw, { it.id }, focusFirst = true) { item ->
                WideCard(item.progress.title, item.progress.subtitle, item.progress.posterURL,
                    progress = if (item is ContinueWatchingItem.Resume) item.progress.fraction else null) { play(item) }
            }
        }
        item {
            Shelf("Channels", favorites, { it.id }, focusFirst = cw.isEmpty()) { ch ->
                WideCard(ch.displayName, ch.number?.let { "Channel $it" }, ch.logoURL, width = 220) { onPlay(PlaybackItem.Live(ch, favorites)) }
            }
        }
        item { Shelf("Recently Added Movies", movies, { it.id }, focusFirst = cw.isEmpty() && favorites.isEmpty()) { m -> PosterCard(m.name, m.posterURL, m.year) { onOpenMovie(m.id) } } }
        item { Shelf("Recently Added Shows", shows, { it.id }) { s -> PosterCard(s.name, s.coverURL, s.year) { onOpenSeries(s.id) } } }
    }
}
