package app.tuner.tv.ui

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
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.tv.material3.DrawerValue
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.NavigationDrawer
import androidx.tv.material3.NavigationDrawerItem
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
import app.tuner.tv.ui.settings.PlaylistsScreen

/** A page pushed on top of a section's top page. */
sealed class Page {
    data class MovieDetail(val id: String) : Page()
    data class SeriesDetail(val id: String) : Page()
    object AddPlaylist : Page()
}

/**
 * The frame: a left drawer (collapsed to icons, expands when focused), the selected section with its own back stack, and
 * the full-screen player above everything. Back pops the page, then focuses the drawer; Back on the drawer leaves the app.
 */
@Composable
fun AppShell() {
    var selected by rememberSaveable { mutableStateOf(Section.launch) }
    val stack = remember { mutableStateListOf<Page>() }
    var playing by remember { mutableStateOf<PlaybackItem?>(null) }
    var contentHasFocus by remember { mutableStateOf(false) }
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val itemFocus = remember { Section.entries.associateWith { FocusRequester() } }
    val contentFocus = remember { FocusRequester() }

    fun open(page: Page) { stack.add(page) }
    val play: (PlaybackItem) -> Unit = { playing = it }

    BackHandler(enabled = playing == null && (stack.isNotEmpty() || contentHasFocus)) {
        if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) else itemFocus.getValue(selected).requestFocus()
    }

    Box(Modifier.fillMaxSize()) {
        NavigationDrawer(
            drawerState = drawerState,
            drawerContent = {
                Column(Modifier.fillMaxHeight().padding(vertical = 27.dp, horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Section.entries.filter { it != Section.Settings }.forEach { section ->
                        DrawerItem(section, selected, itemFocus.getValue(section)) { if (selected == it) stack.clear() else { selected = it; stack.clear() } }
                    }
                    Spacer(Modifier.weight(1f))
                    DrawerItem(Section.Settings, selected, itemFocus.getValue(Section.Settings)) { selected = it; stack.clear() }
                }
            },
        ) {
            Box(
                Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)
                    .onFocusChanged { contentHasFocus = it.hasFocus }
                    .padding(start = 48.dp, end = 24.dp, top = 27.dp, bottom = 0.dp)

            ) {
                when (val page = stack.lastOrNull()) {
                    is Page.MovieDetail -> MovieDetailScreen(page.id, play)
                    is Page.SeriesDetail -> SeriesDetailScreen(page.id, play)
                    Page.AddPlaylist -> AddPlaylistScreen(onDone = { stack.removeAt(stack.lastIndex) })
                    null -> when (selected) {
                        Section.Home -> HomeScreen(play, { open(Page.MovieDetail(it)) }, { open(Page.SeriesDetail(it)) }, { open(Page.AddPlaylist) })
                        Section.Live -> LiveScreen(play)
                        Section.Movies -> VodGridScreen(CategoryKind.MOVIE) { open(Page.MovieDetail(it)) }
                        Section.Shows -> VodGridScreen(CategoryKind.SERIES) { open(Page.SeriesDetail(it)) }
                        Section.Favorites -> LiveScreen(play, Library.ChannelScope.Favorites)
                        Section.Search -> SearchScreen(play, { open(Page.MovieDetail(it)) }, { open(Page.SeriesDetail(it)) })
                        Section.Settings -> PlaylistsScreen(onAdd = { open(Page.AddPlaylist) })
                    }
                }
            }
        }
        playing?.let { item -> PlayerScreen(item, onClose = { playing = null }) }
    }


}

@Composable
private fun NavigationDrawerScope.DrawerItem(section: Section, selected: Section, focusRequester: FocusRequester, onSelect: (Section) -> Unit) {
    NavigationDrawerItem(
        selected = section == selected,
        onClick = { onSelect(section) },
        leadingContent = { Icon(section.icon, contentDescription = null) },
        modifier = Modifier.focusRequester(focusRequester),
    ) { Text(stringResource(section.title)) }
}
