package app.tuner.tv.ui

import androidx.compose.runtime.withFrameNanos
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.draw.alpha
import app.tuner.tv.integration.HomeChannel
import app.tuner.tv.integration.WatchNext
import app.tuner.tv.app
import androidx.compose.ui.platform.LocalContext
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.tv.material3.DrawerValue
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.ModalNavigationDrawer
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Surface
import androidx.tv.material3.NavigationDrawerScope
import androidx.tv.material3.Text
import androidx.tv.material3.rememberDrawerState
import app.tuner.core.models.CategoryKind
import app.tuner.data.Library
import app.tuner.tv.ui.browse.HomeScreen
import app.tuner.tv.ui.browse.LiveScreen
import app.tuner.tv.ui.browse.MovieDetailScreen
import app.tuner.tv.ui.browse.SearchScreen
import app.tuner.tv.ui.browse.SeriesDetailScreen
import app.tuner.tv.ui.browse.VodGridScreen
import app.tuner.tv.ui.player.PlayerScreen
import app.tuner.tv.ui.settings.AddPlaylistScreen
import app.tuner.tv.ui.settings.EditPlaylistScreen
import app.tuner.tv.ui.settings.PlaylistsScreen

/** A page pushed on top of a section's top page. */
sealed class Page {
    data class MovieDetail(val id: String) : Page()
    data class SeriesDetail(val id: String) : Page()
    object AddPlaylist : Page()
    data class EditPlaylist(val id: String) : Page()
}

