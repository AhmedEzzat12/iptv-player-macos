package app.tuner.tv.ui.browse

import app.tuner.tv.ui.PillButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import app.tuner.tv.ui.rememberedFocus
import app.tuner.core.metadata.VODRating
import app.tuner.tv.ui.KeepInView
import androidx.activity.compose.BackHandler
import app.tuner.tv.ui.RenameDialog
import app.tuner.tv.ui.MenuAction
import app.tuner.tv.ui.ItemMenu
import app.tuner.tv.ui.FocusBleed
import app.tuner.tv.ui.bleedStart
import app.tuner.tv.ui.PageTitle
import androidx.compose.foundation.background
import androidx.compose.ui.focus.focusProperties
import androidx.tv.material3.Surface
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.text.style.TextOverflow
import app.tuner.tv.ui.PageStart
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
import androidx.compose.ui.platform.LocalDensity
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
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun VodGridScreen(kind: CategoryKind, onOpen: (String) -> Unit) {
    val app = LocalContext.current.app
    val scope = rememberCoroutineScope()
    var categories by remember { mutableStateOf<List<Category>>(emptyList()) }
    var selected by remember { mutableStateOf<String?>(null) }
    var items by remember { mutableStateOf<List<Triple<String, String, String?>>>(emptyList()) }
    var revision by remember { mutableStateOf(0) }
    var exhausted by remember { mutableStateOf(false) }
    var menuCategory by remember { mutableStateOf<app.tuner.core.models.Category?>(null) }
    var renamingCategory by remember { mutableStateOf<app.tuner.core.models.Category?>(null) }
    BackHandler(enabled = menuCategory != null || renamingCategory != null) { menuCategory = null; renamingCategory = null }
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

    // Categories in a list on the left (as on Live TV), posters on the right. A row of chips was slow with dozens of
    // categories: one press per chip, and the posters had to be climbed back up one row at a time to reach them. Now
    // moving through the list switches category (after a short pause, so passing through doesn't load each one), Left
    // from the posters' first column comes back to it, and Back from the posters returns to the selected category.
    val listFocus = remember { mutableMapOf<String, FocusRequester>() }
    fun requester(key: String) = listFocus.getOrPut(key) { FocusRequester() }
    var postersHaveFocus by remember { mutableStateOf(false) }
    var focusedCategory by remember { mutableStateOf<String?>(null) }
    var focusedAny by remember { mutableStateOf(false) }
    LaunchedEffect(focusedCategory, focusedAny) {
        if (!focusedAny) return@LaunchedEffect
        delay(350)
        selected = focusedCategory
    }
    BackHandler(enabled = postersHaveFocus && menuCategory == null && renamingCategory == null) {
        runCatching { requester(selected ?: "").requestFocus() }
    }
    val grid = androidx.compose.foundation.lazy.grid.rememberLazyGridState()
    LaunchedEffect(selected) { grid.scrollToItem(0) }

    Box(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxSize()) {
            Column(Modifier.width(230.dp).fillMaxHeight()) {
                PageTitle(if (kind == CategoryKind.MOVIE) "Movies" else "TV Shows")
                // Entering the list (Left from the posters) lands on the selected category, not on whichever one is
                // level with the poster, which would then switch the category.
                LazyColumn(Modifier.fillMaxSize().bleedStart()
                    .focusProperties { enter = { runCatching { requester(selected ?: "") }.getOrDefault(FocusRequester.Default) } }.focusGroup(),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    contentPadding = PaddingValues(start = FocusBleed, top = 4.dp, bottom = 48.dp)) {
                    item(key = "") {
                        CategoryRow("All", selected == null, Modifier.focusRequester(requester("")).initialFocus()
                            .onFocusChanged { if (it.isFocused) { focusedCategory = null; focusedAny = true } }) { selected = null; focusedAny = false }
                    }
                    items(categories, key = { it.id }) { c ->
                        CategoryRow(c.displayName, selected == c.id, Modifier.focusRequester(requester(c.id))
                            .onFocusChanged { if (it.isFocused) { focusedCategory = c.id; focusedAny = true } },
                            onLongClick = { menuCategory = c }) { selected = c.id; focusedAny = false }
                    }
                }
            }
            Spacer(Modifier.width(20.dp))
            Box(Modifier.weight(1f).fillMaxHeight().padding(top = 44.dp).onFocusChanged { postersHaveFocus = it.hasFocus; if (it.hasFocus) focusedAny = false }) {
                if (items.isEmpty()) {
                    Placeholder(if (categories.isEmpty()) "Add a playlist with movies and shows in Settings." else "Nothing in this category.")
                } else {
                    // Fixed cells: posters keep one size in every category (Adaptive stretched them); four to a row beside
                    // the list.
                    LazyVerticalGrid(GridCells.FixedSize(132.dp), Modifier.bleedStart(), state = grid, horizontalArrangement = Arrangement.spacedBy(18.dp),
                        verticalArrangement = Arrangement.spacedBy(22.dp), contentPadding = PaddingValues(top = 12.dp, start = FocusBleed, bottom = 48.dp, end = 4.dp)) {
                        itemsIndexed(items, key = { _, it -> it.first }) { index, (id, name, image) ->
                            Box(Modifier.rememberedFocus(id)) { PosterCard(name, image, width = 132, onClick = { onOpen(id) }) }
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

        menuCategory?.let { cat ->
            ItemMenu(cat.displayName, listOf(
                MenuAction("Rename…") { renamingCategory = cat },
                MenuAction("Hide Category") { scope.launch { app.library.setCategoryHidden(cat.id, true); if (selected == cat.id) selected = null } },
            )) { menuCategory = null }
        }
        renamingCategory?.let { cat ->
            RenameDialog("Rename Category", cat.alias ?: "", cat.name, onSave = { scope.launch { app.library.renameCategory(cat.id, it) } }) { renamingCategory = null }
        }
    }
}

/** One category in the Movies/TV Shows list: 36 dp rows (ListItem's 48 dp, even the dense one, fitted only nine on
 * screen), and the selected one stays marked while focus is on the posters. */
@Composable
private fun CategoryRow(name: String, selected: Boolean, modifier: Modifier, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    Surface(
        onClick = onClick, onLongClick = onLongClick, modifier = modifier.fillMaxWidth().height(36.dp),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(8.dp)),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.03f),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected) Color.White.copy(alpha = 0.14f) else Color.Transparent, contentColor = Color.White,
            focusedContainerColor = Color.White, focusedContentColor = Color.Black,
        ),
    ) {
        Box(Modifier.fillMaxSize().padding(horizontal = 14.dp), contentAlignment = Alignment.CenterStart) {
            Text(name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/**
 * Movie and show pages, like the Apple TV app's: the artwork fills the screen behind the page (under the rail too),
 * the title, details and buttons sit low on its left over a fade, and what follows (seasons and episodes, cast) peeks
 * in at the bottom. The old 380 dp boxed backdrop took most of a 540 dp-tall TV screen: the season chips sat on its
 * bottom edge and the episodes started off screen. Scrolling down dims the artwork; focus back in the top block
 * scrolls back to the top so the title shows again.
 */
@Composable
private fun DetailPage(backdrop: String?, poster: String?, list: LazyListState = rememberLazyListState(), hero: @Composable ColumnScope.() -> Unit, more: LazyListScope.() -> Unit) {
    val scope = rememberCoroutineScope()
    val scrolled by remember { derivedStateOf { list.firstVisibleItemIndex > 0 || list.firstVisibleItemScrollOffset > 40 } }
    val dim by animateFloatAsState(if (scrolled) 0.7f else 0f, label = "dim")
    val background = MaterialTheme.colorScheme.background
    BoxWithConstraints(Modifier.fillMaxSize().background(background)) {
        val screen = maxHeight
        if (backdrop != null) AsyncImage(backdrop, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alignment = Alignment.TopCenter)
        // A fade from the left (the text and the rail stay readable) and one into the page at the bottom.
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to background.copy(alpha = 0.97f), 0.42f to background.copy(alpha = 0.7f), 0.75f to Color.Transparent)))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.3f to Color.Transparent, 0.95f to background)))
        // Only a poster (no wide artwork): shown whole on the right, over the fades; stretched across the screen it was
        // a blurry crop.
        if (backdrop == null && poster != null) AsyncImage(poster, null,
            Modifier.align(Alignment.TopEnd).padding(top = 40.dp, end = 64.dp).height(screen * 0.62f).aspectRatio(2f / 3f).clip(RoundedCornerShape(12.dp)),
            contentScale = ContentScale.Crop)
        Box(Modifier.fillMaxSize().background(background.copy(alpha = dim)))
        // Scroll only when the focused control would be off screen, and then far enough to show the titles under an
        // episode card too (the card alone came into view with its title cut off by the screen's edge).
        val below = with(LocalDensity.current) { 64.dp.toPx() }
        val spec = remember(below) { object : androidx.compose.foundation.gestures.BringIntoViewSpec {
            override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float =
                if (offset + size > containerSize && offset >= 0f) minOf(offset, offset + size + below - containerSize)
                else KeepInView.calculateScrollDistance(offset, size, containerSize)
        } }
        @OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
        androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides spec) {
            LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(start = PageStart, end = 48.dp, bottom = 48.dp)) {
                item {
                    Column(
                        Modifier.fillMaxWidth().height(screen * 0.74f).padding(bottom = 22.dp)
                            .onFocusChanged { if (it.hasFocus && list.firstVisibleItemIndex + list.firstVisibleItemScrollOffset > 0) scope.launch { list.animateScrollToItem(0) } },
                        verticalArrangement = Arrangement.Bottom, content = hero,
                    )
                }
                more()
            }
        }
    }
}

