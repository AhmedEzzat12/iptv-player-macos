package app.tuner.tv.ui.browse

import app.tuner.tv.ui.rememberedFocus
import androidx.tv.material3.LocalContentColor
import app.tuner.tv.ui.RenameDialog
import app.tuner.tv.ui.MenuAction
import app.tuner.tv.ui.ItemMenu
import app.tuner.tv.ui.FocusBleed
import app.tuner.tv.ui.bleedStart
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
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
import androidx.tv.material3.Button
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.FilterChip
import androidx.tv.material3.ListItem
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import app.tuner.core.models.CategoryKind
import app.tuner.core.models.Channel
import app.tuner.core.models.Program
import app.tuner.data.Change
import app.tuner.data.Library
import app.tuner.tv.app
import app.tuner.tv.ui.PageTitle
import app.tuner.tv.ui.PlaybackItem
import app.tuner.tv.ui.Placeholder
import app.tuner.tv.ui.TunerColors
import app.tuner.tv.ui.initialFocus
import coil3.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private val TIME_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm", Locale.getDefault())
private val DAY_TIME_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("EEE HH:mm", Locale.getDefault())

internal fun fmtClock(instant: Instant): String = TIME_FMT.withZone(ZoneId.systemDefault()).format(instant)
private fun fmtDayClock(instant: Instant): String = DAY_TIME_FMT.withZone(ZoneId.systemDefault()).format(instant)

