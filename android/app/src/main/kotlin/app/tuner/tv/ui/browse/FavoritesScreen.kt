package app.tuner.tv.ui.browse

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.tuner.core.models.Channel
import app.tuner.core.models.Movie
import app.tuner.core.models.Series
import app.tuner.data.Change
import app.tuner.data.Library
import app.tuner.tv.app
import app.tuner.tv.ui.CardSize
import app.tuner.tv.ui.ItemMenu
import app.tuner.tv.ui.MenuAction
import app.tuner.tv.ui.PageTitle
import app.tuner.tv.ui.Placeholder
import app.tuner.tv.ui.PlaybackItem
import app.tuner.tv.ui.PosterCard
import app.tuner.tv.ui.Shelf
import app.tuner.tv.ui.TitleMenu
import app.tuner.tv.ui.TitleRef
import app.tuner.tv.ui.WideCard
import app.tuner.tv.ui.rememberScreenState
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * The Favorites section: favourite channels (with what's on), movies and shows, one row each, newest favourite first.
 * On Apple the section is the guide filtered to favourite channels; here that guide is Live TV → Favorites, and this page
 * gathers every kind of favourite (docs/android-parity.md).
 */
@Composable
fun FavoritesScreen(onPlay: (PlaybackItem) -> Unit, onOpenMovie: (String) -> Unit, onOpenSeries: (String) -> Unit) {
    val app = LocalContext.current.app
    var channels by rememberScreenState("favorites.channels") { emptyList<OnNow>() }
    var movies by rememberScreenState("favorites.movies") { emptyList<Movie>() }
    var shows by rememberScreenState("favorites.shows") { emptyList<Series>() }
    var loaded by rememberScreenState("favorites.loaded") { false }
    var revision by remember { mutableIntStateOf(0) }
    var titleMenu by remember { mutableStateOf<TitleRef?>(null) }
    var channelMenu by remember { mutableStateOf<Channel?>(null) }

    LaunchedEffect(Unit) { app.database.changes.collect { revision++ } }
    LaunchedEffect(revision) {
        movies = app.library.favoriteMovies()
        shows = app.library.favoriteSeries()
        val favorites = app.library.channels(Library.ChannelScope.Favorites)
        val now = Instant.now()
        val programs = favorites.mapNotNull { it.epgKey }.takeIf { it.isNotEmpty() }?.let { app.library.programs(it, now, now.plusSeconds(60)) }.orEmpty()
        channels = favorites.map { ch -> OnNow(ch, ch.epgKey?.let { programs[it] }?.firstOrNull { it.isLive(now) }) }
        loaded = true
    }
    if (!loaded) return
    if (channels.isEmpty() && movies.isEmpty() && shows.isEmpty()) {
        return Placeholder("No favorites yet", "Hold OK on a channel, movie or show to add it.")
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 120.dp)) {
        item(key = "title") { PageTitle("Favorites") }
        item(key = "channels") {
            Shelf("Channels", channels, { it.channel.id }, focusFirst = true) { (ch, program) ->
                WideCard(program?.title ?: ch.displayName,
                    if (program != null) "${ch.displayName} · ${fmtClock(program.start)}–${fmtClock(program.end)}" else ch.number?.let { "Channel $it" },
                    program?.iconURL ?: ch.logoURL, progress = program?.progress(), width = CardSize.WIDE,
                    fitImage = program?.iconURL == null, badge = "LIVE", onLongClick = { channelMenu = ch }) {
                    onPlay(PlaybackItem.Live(ch, channels.map { it.channel }))
                }
            }
        }
        item(key = "movies") {
            Shelf("Movies", movies, { it.id }, focusFirst = channels.isEmpty()) { m ->
                PosterCard(m.name, m.posterURL, m.year, onLongClick = { titleMenu = TitleRef(m.id, m.name, false) }) { onOpenMovie(m.id) }
            }
        }
        item(key = "shows") {
            Shelf("TV Shows", shows, { it.id }, focusFirst = channels.isEmpty() && movies.isEmpty()) { s ->
                PosterCard(s.name, s.coverURL, s.year, onLongClick = { titleMenu = TitleRef(s.id, s.name, true) }) { onOpenSeries(s.id) }
            }
        }
    }
    titleMenu?.let { ref -> TitleMenu(ref, onOpen = { if (it.isSeries) onOpenSeries(it.id) else onOpenMovie(it.id) }) { titleMenu = null } }
    channelMenu?.let { ch ->
        ItemMenu(ch.displayName, listOf(
            MenuAction("Watch") { onPlay(PlaybackItem.Live(ch, channels.map { it.channel })) },
            MenuAction("Remove from Favorites") { app.scope.launch { app.library.setFavorite(ch.id, false) } },
        )) { channelMenu = null }
    }
}