/** The title block: the show's logo (online metadata) or its name, the details line and the plot. */
@Composable
private fun HeroTitle(title: String, meta: MediaMetadata?, details: String, plot: String?) {
    if (meta?.logoURL != null) AsyncImage(meta.logoURL, title, Modifier.height(110.dp).widthIn(max = 420.dp), contentScale = ContentScale.Fit, alignment = Alignment.BottomStart)
    else Text(title, Modifier.widthIn(max = 680.dp), style = MaterialTheme.typography.displaySmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
    if (details.isNotEmpty()) { Spacer(Modifier.height(10.dp)); Text(details, color = Color.White.copy(alpha = 0.75f), style = MaterialTheme.typography.bodyLarge) }
    plot?.takeIf { it.isNotBlank() }?.let {
        Spacer(Modifier.height(10.dp))
        Text(it, Modifier.widthIn(max = 600.dp), maxLines = 3, overflow = TextOverflow.Ellipsis, color = Color.White.copy(alpha = 0.85f), style = MaterialTheme.typography.bodyMedium)
    }
    Spacer(Modifier.height(20.dp))
}

@Composable
fun MovieDetailScreen(id: String, onPlay: (PlaybackItem) -> Unit) {
    val app = LocalContext.current.app
    var movie by remember { mutableStateOf<Movie?>(null) }
    var meta by remember { mutableStateOf<MediaMetadata?>(null) }
    var progress by remember { mutableStateOf<WatchProgress?>(null) }
    var revision by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { app.database.changes.collect { if (it != Change.GUIDE) revision++ } }
    LaunchedEffect(id, revision) { progress = app.library.progress(id) }
    LaunchedEffect(id) {
        movie = app.library.movie(id)
        movie?.let { m ->
            app.sync.movieDetails(m)?.let { d -> movie = m.copy(plot = d.plot ?: m.plot, cast = d.cast ?: m.cast, genre = d.genre ?: m.genre,
                containerExtension = d.containerExtension ?: m.containerExtension, durationSeconds = d.durationSeconds ?: m.durationSeconds) }
            meta = runCatching { app.metadata.metadata(m) }.getOrNull()
        }
    }
    val m = movie ?: return Placeholder("Loading…")
    val details = listOfNotNull(m.year ?: meta?.year, m.durationSeconds?.takeIf { it > 0 }?.let { "${(it / 60).coerceAtLeast(1)} min" } ?: meta?.runtimeMinutes?.let { "$it min" },
        VODRating.of(m.rating, meta)?.text, m.genre ?: meta?.genres?.joinToString(", ")).joinToString("  ·  ")
    DetailPage(meta?.backdropURL ?: m.backdropURL, m.posterURL ?: meta?.posterURL, hero = {
        HeroTitle(m.name, meta, details, meta?.overview ?: m.plot)
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            val resumable = progress?.let { !it.completed && it.position > 10 } == true
            PillButton(if (resumable) "Resume ${minutes(progress!!.position)}" else "Play", icon = Icons.Filled.PlayArrow,
                onClick = { onPlay(PlaybackItem.MovieItem(m, if (resumable) progress!!.position else null)) }, modifier = Modifier.initialFocus(m.id))
            if (resumable) PillButton("Play from Beginning", icon = Icons.Filled.Replay, onClick = { onPlay(PlaybackItem.MovieItem(m, null)) })
        }
    }) {
        m.cast?.let { item { Text("Cast: $it", Modifier.padding(top = 8.dp).widthIn(max = 900.dp), color = Color.White.copy(alpha = 0.7f), maxLines = 2) } }
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
    var revision by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { app.database.changes.collect { if (it != Change.GUIDE) revision++ } }
    LaunchedEffect(id, revision) { progress = app.library.progress(id, forSeries = true) }
    LaunchedEffect(id) {
        series = app.library.seriesItem(id)
        val s = series ?: return@LaunchedEffect
        episodes = app.library.episodes(id)
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
    val details = listOfNotNull(s.year ?: meta?.year, VODRating.of(s.rating, meta)?.text,
        s.genre ?: meta?.genres?.joinToString(", "), if (seasons.isNotEmpty()) "${seasons.count { it > 0 }} seasons" else null).joinToString("  ·  ")

    val page = rememberLazyListState()
    val scope = rememberCoroutineScope()
    DetailPage(meta?.backdropURL ?: s.backdropURL, s.coverURL ?: meta?.posterURL, page, hero = {
        HeroTitle(s.name, meta, details, meta?.overview ?: s.plot)
        if (episodes.isNotEmpty()) {
            val primary = resume ?: upNext?.let { it to null } ?: (episodes.first { it.season == seasons.first() } to null)
            val label = when {
                resume != null -> "Resume S${resume.first.season}, E${resume.first.number}"
                upNext != null -> "Play S${upNext.season}, E${upNext.number}"
                else -> "Play"
            }
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.focusGroup()) {
                PillButton(label, icon = Icons.Filled.PlayArrow, onClick = { onPlay(PlaybackItem.EpisodeItem(primary.first, s, episodes, primary.second)) },
                    modifier = Modifier.initialFocus(s.id))
                if (resume != null) {
                    PillButton("Play from Beginning", icon = Icons.Filled.Replay, onClick = { onPlay(PlaybackItem.EpisodeItem(resume.first, s, episodes, null)) })
                }
            }
        } else {
            Text("Loading episodes…", color = Color.White.copy(alpha = 0.7f))
        }
    }) {
        if (seasons.size > 1) item {
            // Room around the chips: a focused chip grows, and would otherwise overlap what's above and below.
            LazyRow(Modifier.bleedStart(), horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 8.dp, horizontal = FocusBleed)) {
                items(seasons) { n -> PillButton(if (n == 0) "Specials" else "Season $n", onClick = { season = n }, selected = n == shown) }
            }
        } else if (episodes.isNotEmpty()) item {
            Text("Episodes", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
        }
        item {
            val list = episodes.filter { it.season == shown }
            // The episodes are the page's last row: show all of it, titles under the cards included. After the focused
            // card's own bring-into-view scroll, which would otherwise cancel this one.
            if (list.isNotEmpty()) LazyRow(Modifier.bleedStart().onFocusChanged { if (it.hasFocus) scope.launch { delay(250); page.animateScrollBy(100_000f) } },
                horizontalArrangement = Arrangement.spacedBy(20.dp), contentPadding = PaddingValues(top = 12.dp, bottom = 16.dp, start = FocusBleed, end = 48.dp)) {
                items(list, key = { it.id }) { e ->
                    val p = progress[e.id]
                    val still = e.imageURL ?: meta?.episode(e.season, e.number)?.stillURL
                    WideCard("E${e.number} · ${e.title}", e.durationSeconds?.takeIf { it > 0 }?.let { "${(it / 60).coerceAtLeast(1)} min" }, still,
                        width = 220, progress = p?.let { if (it.completed) 1.0 else it.fraction }) {
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
