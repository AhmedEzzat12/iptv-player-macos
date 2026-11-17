package app.tuner.tv.ui.browse

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

/** Search: channels, movies and shows by name, 300 ms after typing stops. */
@Composable
fun SearchScreen(onPlay: (PlaybackItem) -> Unit, onOpenMovie: (String) -> Unit, onOpenSeries: (String) -> Unit) {
    val app = LocalContext.current.app
    var query by remember { mutableStateOf("") }
    var channels by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var movies by remember { mutableStateOf<List<Movie>>(emptyList()) }
    var shows by remember { mutableStateOf<List<Series>>(emptyList()) }
    LaunchedEffect(query) {
        delay(300)
        if (query.isBlank()) { channels = emptyList(); movies = emptyList(); shows = emptyList(); return@LaunchedEffect }
        channels = app.library.channels(Library.ChannelScope.All, query, limit = 50)
        movies = app.library.movies(search = query, limit = 50)
        shows = app.library.series(search = query, limit = 50)
    }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Column(Modifier.padding(bottom = 24.dp)) {
                PageTitle("Search")
                Spacer(Modifier.height(12.dp))
                BasicTextField(query, { query = it }, singleLine = true, textStyle = TextStyle(color = Color.White, fontSize = 24.sp),
                    cursorBrush = SolidColor(TunerColors.accent),
                    modifier = Modifier.width(720.dp).initialFocus().background(TunerColors.surface, RoundedCornerShape(12.dp)).padding(16.dp))
            }
        }
        item { Shelf("Channels", channels, { it.id }) { ch -> WideCard(ch.displayName, null, ch.logoURL, width = 220, fitImage = true) { onPlay(PlaybackItem.Live(ch, channels)) } } }
        item { Shelf("Movies", movies, { it.id }) { m -> PosterCard(m.name, m.posterURL, m.year) { onOpenMovie(m.id) } } }
        item { Shelf("TV Shows", shows, { it.id }) { s -> PosterCard(s.name, s.coverURL, s.year) { onOpenSeries(s.id) } } }
    }
}
