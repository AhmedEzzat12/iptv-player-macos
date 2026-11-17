package app.tuner.tv.ui.browse

import app.tuner.tv.ui.PageTitle
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Button
import androidx.tv.material3.FilterChip
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text
import app.tuner.core.metadata.MediaMetadata
import app.tuner.core.models.Category
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Episode
import app.tuner.core.models.Movie
import app.tuner.core.models.Series
import app.tuner.core.models.SmartContinueWatching
import app.tuner.core.models.WatchProgress
import app.tuner.data.Change
import app.tuner.tv.app
import app.tuner.tv.ui.PlaybackItem
import app.tuner.tv.ui.Placeholder
import app.tuner.tv.ui.PosterCard
import app.tuner.tv.ui.WideCard
import app.tuner.tv.ui.initialFocus
import androidx.compose.foundation.focusGroup
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch

/** Movies or TV Shows: category chips and a poster grid, paged 120 at a time. */
@Composable
fun VodGridScreen(kind: CategoryKind, onOpen: (String) -> Unit) {
    val app = LocalContext.current.app
    val scope = rememberCoroutineScope()
    var categories by remember { mutableStateOf<List<Category>>(emptyList()) }
    var selected by remember { mutableStateOf<String?>(null) }
    var items by remember { mutableStateOf<List<Triple<String, String, String?>>>(emptyList()) }
    var revision by remember { mutableStateOf(0) }
    var exhausted by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { app.database.changes.collect { if (it == Change.LIBRARY) revision++ } }
    LaunchedEffect(revision) { categories = app.library.categories(kind) }

    suspend fun page(offset: Int): List<Triple<String, String, String?>> =
        if (kind == CategoryKind.MOVIE) app.library.movies(selected, limit = 120, offset = offset).map { Triple(it.id, it.name, it.posterURL) }
        else app.library.series(selected, limit = 120, offset = offset).map { Triple(it.id, it.name, it.coverURL) }

    LaunchedEffect(selected, revision) {
        items = page(0)
        exhausted = items.size < 120
        // Stalker portals: a category's items load when it's first opened.
        val cat = categories.firstOrNull { it.id == selected }
        if (items.isEmpty() && cat != null) scope.launch { runCatching { app.sync.loadStalkerCategory(cat.sourceId, kind, cat.id) } }
    }

    Column(Modifier.fillMaxSize()) {
        PageTitle(if (kind == CategoryKind.MOVIE) "Movies" else "TV Shows")
        Spacer(Modifier.height(12.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
            item { FilterChip(selected = selected == null, onClick = { selected = null }, modifier = Modifier.initialFocus()) { Text("All") } }
            items(categories, key = { it.id }) { c -> FilterChip(selected = selected == c.id, onClick = { selected = c.id }) { Text(c.displayName) } }
        }
        Spacer(Modifier.height(12.dp))
        if (items.isEmpty()) {
            Placeholder(if (categories.isEmpty()) "Add a playlist with movies and shows in Settings." else "Nothing in this category.")
        } else {
            // Fixed cells: posters are the same 150 dp as on Home in every category (Adaptive stretched them).
            LazyVerticalGrid(GridCells.FixedSize(150.dp), horizontalArrangement = Arrangement.spacedBy(18.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp), contentPadding = PaddingValues(top = 12.dp, start = 6.dp, bottom = 48.dp, end = 4.dp)) {
                itemsIndexed(items, key = { _, it -> it.first }) { index, (id, name, image) ->
                    PosterCard(name, image, onClick = { onOpen(id) })
                    if (index == items.size - 1 && !exhausted) LaunchedEffect(items.size) {
                        val more = page(items.size)
                        exhausted = more.size < 120
                        items = items + more
                    }
                }
            }
        }
    }
}

/** Backdrop and title block shared by the movie and show pages (online metadata fills logo, backdrop and plot). */
@Composable
private fun Header(title: String, meta: MediaMetadata?, fallbackBackdrop: String?, details: String, plot: String?) {
    Box(Modifier.fillMaxWidth().height(380.dp)) {
        val backdrop = meta?.backdropURL ?: fallbackBackdrop
        if (backdrop != null) AsyncImage(backdrop, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.92f), Color.Transparent))))
        Column(Modifier.align(Alignment.BottomStart).width(760.dp).padding(bottom = 20.dp)) {
            if (meta?.logoURL != null) AsyncImage(meta.logoURL, title, Modifier.height(120.dp).width(420.dp), contentScale = ContentScale.Fit, alignment = Alignment.CenterStart)
            else Text(title, style = MaterialTheme.typography.displaySmall)
            Spacer(Modifier.height(8.dp))
            Text(details, color = Color.White.copy(alpha = 0.75f))
            (meta?.overview ?: plot)?.let { Spacer(Modifier.height(8.dp)); Text(it, maxLines = 4, color = Color.White.copy(alpha = 0.85f)) }
        }
    }
}

