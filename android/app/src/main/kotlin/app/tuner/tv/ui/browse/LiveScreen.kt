package app.tuner.tv.ui.browse

import app.tuner.tv.ui.rememberedFocus
import app.tuner.tv.ui.PillButton
import app.tuner.tv.ui.SideListRow
import app.tuner.tv.ui.ProgressLine
import androidx.compose.material.icons.filled.History
import androidx.tv.material3.Icon
import app.tuner.tv.ui.TvDialog
import app.tuner.tv.ui.Eyebrow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarViewWeek
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
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

    BackHandler(enabled = showGrid) { showGrid = false }

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
                Column(Modifier.width(250.dp).fillMaxHeight()) {
                    PageTitle(if (initial == Library.ChannelScope.Favorites) "Favorites" else "Live TV")
                    PillButton("TV Guide", icon = Icons.Filled.CalendarViewWeek, onClick = {
                        windowStartEpoch = (System.currentTimeMillis() / 1000 / 1800) * 1800
                        showGrid = true
                    })
                    Spacer(Modifier.height(14.dp))
                    LazyColumn(Modifier.fillMaxSize().bleedStart(), verticalArrangement = Arrangement.spacedBy(2.dp),
                        contentPadding = PaddingValues(start = FocusBleed, top = 4.dp, bottom = 48.dp)) {
                        items(groups, key = { it.first + it.second }) { (name, grpScope) ->
                            SideListRow(name, grpScope == selected,
                                Modifier.initialFocus(enabled = grpScope == initial).onFocusChanged { if (it.isFocused) selected = grpScope },
                                onLongClick = { (grpScope as? Library.ChannelScope.InCategory)?.let { menuCategory = liveCategories[it.id] } }) { selected = grpScope }
                        }
                    }
                }
                Spacer(Modifier.width(24.dp))
                if (channels.isEmpty()) {
                    Placeholder(if (groups.size <= 3) "No channels yet" else "No channels here",
                        if (groups.size <= 3) "Add a playlist in Settings to watch live TV." else null)
                } else {
                    val firstChannel = remember { FocusRequester() }
                    LazyColumn(Modifier.fillMaxSize().focusRestorer(firstChannel), verticalArrangement = Arrangement.spacedBy(6.dp),
                        contentPadding = PaddingValues(top = 4.dp, bottom = 48.dp, end = 4.dp)) {
                        items(channels, key = { it.id }) { ch ->
                            val progs = ch.epgKey?.let { programsByKey[it] }.orEmpty()
                            val current = progs.firstOrNull { it.isLive(now) }
                            val next = progs.firstOrNull { !it.start.isBefore(current?.end ?: now) && it != current }
                            ChannelRow(ch, current, next, now, onClick = { onPlay(PlaybackItem.Live(ch, channels)) }, onLongClick = { menuChannel = ch },
                                modifier = Modifier.rememberedFocus(ch.id).then(if (ch.id == channels.first().id) Modifier.focusRequester(firstChannel) else Modifier))
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
            TvDialog(onDismiss = { inspected = null }, width = 640.dp) {
                Text("${ch.displayName}  ·  ${fmtDayClock(prog.start)}–${fmtClock(prog.end)}".uppercase(), style = Eyebrow, color = TunerColors.secondary)
                Spacer(Modifier.height(8.dp))
                Text(prog.title, style = MaterialTheme.typography.headlineSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                prog.subtitle?.let { Spacer(Modifier.height(4.dp)); Text(it, color = TunerColors.secondary) }
                prog.summary?.let { Spacer(Modifier.height(12.dp)); Text(it, color = Color.White.copy(alpha = 0.8f), maxLines = 5, overflow = TextOverflow.Ellipsis) }
                Spacer(Modifier.height(24.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (canCatchup) {
                        PillButton(if (prog.isLive(now)) "Start Over" else "Play Catchup", icon = Icons.Filled.Replay,
                            onClick = { inspected = null; onPlay(PlaybackItem.Catchup(ch, prog)) }, modifier = Modifier.initialFocus(prog.stableKey))
                    }
                    PillButton("Watch Live", icon = Icons.Filled.PlayArrow, onClick = { inspected = null; onPlay(PlaybackItem.Live(ch, channels)) },
                        modifier = if (!canCatchup) Modifier.initialFocus(prog.stableKey) else Modifier)
                }
            }
        }
    }
}

/**
 * One channel: its logo on a tile, number and name, the programme on now with its progress, and what's next. Quiet
 * until focused, then white with dark text (secondary lines follow the row's content colour so they stay readable).
 */
@Composable
private fun ChannelRow(ch: Channel, current: Program?, next: Program?, now: Instant, onClick: () -> Unit, onLongClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick, onLongClick = onLongClick, modifier = modifier.fillMaxWidth().height(78.dp),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(14.dp)),
        colors = ClickableSurfaceDefaults.colors(containerColor = Color.White.copy(alpha = 0.05f), contentColor = Color.White,
            focusedContainerColor = Color.White, focusedContentColor = TunerColors.onFocus),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
    ) {
        Row(Modifier.fillMaxSize().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(96.dp, 54.dp).background(Color.Black.copy(alpha = 0.35f), RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) {
                if (ch.logoURL != null) AsyncImage(ch.logoURL, null, Modifier.fillMaxSize().padding(6.dp), contentScale = ContentScale.Fit)
                else Text(ch.number?.toString() ?: ch.displayName.take(2), style = MaterialTheme.typography.titleSmall, color = Color.White.copy(alpha = 0.6f))
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ch.number?.let { Text("$it", style = MaterialTheme.typography.titleSmall, color = LocalContentColor.current.copy(alpha = 0.55f)); Spacer(Modifier.width(8.dp)) }
                    Text(ch.displayName, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    if (ch.isFavorite) { Spacer(Modifier.width(8.dp)); Text("★", color = TunerColors.accent, style = MaterialTheme.typography.titleSmall) }
                }
                if (current != null) {
                    Spacer(Modifier.height(3.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(current.title, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            color = LocalContentColor.current.copy(alpha = 0.8f), modifier = Modifier.weight(1f, fill = false))
                        Spacer(Modifier.width(10.dp))
                        Box(Modifier.width(64.dp)) { ProgressLine(current.progress(now), color = TunerColors.accent) }
                    }
                }
                if (next != null) Text("Next  ${fmtClock(next.start)}  ${next.title}", style = MaterialTheme.typography.bodySmall, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, color = LocalContentColor.current.copy(alpha = 0.5f))
                if (current == null && next == null) Text("No programme information", style = MaterialTheme.typography.bodySmall,
                    color = LocalContentColor.current.copy(alpha = 0.45f))
            }
            if (ch.hasCatchup) Icon(Icons.Filled.History, "Catchup", Modifier.padding(start = 12.dp).size(20.dp), tint = LocalContentColor.current.copy(alpha = 0.5f))
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
                PillButton("Channels List", onClick = onCloseGrid, modifier = Modifier.initialFocus())
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                PillButton("◀ -2h", onClick = { onShiftWindow(-7200) })
                PillButton("Now", onClick = { onShiftWindow(0) })
                PillButton("+2h ▶", onClick = { onShiftWindow(7200) })
            }
        }
        Spacer(Modifier.height(8.dp))
        LazyRow(Modifier.bleedStart(), horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 4.dp, horizontal = FocusBleed)) {
            items(groups, key = { it.first + it.second }) { (name, grpScope) ->
                PillButton(name, onClick = { onSelectGroup(grpScope) }, selected = grpScope == selected)
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
