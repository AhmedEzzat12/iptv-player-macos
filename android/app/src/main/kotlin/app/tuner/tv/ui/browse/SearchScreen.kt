package app.tuner.tv.ui.browse

import app.tuner.tv.ui.PillButton
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.platform.LocalFocusManager
import app.tuner.core.models.RecentSearches
import androidx.tv.material3.OutlinedButton
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.layout.Arrangement
import app.tuner.tv.ui.PageTitle
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import app.tuner.core.models.Channel
import app.tuner.core.models.Movie
import app.tuner.core.models.Program
import app.tuner.core.models.Series
import app.tuner.data.Library
import app.tuner.tv.app
import app.tuner.tv.ui.PlaybackItem
import app.tuner.tv.ui.PosterCard
import app.tuner.tv.ui.Shelf
import app.tuner.tv.ui.TunerColors
import app.tuner.tv.ui.WideCard
import app.tuner.tv.ui.initialFocus
import kotlinx.coroutines.delay

/**
 * Search: channels, what's on TV, movies and shows by name, 300 ms after typing stops. With nothing typed, the recent
 * searches show as chips. A search is remembered once a result from it is opened or played (as in the Apple apps),
 * and also, unlike them, when typed: on going down to the results, or after a pause with results.
 */
@Composable
fun SearchScreen(onPlay: (PlaybackItem) -> Unit, onOpenMovie: (String) -> Unit, onOpenSeries: (String) -> Unit, focusSidebar: () -> Unit = {}) {
    val app = LocalContext.current.app
    val focusManager = LocalFocusManager.current
    // The field's value with its cursor (Left at the start of the text leaves the field for the sidebar).
    // Saveable (AppShell keeps each section's state): coming back from a result keeps the search and its results.
    var field by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
    val query = field.text
    fun used() { app.prefs.recentSearches = RecentSearches.remember(app.prefs.recentSearches, query) }
    fun typed() { app.prefs.recentSearches = RecentSearches.rememberTyped(app.prefs.recentSearches, query) }
    val play: (PlaybackItem) -> Unit = { used(); onPlay(it) }
    val openMovie: (String) -> Unit = { used(); onOpenMovie(it) }
    val openSeries: (String) -> Unit = { used(); onOpenSeries(it) }
    var channels by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var onTv by remember { mutableStateOf<List<Pair<Channel, Program>>>(emptyList()) }
    var movies by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var shows by remember { mutableStateOf<List<Series>>(emptyList()) }
    LaunchedEffect(query) {
        delay(300)
        if (query.isBlank()) { channels = emptyList(); onTv = emptyList(); movies = emptyList(); shows = emptyList(); return@LaunchedEffect }
        channels = app.library.channels(Library.ChannelScope.All, query, limit = 50)
        val progs = app.library.searchPrograms(query, limit = 40)
        val byKey = if (progs.isEmpty()) emptyMap() else app.library.channels(Library.ChannelScope.All).filter { it.epgKey != null }.associateBy { it.epgKey!! }
        onTv = progs.mapNotNull { p -> byKey[p.epgKey]?.let { it to p } }
        movies = app.library.movies(search = query, limit = 50)
        shows = app.library.series(search = query, limit = 50)
        // Typed and left alone with results: kept too, without opening anything (cancelled by more typing).
        if (channels.isNotEmpty() || onTv.isNotEmpty() || movies.isNotEmpty() || shows.isNotEmpty()) { delay(2500); typed() }
    }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Column(Modifier.padding(bottom = 24.dp)) {
                PageTitle("Search")
                Spacer(Modifier.height(12.dp))
                BasicTextField(field, { field = it }, singleLine = true, textStyle = TextStyle(color = Color.White, fontSize = 24.sp),
                    cursorBrush = SolidColor(TunerColors.accent),
                    modifier = Modifier.width(720.dp).initialFocus()
                        // A text field keeps Down for itself (it never moved on to the results): send it to the results.
                        .onPreviewKeyEvent { e ->
                            // and Left at the start of the text to the sidebar (the field kept Left for its cursor, so the only
                            // way out of Search was Back).
                            if (e.type != KeyEventType.KeyDown) false
                            else if (e.key == Key.DirectionDown) { typed(); focusManager.moveFocus(FocusDirection.Down); true }
                            else if (e.key == Key.DirectionLeft && field.selection.collapsed && field.selection.start == 0) { focusSidebar(); true }
                            else false
                        }
                        .background(TunerColors.surface, RoundedCornerShape(12.dp)).padding(16.dp))
            }
        }
        val recent = app.prefs.recentSearches
        if (query.isBlank() && recent.isNotEmpty()) {
            item {
                Column(Modifier.padding(bottom = 24.dp)) {
                    Text("Recent Searches", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(10.dp))
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(recent, key = { it }) { r -> PillButton(r, onClick = { field = TextFieldValue(r, TextRange(r.length)) }) }
                        item(key = "clear") { PillButton("Clear", onClick = { app.prefs.recentSearches = emptyList() }) }
                    }
                }
            }
        }
        item { Shelf("Channels", channels, { it.id }) { ch -> WideCard(ch.displayName, null, ch.logoURL, width = 220, fitImage = true) { play(PlaybackItem.Live(ch, channels)) } } }
        item {
            Shelf("On TV", onTv, { "${it.first.id}:${it.second.stableKey}" }) { (ch, p) ->
                WideCard(p.title, "${ch.displayName} · ${fmtClock(p.start)}–${fmtClock(p.end)}", p.iconURL ?: ch.logoURL,
                    progress = if (p.isLive()) p.progress() else null, fitImage = p.iconURL == null) {
                    play(PlaybackItem.Live(ch, listOf(ch)))
                }
            }
        }
        item { Shelf("Movies", movies, { it.id }) { m -> PosterCard(m.name, m.posterURL, m.year) { openMovie(m.id) } } }
        item { Shelf("TV Shows", shows, { it.id }) { s -> PosterCard(s.name, s.coverURL, s.year) { openSeries(s.id) } } }
    }
}
