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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.width
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
        // Like the Apple TV app's sidebar: a slim icon rail that opens over the page (with a fade) instead of pushing
        // it aside. Entering it focuses the current section, not whichever icon is level with the focused card.
        ModalNavigationDrawer(
            drawerState = drawerState,
            scrimBrush = Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.8f), Color.Black.copy(alpha = 0.4f))),
            drawerContent = {
                val currentSection = selected
                // Open, the rail sits on a solid panel so its titles never mix with the page's text underneath.
                Column(
                    Modifier.fillMaxHeight()
                        // Focus enters on the current section directly (moving it afterwards made another icon flash).
                        .focusProperties {
                            canFocus = playing == null
                            onEnter = { if (itemFocus.getValue(currentSection).requestFocus()) cancelFocusChange() }
                        }
                        .focusGroup()
                        .then(if (hasFocus) Modifier.background(TunerColors.surface, RoundedCornerShape(topEnd = 24.dp, bottomEnd = 24.dp)) else Modifier)
                        .padding(vertical = 27.dp, horizontal = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
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
                    .focusRequester(contentFocus).focusRestorer().focusGroup()
                    .onFocusChanged { contentHasFocus = it.hasFocus }
                    .padding(start = RAIL_WIDTH + 32.dp, end = 24.dp, top = 27.dp, bottom = 0.dp)

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
        playing?.let { item ->
            PlayerScreen(item, onClose = {
                runCatching { contentFocus.requestFocus() }
                playing = null
            })
        }
    }


}

@Composable
private fun NavigationDrawerScope.DrawerItem(section: Section, selected: Section, focusRequester: FocusRequester, onSelect: (Section) -> Unit) {
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
        modifier = Modifier.focusRequester(focusRequester).height(44.dp).then(if (hasFocus) Modifier.width(200.dp) else Modifier.width(48.dp)),
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