/** Live TV: categories + channel list with Now/Next, plus the multi-channel TV Guide grid and catchup playback. */
@Composable
fun LiveScreen(onPlay: (PlaybackItem) -> Unit, initial: Library.ChannelScope = Library.ChannelScope.All) {
    val app = LocalContext.current.app
    val scope = rememberCoroutineScope()
    var groups by remember { mutableStateOf<List<Pair<String, Library.ChannelScope>>>(emptyList()) }
    var selected by remember { mutableStateOf(initial) }
    var channels by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var programsByKey by remember { mutableStateOf<Map<String, List<Program>>>(emptyMap()) }
    var revision by remember { mutableStateOf(0) }
    var guideRevision by remember { mutableStateOf(0) }
    var showGrid by remember { mutableStateOf(false) }
    var inspected by remember { mutableStateOf<Pair<Channel, Program>?>(null) }
    // Long-press menus (favourite, hide, rename) and the rename dialog.
    var menuChannel by remember { mutableStateOf<Channel?>(null) }
    var menuCategory by remember { mutableStateOf<app.tuner.core.models.Category?>(null) }
    var renamingChannel by remember { mutableStateOf<Channel?>(null) }
    var renamingCategory by remember { mutableStateOf<app.tuner.core.models.Category?>(null) }
    var liveCategories by remember { mutableStateOf<Map<String, app.tuner.core.models.Category>>(emptyMap()) }
    var nowEpoch by remember { mutableLongStateOf(System.currentTimeMillis() / 1000) }
    // Grid 2-hour window start, rounded down to 30 minutes.
    var windowStartEpoch by remember { mutableLongStateOf((System.currentTimeMillis() / 1000 / 1800) * 1800) }

    LaunchedEffect(Unit) {
        app.database.changes.collect {
            if (it == Change.GUIDE) guideRevision++ else revision++
        }
    }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            nowEpoch = System.currentTimeMillis() / 1000
        }
    }
    LaunchedEffect(revision) {
        groups = listOf("All Channels" to Library.ChannelScope.All, "Favorites" to Library.ChannelScope.Favorites,
            "Recently Watched" to Library.ChannelScope.Recent) +
            app.library.categories(CategoryKind.LIVE).also { cats -> liveCategories = cats.associateBy { it.id } }
                .map { it.displayName to Library.ChannelScope.InCategory(it.id) }
    }
    LaunchedEffect(selected, revision, guideRevision) {
        channels = app.library.channels(selected)
    }
    LaunchedEffect(channels, guideRevision, windowStartEpoch, showGrid, nowEpoch / 300) {
        val keys = channels.mapNotNull { it.epgKey }
        if (keys.isEmpty()) {
            programsByKey = emptyMap()
        } else {
            val from = if (showGrid) Instant.ofEpochSecond(windowStartEpoch) else Instant.ofEpochSecond(nowEpoch - 1800)
            val to = if (showGrid) Instant.ofEpochSecond(windowStartEpoch + 7200) else Instant.ofEpochSecond(nowEpoch + 6 * 3600)
            programsByKey = app.library.programs(keys, from, to)
        }
    }

    BackHandler(enabled = menuChannel != null || menuCategory != null || renamingChannel != null || renamingCategory != null) {
        menuChannel = null; menuCategory = null; renamingChannel = null; renamingCategory = null
    }
    BackHandler(enabled = inspected != null || showGrid) {
        if (inspected != null) inspected = null else showGrid = false
    }

    val now = Instant.ofEpochSecond(nowEpoch)

    Box(Modifier.fillMaxSize()) {
        if (showGrid) {
            GuideGridView(
                groups = groups,
                selected = selected,
                onSelectGroup = { selected = it },
                channels = channels,
                programsByKey = programsByKey,
                now = now,
                windowStartEpoch = windowStartEpoch,
                onShiftWindow = { deltaSeconds ->
                    windowStartEpoch = if (deltaSeconds == 0L) (System.currentTimeMillis() / 1000 / 1800) * 1800 else windowStartEpoch + deltaSeconds
                },
                onCloseGrid = { showGrid = false },
                onPlay = onPlay,
                onInspect = { ch, p -> inspected = ch to p },
            )
        } else {
            Row(Modifier.fillMaxSize()) {
                LazyColumn(Modifier.width(320.dp).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    item {
                        Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            PageTitle(if (initial == Library.ChannelScope.Favorites) "Favorites" else "Live TV")
                            OutlinedButton(onClick = {
                                windowStartEpoch = (System.currentTimeMillis() / 1000 / 1800) * 1800
                                showGrid = true
                            }) { Text("TV Guide") }
                        }
                    }
                    items(groups, key = { it.first + it.second }) { (name, grpScope) ->
                        ListItem(
                            selected = grpScope == selected,
                            onClick = { selected = grpScope },
                            onLongClick = { (grpScope as? Library.ChannelScope.InCategory)?.let { menuCategory = liveCategories[it.id] } },
                            headlineContent = { Text(name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            modifier = Modifier.initialFocus(enabled = grpScope == initial).onFocusChanged { if (it.isFocused) selected = grpScope },
                        )
                    }
                }
                Spacer(Modifier.width(32.dp))
                if (channels.isEmpty()) {
                    Placeholder(if (groups.size <= 3) "Add a playlist in Settings to watch live TV." else "No channels here.")
                } else {
                    val firstChannel = remember { FocusRequester() }
                    LazyColumn(Modifier.fillMaxSize().focusRestorer(firstChannel), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        items(channels, key = { it.id }) { ch ->
                            val progs = ch.epgKey?.let { programsByKey[it] }.orEmpty()
                            val current = progs.firstOrNull { it.isLive(now) }
                            val next = progs.firstOrNull { !it.start.isBefore(current?.end ?: now) && it != current }
                            ListItem(
                                selected = false,
                                onClick = { onPlay(PlaybackItem.Live(ch, channels)) },
                                onLongClick = { menuChannel = ch },
                                leadingContent = {
                                    Box(Modifier.size(64.dp, 40.dp).background(TunerColors.surface, RoundedCornerShape(6.dp)), contentAlignment = Alignment.Center) {
                                        if (ch.logoURL != null) AsyncImage(ch.logoURL, null, Modifier.fillMaxSize().padding(4.dp), contentScale = ContentScale.Fit)
                                        else Text(ch.number?.toString() ?: "", color = Color.White.copy(alpha = 0.6f))
                                    }
                                },
                                headlineContent = {
                                    Text((ch.number?.let { "$it  " } ?: "") + ch.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                },
                                // Secondary text follows the row's content colour (dark on the white focused row; it was
                                // fixed white and vanished there).
                                supportingContent = if (current != null || next != null) {
                                    {
                                        Column(Modifier.padding(top = 2.dp)) {
                                            if (current != null) {
                                                Text("${current.title}  ·  ${fmtClock(current.start)}–${fmtClock(current.end)}",
                                                    maxLines = 1, overflow = TextOverflow.Ellipsis, color = LocalContentColor.current.copy(alpha = 0.78f),
                                                    style = MaterialTheme.typography.bodySmall)
                                                Spacer(Modifier.height(4.dp))
                                                Box(Modifier.width(240.dp).height(3.dp).background(LocalContentColor.current.copy(alpha = 0.2f))) {
                                                    Box(Modifier.fillMaxWidth(current.progress(now).toFloat()).height(3.dp).background(TunerColors.accent))
                                                }
                                            }
                                            if (next != null) {
                                                Spacer(Modifier.height(2.dp))
                                                Text("Next · ${fmtClock(next.start)}  ${next.title}", maxLines = 1, overflow = TextOverflow.Ellipsis,
                                                    color = LocalContentColor.current.copy(alpha = 0.6f), style = MaterialTheme.typography.bodySmall)
                                            }
                                        }
                                    }
                                } else null,
                                trailingContent = {
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                                        if (ch.hasCatchup) Text("⟲", color = LocalContentColor.current.copy(alpha = 0.6f))
                                        if (ch.isFavorite) Text("★", color = TunerColors.accent)
                                    }
                                },
                                modifier = Modifier.fillMaxWidth().rememberedFocus(ch.id).then(if (ch.id == channels.first().id) Modifier.focusRequester(firstChannel) else Modifier),
                            )
                        }
                    }
                }
            }
        }

        menuChannel?.let { ch ->
            ItemMenu(ch.displayName, listOf(
                MenuAction(if (ch.isFavorite) "Remove from Favorites" else "Add to Favorites") { scope.launch { app.library.setFavorite(ch.id, !ch.isFavorite) } },
                MenuAction("Rename…") { renamingChannel = ch },
                MenuAction("Hide Channel") { scope.launch { app.library.setChannelHidden(ch.id, true) } },
            )) { menuChannel = null }
        }
        menuCategory?.let { cat ->
            ItemMenu(cat.displayName, listOf(
                MenuAction("Rename…") { renamingCategory = cat },
                MenuAction("Hide Category") { scope.launch { app.library.setCategoryHidden(cat.id, true); selected = Library.ChannelScope.All } },
            )) { menuCategory = null }
        }
        renamingChannel?.let { ch ->
            RenameDialog("Rename Channel", ch.alias ?: "", ch.name, onSave = { scope.launch { app.library.renameChannel(ch.id, it) } }) { renamingChannel = null }
        }
        renamingCategory?.let { cat ->
            RenameDialog("Rename Category", cat.alias ?: "", cat.name, onSave = { scope.launch { app.library.renameCategory(cat.id, it) } }) { renamingCategory = null }
        }

        inspected?.let { (ch, prog) ->
            // Same rule as the Apple guide: started, and still inside the channel's archive (so a live programme can start over).
            val canCatchup = ch.catchupAvailable(prog, now)
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.78f)), contentAlignment = Alignment.Center) {
                Column(Modifier.width(640.dp).background(TunerColors.surface, RoundedCornerShape(18.dp)).padding(28.dp)) {
                    Text(prog.title, style = MaterialTheme.typography.headlineSmall)
                    prog.subtitle?.let { Spacer(Modifier.height(4.dp)); Text(it, color = Color.White.copy(alpha = 0.8f)) }
                    Spacer(Modifier.height(6.dp))
                    Text("${ch.displayName}  ·  ${fmtDayClock(prog.start)}–${fmtClock(prog.end)}", color = TunerColors.accent)
                    prog.summary?.let { Spacer(Modifier.height(12.dp)); Text(it, color = Color.White.copy(alpha = 0.78f), maxLines = 5, overflow = TextOverflow.Ellipsis) }
                    Spacer(Modifier.height(22.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        if (canCatchup) {
                            Button(onClick = { inspected = null; onPlay(PlaybackItem.Catchup(ch, prog)) }, modifier = Modifier.initialFocus(prog.stableKey)) {
                                Text(if (prog.isLive(now)) "Start Over ⟲" else "Play Catchup ⟲")
                            }
                        }
                        Button(onClick = { inspected = null; onPlay(PlaybackItem.Live(ch, channels)) },
                            modifier = if (!canCatchup) Modifier.initialFocus(prog.stableKey) else Modifier) {
                            Text("Watch Live")
                        }
                        OutlinedButton(onClick = { inspected = null }) { Text("Close") }
                    }
                }
            }
        }
    }
}