@Composable
fun MovieDetailScreen(id: String, onPlay: (PlaybackItem) -> Unit) {
    val app = LocalContext.current.app
    var movie by remember { mutableStateOf<Movie?>(null) }
    var meta by remember { mutableStateOf<MediaMetadata?>(null) }
    var progress by remember { mutableStateOf<WatchProgress?>(null) }
    LaunchedEffect(id) {
        movie = app.library.movie(id)
        progress = app.library.progress(id)
        movie?.let { m ->
            app.sync.movieDetails(m)?.let { d -> movie = m.copy(plot = d.plot ?: m.plot, cast = d.cast ?: m.cast, genre = d.genre ?: m.genre,
                containerExtension = d.containerExtension ?: m.containerExtension, durationSeconds = d.durationSeconds ?: m.durationSeconds) }
            meta = runCatching { app.metadata.metadata(m) }.getOrNull()
        }
    }
    val m = movie ?: return Placeholder("Loading…")
    val details = listOfNotNull(m.year ?: meta?.year, m.durationSeconds?.let { "${it / 60} min" } ?: meta?.runtimeMinutes?.let { "$it min" },
        (m.rating ?: meta?.rating)?.let { "★ %.1f".format(it) }, m.genre ?: meta?.genres?.joinToString(", ")).joinToString("  ·  ")
    LazyColumn {
        item { Header(m.name, meta, m.backdropURL ?: m.posterURL, details, m.plot) }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.padding(top = 16.dp)) {
                val resumable = progress?.let { !it.completed && it.position > 10 } == true
                Button(onClick = { onPlay(PlaybackItem.MovieItem(m, if (resumable) progress!!.position else null)) }, modifier = Modifier.initialFocus(m.id)) {
                    Text(if (resumable) "Resume ${minutes(progress!!.position)}" else "Play")
                }
                if (resumable) OutlinedButton(onClick = { onPlay(PlaybackItem.MovieItem(m, null)) }) { Text("Play from Beginning") }
            }
        }
        m.cast?.let { item { Text("Cast: $it", Modifier.padding(top = 20.dp), color = Color.White.copy(alpha = 0.7f), maxLines = 2) } }
    }
}

@Composable
fun SeriesDetailScreen(id: String, onPlay: (PlaybackItem) -> Unit) {
    val app = LocalContext.current.app
    var series by remember { mutableStateOf<Series?>(null) }
    var meta by remember { mutableStateOf<MediaMetadata?>(null) }
    var episodes by remember { mutableStateOf<List<Episode>>(emptyList()) }
    var progress by remember { mutableStateOf<Map<String, WatchProgress>>(emptyMap()) }
    var season by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(id) {
        series = app.library.seriesItem(id)
        val s = series ?: return@LaunchedEffect
        episodes = app.library.episodes(id)
        progress = app.library.progress(id, forSeries = true)
        episodes = app.sync.episodes(s)
        meta = runCatching { app.metadata.metadata(s) }.getOrNull()
    }
    val s = series ?: return Placeholder("Loading…")
    val seasons = episodes.map { it.season }.distinct().sortedWith(compareBy { if (it == 0) Int.MAX_VALUE else it })
    // The episode to offer: SmartContinueWatching's choice for this show, else the first.
    val next = remember(episodes, progress) {
        SmartContinueWatching.rank(progress.values.toList(), mapOf(s.id to episodes), java.time.Instant.now(), 1).firstOrNull()
    }
    val resume = (next as? SmartContinueWatching.Entry.Resume)?.progress?.let { p -> episodes.firstOrNull { it.id == p.mediaId }?.let { it to p.position } }
    val upNext = (next as? SmartContinueWatching.Entry.NextEpisode)?.episode?.let { e -> episodes.firstOrNull { it.id == e.id } }
    val shown = season ?: resume?.first?.season ?: upNext?.season ?: seasons.firstOrNull()
    val details = listOfNotNull(s.year ?: meta?.year, (s.rating ?: meta?.rating)?.let { "★ %.1f".format(it) },
        s.genre ?: meta?.genres?.joinToString(", "), if (seasons.isNotEmpty()) "${seasons.count { it > 0 }} seasons" else null).joinToString("  ·  ")

    LazyColumn {
        item { Header(s.name, meta, s.backdropURL ?: s.coverURL, details, s.plot) }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.padding(vertical = 16.dp).initialFocus(episodes.isNotEmpty())
                .focusGroup()) {
                when {
                    resume != null -> Button(onClick = { onPlay(PlaybackItem.EpisodeItem(resume.first, s, episodes, resume.second)) }) {
                        Text("Resume S${resume.first.season}, E${resume.first.number}")
                    }
                    upNext != null -> Button(onClick = { onPlay(PlaybackItem.EpisodeItem(upNext, s, episodes)) }) { Text("Play S${upNext.season}, E${upNext.number}") }
                    episodes.isNotEmpty() -> Button(onClick = { onPlay(PlaybackItem.EpisodeItem(episodes.first { it.season == seasons.first() }, s, episodes)) }) {
                        Text("Play")
                    }
                }
            }
        }
        if (seasons.size > 1) item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(seasons) { n -> FilterChip(selected = n == shown, onClick = { season = n }) { Text(if (n == 0) "Specials" else "Season $n") } }
            }
        }
        item {
            val list = episodes.filter { it.season == shown }
            if (list.isEmpty()) Text("Loading episodes…", Modifier.padding(top = 16.dp)) else
            LazyRow(horizontalArrangement = Arrangement.spacedBy(20.dp), contentPadding = PaddingValues(vertical = 16.dp, horizontal = 4.dp)) {
                items(list, key = { it.id }) { e ->
                    val p = progress[e.id]
                    val still = e.imageURL ?: meta?.episode(e.season, e.number)?.stillURL
                    WideCard("E${e.number} · ${e.title}", e.durationSeconds?.let { "${it / 60} min" }, still,
                        progress = p?.let { if (it.completed) 1.0 else it.fraction }) {
                        val start = p?.takeIf { !it.completed && it.position > 10 }?.position
                        onPlay(PlaybackItem.EpisodeItem(e, s, episodes, start))
                    }
                }
            }
        }
    }
}

private fun minutes(seconds: Double): String {
    val s = seconds.toLong()
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}