/**
 * The frame: a left drawer (collapsed to icons, expands when focused), the selected section with its own back stack, and
 * the full-screen player above everything. Back closes the open drawer (back to the page), pops a page, then goes to
 * Home; Back on Home leaves the app. (Back on the drawer used to leave the app, which closed it by accident.)
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class) // focusProperties.enter
@Composable
fun AppShell() {
    var selected by rememberSaveable { mutableStateOf(Section.launch) }
    val stack = remember { mutableStateListOf<Page>() }
    var playing by remember { mutableStateOf<PlaybackItem?>(null) }
    val closeScope = androidx.compose.runtime.rememberCoroutineScope()
    var contentHasFocus by remember { mutableStateOf(false) }
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val itemFocus = remember { Section.entries.associateWith { FocusRequester() } }
    val contentFocus = remember { FocusRequester() }
    val sectionState = androidx.compose.runtime.saveable.rememberSaveableStateHolder()


    val sectionFocus = remember { FocusRequester() }
    var returningFromPage by remember { mutableStateOf(false) }
    val focusMemory = remember { FocusMemory() }
    var savedKey by remember { mutableStateOf<String?>(null) }
    var returningFromPlayer by remember { mutableStateOf(false) }
    fun open(page: Page) {
        // Remember the exact card that opened the page (restored when the page closes).
        if (stack.isEmpty()) savedKey = focusMemory.lastKey
        stack.add(page)
    }
    val play: (PlaybackItem) -> Unit = { playing = it }
    val app = LocalContext.current.app
    LaunchedEffect(Unit) {
        app.playRequests.collect { uri ->
            if (uri != null) {
                app.playRequests.value = null
                val page = HomeChannel.page(uri)
                if (page != null) { playing = null; stack.clear(); stack.add(page) }
                else WatchNext.resolve(app, uri)?.let { playing = it }
            }
        }
    }

    BackHandler(enabled = playing == null && (stack.isNotEmpty() || (contentHasFocus && selected != Section.Home))) {
        if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) else selected = Section.Home
    }
    // Choosing a section closes the drawer: focus left in the rail kept it open over the page. A new section's own
    // first focus (`initialFocus`: Search's field) goes first; the page only takes focus here if nothing did.
    var chose by remember { mutableStateOf(0) }
    fun choose(section: Section) { selected = section; stack.clear(); chose++ }
    LaunchedEffect(chose) {
        if (chose == 0) return@LaunchedEffect
        withFrameNanos { }
        delay(200)
        if (!contentHasFocus) runCatching { contentFocus.requestFocus() }
    }
    // Registered last, so it wins while the drawer is open: Back closes it and returns to the page.
    BackHandler(enabled = playing == null && drawerState.currentValue == DrawerValue.Open) {
        runCatching { contentFocus.requestFocus() }
    }

    androidx.compose.runtime.CompositionLocalProvider(LocalFocusMemory provides focusMemory) { Box(Modifier.fillMaxSize()) {
        // Like the Apple TV app's sidebar: a slim icon rail that opens over the page (with a fade) instead of pushing
        // it aside. Entering it focuses the current section, not whichever icon is level with the focused card.
        ModalNavigationDrawer(
            drawerState = drawerState,
            scrimBrush = Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.8f), Color.Black.copy(alpha = 0.4f))),
            drawerContent = {
                // Open, the rail sits on a solid panel so its titles never mix with the page's text underneath.
                Column(
                    Modifier.fillMaxHeight()
                        // Right leaves the open drawer for the page (focus search found nothing to the right of the
                        // rail, so the drawer stayed open).
                        .onPreviewKeyEvent { e ->
                            if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionRight) {
                                runCatching { contentFocus.requestFocus() }; true
                            } else false
                        }
                        .focusGroup()
                        .then(if (hasFocus) Modifier.background(TunerColors.surface, RoundedCornerShape(topEnd = 24.dp, bottomEnd = 24.dp)) else Modifier)
                        .padding(vertical = 27.dp, horizontal = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Section.entries.filter { it != Section.Settings }.forEach { section ->
                        DrawerItem(section, selected, itemFocus.getValue(section), playing == null, ::choose)
                    }
                    Spacer(Modifier.weight(1f))
                    DrawerItem(Section.Settings, selected, itemFocus.getValue(Section.Settings), playing == null, ::choose)
                }
            },
        ) {
            Box(
                Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)
                    .focusRequester(contentFocus).focusRestorer().focusGroup()
                    .onFocusChanged { contentHasFocus = it.hasFocus }

            ) {
                val page = stack.lastOrNull()
                // The section stays composed (hidden) under a pushed page, so Back lands on the card that opened the
                // page: disposing it lost the focus, and Back went to the top of Home (where OK then played the first
                // Continue Watching title). Focus can't wander into it while hidden (`enter` is cancelled).
                Box(
                    Modifier.fillMaxSize().padding(PageInsets)
                        // Same modifiers in both states: adding/removing one recreated the focus nodes after it and lost
                        // the saved card.
                        .alpha(if (page != null) 0f else 1f)
                        .focusProperties { if (page != null) enter = { FocusRequester.Cancel } }
                        .focusRequester(sectionFocus).focusGroup()
                ) {
                    // Each section's state (search text, grid scroll) also survives switching sections.
                    sectionState.SaveableStateProvider(selected.name) { when (selected) {
                        Section.Home -> HomeScreen(play, { open(Page.MovieDetail(it)) }, { open(Page.SeriesDetail(it)) }, { open(Page.AddPlaylist) })
                        Section.Live -> LiveScreen(play)
                        Section.Movies -> VodGridScreen(CategoryKind.MOVIE) { open(Page.MovieDetail(it)) }
                        Section.Shows -> VodGridScreen(CategoryKind.SERIES) { open(Page.SeriesDetail(it)) }
                        Section.Favorites -> LiveScreen(play, Library.ChannelScope.Favorites)
                        Section.Search -> SearchScreen(play, { open(Page.MovieDetail(it)) }, { open(Page.SeriesDetail(it)) },
                            focusSidebar = { runCatching { itemFocus.getValue(Section.Search).requestFocus() } })
                        Section.Settings -> PlaylistsScreen(onAdd = { open(Page.AddPlaylist) }, onEdit = { open(Page.EditPlaylist(it)) })
                    } }
                }
                if (page != null) Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
                    when (page) {
                        is Page.MovieDetail -> MovieDetailScreen(page.id, play)
                        is Page.SeriesDetail -> SeriesDetailScreen(page.id, play)
                        // Movie and show pages run their artwork edge to edge and inset their own content.
                        Page.AddPlaylist -> Box(Modifier.padding(PageInsets)) { AddPlaylistScreen(onDone = { stack.removeAt(stack.lastIndex) }) }
                        is Page.EditPlaylist -> Box(Modifier.padding(PageInsets)) { EditPlaylistScreen(page.id, onDone = { stack.removeAt(stack.lastIndex) }) }
                    }
                }
                // Back from the last page: focus returns to the section, whose restorer picks the card that opened it.
                LaunchedEffect(page == null) {
                    if (page == null && returningFromPage) {
                        returningFromPage = false
                        // The card that opened the page takes focus back (`rememberedFocus`); if it's gone, the section.
                        focusMemory.restoreKey = savedKey
                        repeat(8) { if (focusMemory.restoreKey != null) withFrameNanos { } }
                        if (focusMemory.restoreKey != null) { focusMemory.restoreKey = null; runCatching { sectionFocus.requestFocus() } }
                    } else if (page != null) returningFromPage = true
                }
            }
        }
        playing?.let { item ->
            // A new title (e.g. from Google TV's Continue watching row) restarts the player rather than being ignored.
            // Closing: the row or card that started playback takes focus back while the player is still up, then the
            // player goes. Removed with focus inside, the player handed focus to the first focusable item on screen; on
            // Live TV that was "All Channels", whose focus selects it, so Back landed in a different set of channels.
            // (Asking the page for focus did the same: its restorer only knows the section, which starts at its top.)
            androidx.compose.runtime.key(item) { PlayerScreen(item, onClose = {
                closeScope.launch {
                    if (stack.isEmpty()) {
                        focusMemory.restoreKey = focusMemory.lastKey
                        repeat(8) { if (focusMemory.restoreKey != null) withFrameNanos { } }
                    }
                    playing = null
                }
            }) }
        }
        // Closing the player: back to the card that started it (as for pages), else the page. Started from a pushed page
        // (a movie or episode page), the remembered card is the hidden one under that page: focus goes back to the page
        // instead (its restorer picks the Play button), never into the hidden section.
        LaunchedEffect(playing == null) {
            if (playing == null && returningFromPlayer && stack.isNotEmpty()) {
                returningFromPlayer = false
                withFrameNanos { }
                runCatching { contentFocus.requestFocus() }
            } else if (playing == null && returningFromPlayer) {
                returningFromPlayer = false
                focusMemory.restoreKey = focusMemory.lastKey
                repeat(8) { if (focusMemory.restoreKey != null) withFrameNanos { } }
                if (focusMemory.restoreKey != null) { focusMemory.restoreKey = null; runCatching { contentFocus.requestFocus() } }
            } else if (playing != null) returningFromPlayer = true
        }
    } }


}

@Composable
private fun NavigationDrawerScope.DrawerItem(section: Section, selected: Section, focusRequester: FocusRequester, enabled: Boolean, onSelect: (Section) -> Unit) {
    // A compact pill instead of NavigationDrawerItem (256 dp open, bulky): icon only while the rail is closed,
    // icon and title at a fixed 200 dp while it's open.
    val isSelected = section == selected
    Surface(
        onClick = { onSelect(section) },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(50)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (isSelected) Color.White.copy(alpha = 0.12f) else Color.Transparent,
            contentColor = Color.White.copy(alpha = if (isSelected) 1f else 0.75f),
            focusedContainerColor = Color.White, focusedContentColor = Color.Black,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
        // While the rail is closed only the current section can take focus, so Left from a page always lands on it
        // (redirecting focus in onEnter left nothing focused on the TV; moving it afterwards flashed another icon).
        // Nothing in it takes focus during playback. Don't set canFocus on the column: that makes the column itself
        // a focus target, and Left then focuses an invisible container.
        modifier = Modifier.focusRequester(focusRequester).focusProperties { canFocus = enabled && (hasFocus || isSelected) }.height(44.dp).then(if (hasFocus) Modifier.width(200.dp) else Modifier.width(48.dp)),
    ) {
        Row(Modifier.fillMaxSize().padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(section.icon, contentDescription = stringResource(section.title), Modifier.size(20.dp))
            if (hasFocus) {
                Spacer(Modifier.width(14.dp))
                Text(stringResource(section.title), style = MaterialTheme.typography.titleSmall, maxLines = 1)
            }
        }
    }
}

/** Closed rail: 48 dp pills plus 8 dp padding each side. Page content starts after it so titles are never under it. */
private val RAIL_WIDTH = 64.dp

/** Where a page's content starts: clear of the rail on the left. */
val PageStart = RAIL_WIDTH + 32.dp
val PageInsets = PaddingValues(start = PageStart, end = 24.dp, top = 27.dp)