@Composable
private fun GuideGridView(
    groups: List<Pair<String, Library.ChannelScope>>,
    selected: Library.ChannelScope,
    onSelectGroup: (Library.ChannelScope) -> Unit,
    channels: List<Channel>,
    programsByKey: Map<String, List<Program>>,
    now: Instant,
    windowStartEpoch: Long,
    onShiftWindow: (Long) -> Unit,
    onCloseGrid: () -> Unit,
    onPlay: (PlaybackItem) -> Unit,
    onInspect: (Channel, Program) -> Unit,
) {
    val windowStart = Instant.ofEpochSecond(windowStartEpoch)
    val windowEnd = Instant.ofEpochSecond(windowStartEpoch + 7200)
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                PageTitle("TV Guide")
                OutlinedButton(onClick = onCloseGrid, modifier = Modifier.initialFocus()) { Text("Channels List") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(onClick = { onShiftWindow(-7200) }) { Text("◀ -2h") }
                OutlinedButton(onClick = { onShiftWindow(0) }) { Text("Now") }
                OutlinedButton(onClick = { onShiftWindow(7200) }) { Text("+2h ▶") }
            }
        }
        Spacer(Modifier.height(8.dp))
        LazyRow(Modifier.bleedStart(), horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 4.dp, horizontal = FocusBleed)) {
            items(groups, key = { it.first + it.second }) { (name, grpScope) ->
                FilterChip(selected = grpScope == selected, onClick = { onSelectGroup(grpScope) }) { Text(name) }
            }
        }
        Spacer(Modifier.height(8.dp))
        // Time ruler header (4 x 30 min = 1120 dp)
        Row(Modifier.fillMaxWidth().padding(bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(220.dp)) {
                Text(fmtDayClock(windowStart), color = TunerColors.accent, style = MaterialTheme.typography.titleSmall)
            }
            Spacer(Modifier.width(12.dp))
            for (slot in 0 until 4) {
                val tick = Instant.ofEpochSecond(windowStartEpoch + slot * 1800L)
                Box(Modifier.width(280.dp)) {
                    Text(fmtClock(tick), color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        if (channels.isEmpty()) {
            Placeholder("No channels in this category.")
        } else {
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 36.dp)) {
                items(channels, key = { it.id }) { ch ->
                    val progs = ch.epgKey?.let { programsByKey[it] }.orEmpty()
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Surface(
                            onClick = { onPlay(PlaybackItem.Live(ch, channels)) },
                            shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(8.dp)),
                            colors = ClickableSurfaceDefaults.colors(containerColor = TunerColors.surface, contentColor = Color.White,
                                focusedContainerColor = Color.White, focusedContentColor = Color.Black),
                            scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
                            modifier = Modifier.width(220.dp).height(64.dp),
                        ) {
                            Row(Modifier.fillMaxSize().padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                                if (ch.logoURL != null) {
                                    AsyncImage(ch.logoURL, null, Modifier.size(40.dp, 28.dp), contentScale = ContentScale.Fit)
                                    Spacer(Modifier.width(8.dp))
                                }
                                Text((ch.number?.let { "$it " } ?: "") + ch.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                    style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                        Spacer(Modifier.width(12.dp))
                        if (progs.isEmpty()) {
                            Surface(
                                onClick = { onPlay(PlaybackItem.Live(ch, channels)) },
                                shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(8.dp)),
                                colors = ClickableSurfaceDefaults.colors(containerColor = TunerColors.surface.copy(alpha = 0.6f),
                                    contentColor = Color.White.copy(alpha = 0.5f), focusedContainerColor = Color.White, focusedContentColor = Color.Black),
                                scale = ClickableSurfaceDefaults.scale(focusedScale = 1.01f),
                                modifier = Modifier.width(1120.dp).height(64.dp),
                            ) {
                                Box(Modifier.fillMaxSize().padding(horizontal = 14.dp), contentAlignment = Alignment.CenterStart) {
                                    Text("No program information", style = MaterialTheme.typography.bodySmall)
                                }
                            }
                        } else {
                            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                for (p in progs) {
                                    val clampedStart = maxOf(p.start.epochSecond, windowStart.epochSecond)
                                    val clampedEnd = minOf(p.end.epochSecond, windowEnd.epochSecond)
                                    val secs = (clampedEnd - clampedStart).coerceAtLeast(600L)
                                    val widthDp = ((secs / 7200f) * 1120f).coerceIn(160f, 1120f).dp
                                    val live = p.isLive(now)
                                    val pastCatchup = p.end.isBefore(now) && ch.catchupAvailable(p, now)
                                    Surface(
                                        onClick = {
                                            when {
                                                live -> onPlay(PlaybackItem.Live(ch, channels))
                                                pastCatchup -> onPlay(PlaybackItem.Catchup(ch, p))
                                                else -> onInspect(ch, p)
                                            }
                                        },
                                        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(8.dp)),
                                        colors = ClickableSurfaceDefaults.colors(
                                            containerColor = if (live) TunerColors.surface else TunerColors.surface.copy(alpha = 0.72f),
                                            contentColor = Color.White,
                                            focusedContainerColor = Color.White, focusedContentColor = Color.Black,
                                        ),
                                        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
                                        modifier = Modifier.width(widthDp).height(64.dp),
                                    ) {
                                        Box(Modifier.fillMaxSize()) {
                                            Column(Modifier.fillMaxSize().padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.SpaceBetween) {
                                                Text(p.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                                                val badge = when {
                                                    live -> "  ·  LIVE"
                                                    pastCatchup -> "  ·  ⟲ Catchup"
                                                    else -> ""
                                                }
                                                Text("${fmtClock(p.start)}–${fmtClock(p.end)}$badge", maxLines = 1,
                                                    style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                                            }
                                            if (live) {
                                                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(p.progress(now).toFloat()).height(3.dp).background(TunerColors.accent))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
