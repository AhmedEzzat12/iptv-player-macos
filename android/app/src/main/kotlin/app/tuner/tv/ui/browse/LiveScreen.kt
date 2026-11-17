package app.tuner.tv.ui.browse

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.ListItem
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Channel
import app.tuner.data.Change
import app.tuner.data.Library
import app.tuner.tv.app
import app.tuner.tv.ui.PlaybackItem
import app.tuner.tv.ui.Placeholder
import app.tuner.tv.ui.TunerColors
import app.tuner.tv.ui.initialFocus
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch

/** Live TV (first slice): categories on the left, the channel list on the right; OK plays, long-press toggles favourite. */
@Composable
fun LiveScreen(onPlay: (PlaybackItem) -> Unit, initial: Library.ChannelScope = Library.ChannelScope.All) {
    val app = LocalContext.current.app
    val scope = rememberCoroutineScope()
    var groups by remember { mutableStateOf<List<Pair<String, Library.ChannelScope>>>(emptyList()) }
    var selected by remember { mutableStateOf(initial) }
    var channels by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var revision by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { app.database.changes.collect { if (it != Change.GUIDE) revision++ } }
    LaunchedEffect(revision) {
        groups = listOf("All Channels" to Library.ChannelScope.All, "Favorites" to Library.ChannelScope.Favorites,
            "Recently Watched" to Library.ChannelScope.Recent) +
            app.library.categories(CategoryKind.LIVE).map { it.displayName to Library.ChannelScope.InCategory(it.id) }
    }
    LaunchedEffect(selected, revision) { channels = app.library.channels(selected) }

    Row(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.width(320.dp).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            item { Text("Live TV", style = MaterialTheme.typography.displaySmall, modifier = Modifier.padding(bottom = 16.dp)) }
            items(groups, key = { it.first + it.second }) { (name, scope) ->
                ListItem(selected = scope == selected, onClick = { selected = scope }, headlineContent = {
                    Text(name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }, modifier = Modifier.initialFocus(enabled = scope == initial).onFocusChanged { if (it.isFocused) selected = scope })
            }
        }
        Spacer(Modifier.width(32.dp))
        if (channels.isEmpty()) {
            Placeholder(if (groups.size <= 3) "Add a playlist in Settings to watch live TV." else "No channels here.")
        } else {
            // Entering the list from the groups goes to the first channel (or back to the last focused one), not to
            // whichever row happens to sit next to the focused group.
            val firstChannel = remember { FocusRequester() }
            LazyColumn(Modifier.fillMaxSize().focusRestorer(firstChannel), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(channels, key = { it.id }) { ch ->
                    ListItem(
                        selected = false,
                        onClick = { onPlay(PlaybackItem.Live(ch, channels)) },
                        onLongClick = { scope.launch { app.library.setFavorite(ch.id, !ch.isFavorite) } },
                        leadingContent = {
                            Box(Modifier.size(64.dp, 40.dp).background(TunerColors.surface, RoundedCornerShape(6.dp)), contentAlignment = Alignment.Center) {
                                if (ch.logoURL != null) AsyncImage(ch.logoURL, null, Modifier.fillMaxSize().padding(4.dp), contentScale = ContentScale.Fit)
                                else Text(ch.number?.toString() ?: "", color = Color.White.copy(alpha = 0.6f))
                            }
                        },
                        headlineContent = { Text((ch.number?.let { "$it  " } ?: "") + ch.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        trailingContent = { if (ch.isFavorite) Text("★", color = TunerColors.accent) },
                        modifier = Modifier.fillMaxWidth().then(if (ch.id == channels.first().id) Modifier.focusRequester(firstChannel) else Modifier),
                    )
                }
            }
        }
    }
}
