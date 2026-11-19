package app.tuner.tv.ui.browse

import app.tuner.tv.ui.rememberedFocus
import app.tuner.tv.ui.PillButton
import app.tuner.tv.ui.rememberScreenState
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
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.Key
import androidx.compose.runtime.derivedStateOf
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.BoxWithConstraints
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
import app.tuner.tv.ui.focusWhenReady
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
    // Lists start from what this page last showed (ScreenMemory), so coming back draws them at once.
    val memory = app.screens
    var groups by rememberScreenState("live.groups") { emptyList<Pair<String, Library.ChannelScope>>() }
    var selected by remember { mutableStateOf(initial) }
    var channels by remember { mutableStateOf(memory["live.channels.$initial"] ?: emptyList<Channel>()) }
    var programsByKey by remember { mutableStateOf(memory["live.programs.$initial"] ?: emptyMap<String, List<Program>>()) }
    var revision by remember { mutableStateOf(0) }
    var guideRevision by remember { mutableStateOf(0) }
    var showGrid by remember { mutableStateOf(false) }
    var inspected by remember { mutableStateOf<Pair<Channel, Program>?>(null) }
    // Long-press menus (favourite, hide, rename) and the rename dialog.
    var menuChannel by remember { mutableStateOf<Channel?>(null) }
    var menuCategory by remember { mutableStateOf<app.tuner.core.models.Category?>(null) }
    var renamingChannel by remember { mutableStateOf<Channel?>(null) }
    var renamingCategory by remember { mutableStateOf<app.tuner.core.models.Category?>(null) }
    var liveCategories by rememberScreenState("live.categories") { emptyMap<String, app.tuner.core.models.Category>() }
    var nowEpoch by remember { mutableLongStateOf(System.currentTimeMillis() / 1000) }
    // The guide's window start, rounded down to 30 minutes (it shows GUIDE_SPAN seconds from there).
    var windowStartEpoch by remember { mutableLongStateOf((System.currentTimeMillis() / 1000 / 1800) * 1800) }
    // The category focus rests on. Moving through the list switches category only once focus settles: every category
    // passed over used to load (and lay out) its channels, so going down the list stuttered at each step.
    var focusedScope by remember { mutableStateOf(initial) }
    LaunchedEffect(focusedScope) { if (focusedScope != selected) { delay(250); selected = focusedScope } }
    val channelList = rememberLazyListState()
    val guideList = rememberLazyListState()
    LaunchedEffect(selected) { channelList.scrollToItem(0); guideList.scrollToItem(0) }
    // Guide data is loaded for the channels around the ones on screen (in steps of 20 rows), not for the whole
    // category: "All Channels" asked for every channel's programmes at each change and every five minutes.
    val firstVisible by remember { derivedStateOf { (if (showGrid) guideList else channelList).firstVisibleItemIndex } }
    val programmeStep = firstVisible / 20
    var programmesFor by remember { mutableStateOf<Any?>(null) }

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
        channels = app.library.channels(selected).also { memory["live.channels.$selected"] = it }
    }
    LaunchedEffect(channels, guideRevision, windowStartEpoch, showGrid, nowEpoch / 300, programmeStep) {
        val start = ((programmeStep - 1) * 20).coerceIn(0, channels.size)
        val end = ((programmeStep + 3) * 20).coerceIn(start, channels.size)
        val keys = channels.subList(start, end).mapNotNull { it.epgKey }.distinct()
        val from = if (showGrid) Instant.ofEpochSecond(windowStartEpoch) else Instant.ofEpochSecond(nowEpoch - 1800)
        val to = if (showGrid) Instant.ofEpochSecond(windowStartEpoch + GUIDE_SPAN) else Instant.ofEpochSecond(nowEpoch + 6 * 3600)
        val loaded = if (keys.isEmpty()) emptyMap() else app.library.programs(keys, from, to)
        // Rows loaded earlier for the same list, guide and window are kept as focus moves down the list.
        val loadedFor = listOf(System.identityHashCode(channels), showGrid, windowStartEpoch, guideRevision)
        val sameList = programmesFor == loadedFor
        val updated = (if (sameList) programsByKey - keys.toSet() else emptyMap()) + loaded
        // Unchanged (most steps down a list without guide data): don't redraw every row mid-scroll.
        if (updated != programsByKey) programsByKey = updated
        programmesFor = loadedFor
        if (!showGrid) memory["live.programs.$selected"] = programsByKey
    }

    BackHandler(enabled = showGrid) { showGrid = false }

    val now = Instant.ofEpochSecond(nowEpoch)

    Box(Modifier.fillMaxSize()) {
        if (showGrid) {
            GuideGridView(
                groups = groups,
                selected = selected,
                onSelectGroup = { selected = it; focusedScope = it },
                listState = guideList,
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
                                Modifier.initialFocus(enabled = grpScope == initial).onFocusChanged { if (it.isFocused) focusedScope = grpScope },
                                onLongClick = { (grpScope as? Library.ChannelScope.InCategory)?.let { menuCategory = liveCategories[it.id] } }) { selected = grpScope; focusedScope = grpScope }
                        }
                    }
                }
                Spacer(Modifier.width(24.dp))
                if (channels.isEmpty()) {
                    Placeholder(if (groups.size <= 3) "No channels yet" else "No channels here",
                        if (groups.size <= 3) "Add a playlist in Settings to watch live TV." else null)
                } else {
                    val firstChannel = remember { FocusRequester() }
                    LazyColumn(Modifier.fillMaxSize().focusRestorer(firstChannel), state = channelList, verticalArrangement = Arrangement.spacedBy(6.dp),
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

/** How much of the day the guide shows at once: 90 minutes fit the screen beside the channel column. */
private const val GUIDE_SPAN = 5400L
private const val GUIDE_STEP = 1800L
private val GUIDE_ROW = 60.dp
private val GUIDE_CHANNEL = 200.dp

/** A programme to focus once the guide's window has moved: the one on `channelId` that covers `epoch`. */
private data class GuideFocus(val channelId: String, val epoch: Long)

/**
 * The TV Guide: one timeline shared by every row, sized to fit the screen, so programmes line up with the time ruler
 * and with each other, and Up/Down lands on what's on at the same time on the next channel. Right from a row's last
 * programme (or Left from its first, when the window is ahead of now) moves the window by 30 minutes and focuses the
 * next (or previous) programme. Each row used to scroll sideways on its own over a timeline twice the screen's width,
 * so moving right on one channel slid it out of line with the ruler and the rows around it.
 */
@Composable
private fun GuideGridView(
    groups: List<Pair<String, Library.ChannelScope>>,
    selected: Library.ChannelScope,
    onSelectGroup: (Library.ChannelScope) -> Unit,
    listState: androidx.compose.foundation.lazy.LazyListState,
    channels: List<Channel>,
    programsByKey: Map<String, List<Program>>,
    now: Instant,
    windowStartEpoch: Long,
    onShiftWindow: (Long) -> Unit,
    onCloseGrid: () -> Unit,
    onPlay: (PlaybackItem) -> Unit,
    onInspect: (Channel, Program) -> Unit,
) {
    val windowEnd = windowStartEpoch + GUIDE_SPAN
    var pendingFocus by remember { mutableStateOf<GuideFocus?>(null) }
    val nowSlot = now.epochSecond / GUIDE_STEP * GUIDE_STEP
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                PageTitle("TV Guide")
                PillButton("Channels List", onClick = onCloseGrid)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                PillButton("Earlier", onClick = { onShiftWindow(-3600) })
                PillButton("Now", onClick = { onShiftWindow(0) })
                PillButton("Later", onClick = { onShiftWindow(3600) })
            }
        }
        Spacer(Modifier.height(6.dp))
        LazyRow(Modifier.bleedStart(), horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 6.dp, horizontal = FocusBleed)) {
            items(groups, key = { it.first + it.second }) { (name, grpScope) ->
                PillButton(name, onClick = { onSelectGroup(grpScope) }, selected = grpScope == selected)
            }
        }
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val timeline = maxWidth - GUIDE_CHANNEL - 12.dp
            val perSecond = timeline / GUIDE_SPAN.toFloat()
            Column(Modifier.fillMaxSize()) {
                // Time ruler: a tick every 30 minutes, and where "now" falls.
                Row(Modifier.fillMaxWidth().height(30.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(fmtDayClock(Instant.ofEpochSecond(windowStartEpoch)), Modifier.width(GUIDE_CHANNEL + 12.dp), color = TunerColors.accent,
                        style = MaterialTheme.typography.titleSmall)
                    Box(Modifier.width(timeline).fillMaxHeight()) {
                        var tick = windowStartEpoch
                        while (tick < windowEnd) {
                            Text(fmtClock(Instant.ofEpochSecond(tick)), Modifier.offset(x = perSecond * (tick - windowStartEpoch).toFloat()).align(Alignment.CenterStart),
                                color = TunerColors.secondary, style = MaterialTheme.typography.bodyMedium)
                            tick += GUIDE_STEP
                        }
                    }
                }
                if (channels.isEmpty()) {
                    Placeholder("No channels in this category.")
                } else {
                    LazyColumn(Modifier.fillMaxSize(), state = listState, verticalArrangement = Arrangement.spacedBy(6.dp), contentPadding = PaddingValues(top = 6.dp, bottom = 36.dp)) {
                        itemsIndexed(channels, key = { _, ch -> ch.id }) { index, ch ->
                            val progs = ch.epgKey?.let { programsByKey[it] }.orEmpty().filter { it.end.epochSecond > windowStartEpoch && it.start.epochSecond < windowEnd }
                            Row(Modifier.fillMaxWidth().height(GUIDE_ROW), verticalAlignment = Alignment.CenterVertically) {
                                GuideCell(onClick = { onPlay(PlaybackItem.Live(ch, channels)) }, modifier = Modifier.width(GUIDE_CHANNEL).fillMaxHeight(),
                                    focusedScale = 1.03f) {
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
                                Box(Modifier.width(timeline).fillMaxHeight()) {
                                    if (progs.isEmpty()) {
                                        GuideCell(onClick = { onPlay(PlaybackItem.Live(ch, channels)) }, modifier = Modifier.fillMaxSize()
                                            .initialFocus(enabled = index == 0), quiet = true) {
                                            Box(Modifier.fillMaxSize().padding(horizontal = 14.dp), contentAlignment = Alignment.CenterStart) {
                                                Text("No programme information", style = MaterialTheme.typography.bodySmall)
                                            }
                                        }
                                    }
                                    progs.forEachIndexed { i, p ->
                                        val from = maxOf(p.start.epochSecond, windowStartEpoch)
                                        val to = minOf(p.end.epochSecond, windowEnd)
                                        val live = p.isLive(now)
                                        val pastCatchup = p.end.isBefore(now) && ch.catchupAvailable(p, now)
                                        val requester = remember { FocusRequester() }
                                        val target = pendingFocus
                                        if (target != null && target.channelId == ch.id && target.epoch >= p.start.epochSecond && target.epoch < p.end.epochSecond) {
                                            LaunchedEffect(target) { requester.focusWhenReady(); pendingFocus = null }
                                        }
                                        GuideCell(
                                            onClick = {
                                                when {
                                                    live -> onPlay(PlaybackItem.Live(ch, channels))
                                                    pastCatchup -> onPlay(PlaybackItem.Catchup(ch, p))
                                                    else -> onInspect(ch, p)
                                                }
                                            },
                                            onLongClick = { onInspect(ch, p) },
                                            modifier = Modifier.offset(x = perSecond * (from - windowStartEpoch).toFloat())
                                                .width((perSecond * (to - from).toFloat() - 4.dp).coerceAtLeast(6.dp)).fillMaxHeight()
                                                .focusRequester(requester)
                                                .initialFocus(enabled = index == 0 && live)
                                                .onPreviewKeyEvent { e ->
                                                    if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                                    when {
                                                        // Right from the last programme in view: 30 minutes later, focus on what follows.
                                                        e.key == Key.DirectionRight && i == progs.lastIndex && p.end.epochSecond >= windowEnd -> {
                                                            pendingFocus = GuideFocus(ch.id, p.end.epochSecond); onShiftWindow(GUIDE_STEP); true
                                                        }
                                                        // Left from the first, when the window is ahead of now: 30 minutes earlier.
                                                        e.key == Key.DirectionLeft && i == 0 && windowStartEpoch > nowSlot && p.start.epochSecond <= windowStartEpoch -> {
                                                            pendingFocus = GuideFocus(ch.id, windowStartEpoch - 1); onShiftWindow(-GUIDE_STEP); true
                                                        }
                                                        else -> false
                                                    }
                                                },
                                            quiet = !live,
                                        ) {
                                            Box(Modifier.fillMaxSize()) {
                                                Column(Modifier.fillMaxSize().padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.SpaceBetween) {
                                                    Text(p.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                                                    Text("${fmtClock(p.start)}–${fmtClock(p.end)}" + if (pastCatchup) "  ·  Catchup" else "", maxLines = 1,
                                                        style = MaterialTheme.typography.bodySmall, color = LocalContentColor.current.copy(alpha = 0.6f))
                                                }
                                                if (live) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(p.progress(now).toFloat()).height(3.dp).background(TunerColors.accent))
                                            }
                                        }
                                    }
                                    // Now, as a line through the row.
                                    if (now.epochSecond in windowStartEpoch until windowEnd) {
                                        Box(Modifier.offset(x = perSecond * (now.epochSecond - windowStartEpoch).toFloat()).width(2.dp).fillMaxHeight()
                                            .background(TunerColors.accent.copy(alpha = 0.8f)))
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

/** A guide cell: quiet until focused, then white with dark text. The programme on now sits a little brighter. */
@Composable
private fun GuideCell(onClick: () -> Unit, modifier: Modifier, onLongClick: (() -> Unit)? = null, quiet: Boolean = false, focusedScale: Float = 1f,
                      content: @Composable androidx.compose.foundation.layout.BoxScope.() -> Unit) {
    Surface(
        onClick = onClick, onLongClick = onLongClick, modifier = modifier,
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(10.dp)),
        colors = ClickableSurfaceDefaults.colors(containerColor = if (quiet) Color.White.copy(alpha = 0.05f) else Color.White.copy(alpha = 0.11f),
            contentColor = Color.White, focusedContainerColor = Color.White, focusedContentColor = TunerColors.onFocus),
        scale = ClickableSurfaceDefaults.scale(focusedScale = focusedScale),
    ) { Box(Modifier.fillMaxSize(), content = content) }
}
