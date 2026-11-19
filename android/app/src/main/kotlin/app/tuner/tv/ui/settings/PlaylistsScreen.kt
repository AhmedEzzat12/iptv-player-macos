package app.tuner.tv.ui.settings

import app.tuner.tv.ui.ConfirmDialog
import app.tuner.tv.ui.PillButton
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.ime
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import app.tuner.core.models.Channel
import app.tuner.core.models.CategoryKind
import androidx.compose.foundation.layout.PaddingValues
import androidx.tv.material3.ListItem
import app.tuner.core.skip.SkipMode
import app.tuner.tv.ui.PageTitle
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text
import app.tuner.core.models.Source
import app.tuner.core.providers.XtreamURLs
import app.tuner.tv.app
import app.tuner.tv.share.PlaylistShareServer
import app.tuner.tv.ui.TunerColors
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.material.icons.filled.Add
import androidx.compose.foundation.focusGroup
import androidx.compose.ui.focus.focusProperties
import app.tuner.tv.ui.Eyebrow
import app.tuner.tv.ui.SideListRow
import app.tuner.tv.ui.initialFocus
import app.tuner.tv.ui.focusWhenReady
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** Settings' panes, in the order of the list on the left. */
private enum class SettingsPane(val title: String) { PLAYLISTS("Playlists"), PLAYBACK("Playback"), GUIDE("Guide & Library"), HIDDEN("Hidden"), ABOUT("About") }

/**
 * Settings, as on the Apple TV: the panes in a list on the left, the chosen pane on the right (Appendix D → Settings).
 * Moving through the list shows each pane; Right goes into it and Left comes back. It was one long list of oversized
 * rows whose focused row grew past the screen's edge.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun PlaylistsScreen(onAdd: () -> Unit, onEdit: (String) -> Unit) {
    val app = LocalContext.current.app
    val prefs = app.prefs
    val scope = rememberCoroutineScope()
    var sources by remember { mutableStateOf<List<Source>>(emptyList()) }
    val progress by app.sync.progress.collectAsState()
    var revision by remember { mutableStateOf(0) }
    var pendingRemove by remember { mutableStateOf<Source?>(null) }
    var hiddenChannels by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var hiddenCategories by remember { mutableStateOf<List<Triple<String, String, CategoryKind>>>(emptyList()) }
    var pane by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(SettingsPane.PLAYLISTS) }
    LaunchedEffect(revision, progress?.done) { sources = app.library.sources() }
    LaunchedEffect(Unit) { app.database.changes.collect { revision++ } }
    LaunchedEffect(revision) {
        hiddenChannels = app.library.hiddenChannels()
        hiddenCategories = app.library.hiddenCategories()
    }
    val paneFocus = remember { SettingsPane.entries.associateWith { androidx.compose.ui.focus.FocusRequester() } }

    Row(Modifier.fillMaxSize()) {
        Column(Modifier.width(250.dp).fillMaxHeight()) {
            PageTitle("Settings")
            Spacer(Modifier.height(8.dp))
            // Entering the list lands on the open pane, not on whichever row is level with the focused setting.
            Column(Modifier.focusProperties { enter = { paneFocus.getValue(pane) } }.focusGroup(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                SettingsPane.entries.forEach { p ->
                    SideListRow(p.title, p == pane, Modifier.focusRequester(paneFocus.getValue(p)).initialFocus(enabled = p == SettingsPane.PLAYLISTS)
                        .onFocusChanged { if (it.isFocused) pane = p }) { pane = p }
                }
            }
        }
        Spacer(Modifier.width(32.dp))
        LazyColumn(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(6.dp), contentPadding = PaddingValues(top = 58.dp, bottom = 48.dp, end = 8.dp)) {
            when (pane) {
                SettingsPane.PLAYLISTS -> {
                    item { PillButton("Add a Playlist", icon = androidx.compose.material.icons.Icons.Filled.Add, onClick = onAdd) }
                    item { Spacer(Modifier.height(6.dp)) }
                    if (sources.isEmpty()) item { PaneNote("No playlists yet. Add one from your phone, or type it in.") }
                    items(sources, key = { it.id }) { s ->
                        Column(Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(18.dp)).padding(22.dp)) {
                            Text(s.kind.displayName.uppercase() + "  ·  " + host(s.url), style = Eyebrow, color = TunerColors.secondary)
                            Spacer(Modifier.height(6.dp))
                            Text(s.name, style = MaterialTheme.typography.titleLarge)
                            Spacer(Modifier.height(4.dp))
                            val counts = "${s.channelCount} channels · ${s.movieCount} movies · ${s.seriesCount} shows"
                            val synced = s.lastSyncedAt?.let { " · updated " + DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it.toEpochMilli())) } ?: ""
                            Text(counts + synced, color = TunerColors.secondary, style = MaterialTheme.typography.bodyMedium)
                            s.expiresAt?.let { Text("Expires " + DateFormat.getDateInstance().format(Date(it.toEpochMilli())), color = TunerColors.secondary, style = MaterialTheme.typography.bodyMedium) }
                            if (progress?.sourceId == s.id && progress?.done == false) Text(progress!!.step, color = TunerColors.accent, style = MaterialTheme.typography.bodyMedium)
                            if (s.needsPassword) Text("Password needed: add the playlist again", color = Color(0xFFFFB74D), style = MaterialTheme.typography.bodyMedium)
                            s.lastError?.let { Text(it, color = Color(0xFFFF6E6E), maxLines = 3, style = MaterialTheme.typography.bodyMedium) }
                            Spacer(Modifier.height(14.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                PillButton("Refresh", onClick = { scope.launch { app.sync.sync(s.id); revision++ } }) // sync runs off the main thread
                                PillButton("Edit", onClick = { onEdit(s.id) })
                                PillButton("Remove", onClick = { pendingRemove = s })
                            }
                        }
                    }
                }
                SettingsPane.PLAYBACK -> {
                    item {
                        OptionRow("Live stream format", if (prefs.liveFormat == "hls") "HLS" else "Automatic (TS, then HLS)",
                            "Xtream live channels. Try HLS if channels stutter or won't start.") {
                            prefs.liveFormat = if (prefs.liveFormat == "hls") "ts" else "hls"
                        }
                    }
                    item {
                        OptionRow("Automatic failover", onOff(prefs.autoFailover), "When a live stream stops, try the channel in your other playlists.") {
                            prefs.autoFailover = !prefs.autoFailover
                        }
                    }
                    item { OptionRow("Resume where you left off", onOff(prefs.resumePlayback)) { prefs.resumePlayback = !prefs.resumePlayback } }
                    item { OptionRow("Play the next episode automatically", onOff(prefs.autoplayNextEpisode)) { prefs.autoplayNextEpisode = !prefs.autoplayNextEpisode } }
                    item {
                        OptionRow("“Up Next” countdown", if (prefs.upNextCountdown == 0) "Off" else "${prefs.upNextCountdown} seconds") {
                            prefs.upNextCountdown = cycle(listOf(0, 5, 10, 15, 20, 30), prefs.upNextCountdown)
                        }
                    }
                    item {
                        OptionRow("Skip intro and credits", when (prefs.skipSegments) {
                            SkipMode.BUTTON -> "Show a button"; SkipMode.AUTOMATIC -> "Skip automatically"; SkipMode.OFF -> "Off"
                        }, "Timings come from public intro databases, when they know the title.") {
                            prefs.skipSegmentsRaw = cycle(SkipMode.entries.map { it.raw }, prefs.skipSegmentsRaw)
                        }
                    }
                }
                SettingsPane.GUIDE -> {
                    item {
                        OptionRow("Refresh channels and guide", refreshTitle(prefs.liveRefreshHours), "Checked when the app starts.") {
                            prefs.liveRefreshHours = cycle(listOf(0, 3, 6, 12, 24), prefs.liveRefreshHours)
                        }
                    }
                    item {
                        OptionRow("Refresh movies and shows", refreshTitle(prefs.vodRefreshHours)) {
                            prefs.vodRefreshHours = cycle(listOf(0, 12, 24, 48, 168), prefs.vodRefreshHours)
                        }
                    }
                }
                SettingsPane.HIDDEN -> {
                    if (hiddenChannels.isEmpty() && hiddenCategories.isEmpty()) {
                        item { PaneNote("Nothing is hidden. Hold OK on a channel or category to hide it.") }
                    }
                    items(hiddenCategories, key = { "cat" + it.first }) { (id, name, kind) ->
                        val where = when (kind) { CategoryKind.LIVE -> "Live TV category"; CategoryKind.MOVIE -> "Movies category"; else -> "TV Shows category" }
                        OptionRow(name, "Show", where) { scope.launch { app.library.setCategoryHidden(id, false) } }
                    }
                    items(hiddenChannels, key = { "ch" + it.id }) { ch ->
                        OptionRow(ch.displayName, "Show", "Channel") { scope.launch { app.library.setChannelHidden(ch.id, false) } }
                    }
                }
                SettingsPane.ABOUT -> {
                    item {
                        val context = LocalContext.current
                        val info = remember { runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull() }
                        Column(Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(18.dp)).padding(22.dp)) {
                            Text("Antenna", style = MaterialTheme.typography.headlineSmall)
                            Spacer(Modifier.height(4.dp))
                            Text("Version ${info?.versionName ?: "?"} (${info?.longVersionCode ?: 0})", color = TunerColors.secondary, style = MaterialTheme.typography.bodyMedium)
                            Spacer(Modifier.height(14.dp))
                            Text("You're responsible for the playlists you add. Antenna doesn't provide any channels or content.",
                                color = TunerColors.secondary, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }
        }
    }

    pendingRemove?.let { s ->
        ConfirmDialog("Remove “${s.name}”?", "Its channels, movies, shows and guide are removed from Antenna. You can add it again at any time.",
            "Remove Playlist", onConfirm = { scope.launch { app.library.deleteSource(s.id); revision++ } }) { pendingRemove = null }
    }
}

@Composable
private fun PaneNote(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = TunerColors.secondary, modifier = Modifier.padding(vertical = 8.dp))
}

/**
 * A setting: OK moves to the next value. Compact, quiet until focused, then white; it doesn't grow, so it stays inside
 * the page (ListItem's focused row ran past the screen's edge).
 */
@Composable
private fun OptionRow(title: String, value: String, detail: String? = null, onClick: () -> Unit) {
    androidx.tv.material3.Surface(
        onClick = onClick, modifier = Modifier.fillMaxWidth().height(if (detail != null) 64.dp else 52.dp),
        shape = androidx.tv.material3.ClickableSurfaceDefaults.shape(RoundedCornerShape(14.dp)),
        colors = androidx.tv.material3.ClickableSurfaceDefaults.colors(containerColor = Color.White.copy(alpha = 0.06f), contentColor = Color.White,
            focusedContainerColor = Color.White, focusedContentColor = TunerColors.onFocus),
        scale = androidx.tv.material3.ClickableSurfaceDefaults.scale(focusedScale = 1f),
    ) {
        Row(Modifier.fillMaxSize().padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (detail != null) Text(detail, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = androidx.tv.material3.LocalContentColor.current.copy(alpha = 0.6f))
            }
            Spacer(Modifier.width(16.dp))
            Text(value, style = MaterialTheme.typography.bodyMedium, color = androidx.tv.material3.LocalContentColor.current.copy(alpha = 0.7f))
        }
    }
}

private fun onOff(on: Boolean) = if (on) "On" else "Off"
private fun <T> cycle(values: List<T>, current: T): T = values[(values.indexOf(current) + 1).mod(values.size)]
private fun refreshTitle(hours: Int) = when {
    hours == 0 -> "Manually"
    hours % 24 == 0 && hours >= 24 -> if (hours == 24) "Every day" else if (hours == 168) "Every week" else "Every ${hours / 24} days"
    else -> "Every $hours hours"
}

private fun host(url: String) = runCatching { java.net.URI(url.trim()).host }.getOrNull() ?: "local file"

/**
 * Add a playlist: a QR code for the phone (camera page or Antenna's Send to TV) next to "Type It In Instead".
 * What arrives is shown for confirmation (name, type, host; never the password), then tested, saved and synced.
 */
@Composable
fun AddPlaylistScreen(onDone: () -> Unit) {
    val app = LocalContext.current.app
    val scope = rememberCoroutineScope()
    var received by remember { mutableStateOf<Source?>(null) }
    var typing by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    val server = remember { PlaylistShareServer(app.scope) { received = it } }
    var url by remember { mutableStateOf<String?>(null) }
    DisposableEffect(Unit) {
        url = server.start()
        onDispose { server.stop() }
    }

    fun add(source: Source) {
        scope.launch {
            status = "Checking the playlist…"
            val error = app.sync.test(source)
            if (error != null) {
                status = error
                return@launch
            }
            app.library.save(source)
            status = "Added. Loading channels…"
            app.scope.launch { app.sync.sync(source.id) }
            onDone()
        }
    }

    val pending = received
    when {
        pending != null -> Column {
            PageTitle("Add this playlist?")
            Spacer(Modifier.height(16.dp))
            Text(pending.name, style = MaterialTheme.typography.headlineSmall)
            Text("${pending.kind.displayName} · ${host(pending.url)}", color = Color.White.copy(alpha = 0.7f))
            Spacer(Modifier.height(24.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                PillButton("Add Playlist", onClick = { add(pending) }, modifier = Modifier.initialFocus(pending))
                PillButton("Discard", onClick = { received = null; onDone() })
            }
            status?.let { Spacer(Modifier.height(16.dp)); Text(it, color = TunerColors.accent) }
        }
        typing -> TypeItIn(status) { add(it) }
        else -> Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(48.dp)) {
            Column(Modifier.weight(1f)) {
                PageTitle("Add a Playlist")
                Spacer(Modifier.height(20.dp))
                if (url != null) {
                    Text("Scan with your phone's camera, or use Send to TV in Antenna on your iPhone or iPad.", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(12.dp))
                    Text("Or open $url on a phone or computer on the same Wi-Fi.", color = Color.White.copy(alpha = 0.7f))
                    Spacer(Modifier.height(12.dp))
                    Text("Waiting for your phone…", color = TunerColors.accent)
                } else {
                    Text("Connect the TV to your network to add a playlist from your phone.", style = MaterialTheme.typography.titleMedium)
                }
                Spacer(Modifier.height(28.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    PillButton("Type It In Instead", onClick = { typing = true }, modifier = Modifier.initialFocus())
                    PillButton("Cancel", onClick = onDone)
                }
            }
            url?.let { link ->
                val bitmap = remember(link) { qr(link, 512) }
                Box(Modifier.background(Color.White, RoundedCornerShape(16.dp)).padding(16.dp)) {
                    Image(bitmap.asImageBitmap(), "QR code", Modifier.size(320.dp))
                }
            }
        }
    }
}

private fun qr(text: String, size: Int): Bitmap {
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
    val pixels = IntArray(size * size) { i -> if (matrix[i % size, i / size]) android.graphics.Color.BLACK else android.graphics.Color.WHITE }
    return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
}

/** The on-TV form: one field per row, the on-screen keyboard for each. */
/**
 * Edit a playlist (Apple: the source editor): name, address, account, guide address, and whether it adds live TV
 * and movies & shows. An empty password field keeps the saved password. Saving refreshes the playlist.
 */
@Composable
fun EditPlaylistScreen(id: String, onDone: () -> Unit) {
    val app = LocalContext.current.app
    val scope = rememberCoroutineScope()
    var source by remember { mutableStateOf<Source?>(null) }
    LaunchedEffect(id) { source = app.library.source(id) }
    val s = source ?: return
    var name by remember(s.id) { mutableStateOf(s.name) }
    var url by remember(s.id) { mutableStateOf(s.url) }
    var username by remember(s.id) { mutableStateOf(s.username ?: "") }
    var password by remember(s.id) { mutableStateOf("") }
    var mac by remember(s.id) { mutableStateOf(s.mac ?: "") }
    var epg by remember(s.id) { mutableStateOf(s.epgURL ?: "") }
    var includeLive by remember(s.id) { mutableStateOf(s.includeLive) }
    var includeVOD by remember(s.id) { mutableStateOf(s.includeVOD) }
    var error by remember { mutableStateOf<String?>(null) }

    LazyColumn(Modifier.imePadding(), verticalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(bottom = 240.dp)) {
        item { PageTitle("Edit Playlist") }
        item { Text(s.kind.displayName, color = Color.White.copy(alpha = 0.6f)) }
        item { Field("Name", name, initialFocus = true) { name = it } }
        item { Field(when (s.kind) { Source.Kind.M3U -> "Playlist URL"; Source.Kind.STALKER -> "Portal URL"; else -> "Server URL" }, url, KeyboardType.Uri) { url = it } }
        if (s.kind == Source.Kind.XTREAM) {
            item { Field("Username", username) { username = it } }
            item { Field(if (s.password != null) "Password (leave empty to keep it)" else "Password", password, secret = true) { password = it } }
        }
        if (s.kind == Source.Kind.STALKER) item { Field("MAC address", mac) { mac = it.uppercase() } }
        item { Field("Guide (XMLTV) URL, optional", epg, KeyboardType.Uri) { epg = it } }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                PillButton("Live TV: " + if (includeLive) "On" else "Off", onClick = { includeLive = !includeLive })
                if (s.kind != Source.Kind.M3U) PillButton("Movies & Shows: " + if (includeVOD) "On" else "Off", onClick = { includeVOD = !includeVOD })
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                PillButton("Save", onClick = {
                    if (url.isBlank()) { error = "Enter the playlist's address."; return@PillButton }
                    scope.launch {
                        // Apply the edits to the playlist as it is now: a refresh may have updated its counts and sync
                        // times since this page opened, and those mustn't be rolled back.
                        val current = app.library.source(s.id) ?: s
                        val updated = current.copy(
                            name = name.ifBlank { s.kind.displayName }, url = url.trim(), username = username.trim().ifEmpty { null },
                            password = password.ifEmpty { current.password }, mac = mac.trim().ifEmpty { null }, epgURL = epg.trim().ifEmpty { null },
                            includeLive = includeLive, includeVOD = includeVOD,
                            needsPassword = current.needsPassword && password.isEmpty(),
                        )
                        app.library.save(updated)
                        app.scope.launch { runCatching { app.sync.sync(updated.id) } }
                        onDone()
                    }
                })
                PillButton("Cancel", onClick = onDone)
            }
        }
        error?.let { item { Text(it, color = Color(0xFFFF6E6E)) } }
    }
}

@Composable
private fun TypeItIn(status: String?, onAdd: (Source) -> Unit) {
    var kind by remember { mutableStateOf(Source.Kind.XTREAM) }
    var name by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var mac by remember { mutableStateOf("") }
    // imePadding: the TV keyboard covers the bottom half without resizing the window, so the list makes room for it
    // and the field being edited can scroll above it (`Field` brings itself into view).
    LazyColumn(Modifier.imePadding(), verticalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(bottom = 240.dp)) {
        item { PageTitle("Add a Playlist") }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Source.Kind.entries.forEach { k ->
                    PillButton(k.displayName, onClick = { kind = k }, selected = k == kind, modifier = Modifier.initialFocus(enabled = k == Source.Kind.XTREAM))
                }
            }
        }
        item { Field("Name", name) { name = it } }
        item {
            Field(when (kind) { Source.Kind.M3U -> "Playlist URL"; Source.Kind.STALKER -> "Portal URL"; else -> "Server URL, or a get.php link" }, url,
                KeyboardType.Uri) { v ->
                url = v
                // A pasted get.php / player_api.php link fills the account too.
                XtreamURLs.parseCredentials(v)?.let { (base, u, p) -> if (kind == Source.Kind.XTREAM) { url = base; username = u; password = p } }
            }
        }
        if (kind == Source.Kind.XTREAM) {
            item { Field("Username", username) { username = it } }
            item { Field("Password", password, secret = true) { password = it } }
        }
        if (kind == Source.Kind.STALKER) item { Field("MAC address", mac) { mac = it.uppercase() } }
        item {
            PillButton("Add Playlist", onClick = {
                if (url.isNotBlank()) onAdd(Source(name = name.ifBlank { kind.displayName }, kind = kind, url = url.trim(),
                    username = username.trim().ifEmpty { null }, password = password.ifEmpty { null }, mac = mac.trim().ifEmpty { null }))
            })
        }
        status?.let { item { Text(it, color = TunerColors.accent) } }
    }
}

/**
 * A text setting for a remote: a button showing the value until OK is pressed, then an editable field with the
 * keyboard (Done or Back ends editing). Moving through a form never pops the keyboard up on its own.
 */
@Composable
private fun Field(label: String, value: String, keyboard: KeyboardType = KeyboardType.Text, secret: Boolean = false, initialFocus: Boolean = false, onChange: (String) -> Unit) {
    var editing by remember { mutableStateOf(false) }
    val editor = remember { androidx.compose.ui.focus.FocusRequester() }
    val button = remember { androidx.compose.ui.focus.FocusRequester() }
    var returnFocus by remember { mutableStateOf(false) }
    val inView = remember { androidx.compose.foundation.relocation.BringIntoViewRequester() }
    var fieldSize by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }
    val below = with(androidx.compose.ui.platform.LocalDensity.current) { 220.dp.toPx() }
    Column(Modifier.bringIntoViewRequester(inView).onSizeChanged { fieldSize = it }) {
        Text(label, color = Color.White.copy(alpha = 0.7f))
        Spacer(Modifier.height(6.dp))
        if (editing) {
            var focused by remember { mutableStateOf(false) }
            BasicTextField(
                value, onChange, singleLine = true,
                textStyle = TextStyle(color = Color.White, fontSize = 22.sp),
                cursorBrush = SolidColor(TunerColors.accent),
                visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(keyboardType = keyboard, autoCorrectEnabled = false, imeAction = androidx.compose.ui.text.input.ImeAction.Done),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { editing = false }),
                modifier = Modifier.width(720.dp).focusRequester(editor)
                    .onFocusChanged { if (focused && !it.isFocused) editing = false; focused = it.isFocused }
                    .onPreviewKeyEvent { e ->
                        val down = e.type == androidx.compose.ui.input.key.KeyEventType.KeyDown
                        if (down && (e.key == androidx.compose.ui.input.key.Key.DirectionDown || e.key == androidx.compose.ui.input.key.Key.DirectionUp)) {
                            editing = false; true
                        } else if (e.key == androidx.compose.ui.input.key.Key.Back) {
                            // Reaches the field only once no keyboard is up to take it (a floating keyboard that's
                            // already hidden, or a hardware keyboard): Back then ends editing instead of doing nothing.
                            if (!down) editing = false
                            true
                        } else false
                    }
                    .background(Color.White.copy(alpha = 0.18f), RoundedCornerShape(10.dp)).padding(14.dp),
            )
            LaunchedEffect(Unit) { editor.focusWhenReady() }
            // Closing the keyboard (Back) ends editing, so the D-pad moves through the form again.
            // Visibility, not height: Google TV's floating keyboard reports a zero-height inset, so testing the height
            // never saw it close and the field stayed in edit mode.
            @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
            val imeVisible = androidx.compose.foundation.layout.WindowInsets.isImeVisible
            var imeWasVisible by remember { mutableStateOf(false) }
            LaunchedEffect(imeVisible) {
                if (imeVisible) {
                    imeWasVisible = true
                    // The list has just shrunk for the keyboard: scroll this field above it.
                    kotlinx.coroutines.delay(80)
                    // The field plus a band under it as tall as the keyboard's top part: the keyboard reports less
                    // than it covers, so bringing just the field into view left it half under the suggestion bar.
                    inView.bringIntoView(androidx.compose.ui.geometry.Rect(0f, 0f, fieldSize.width.toFloat(), fieldSize.height + below))
                } else if (imeWasVisible) editing = false
            }
        } else {
            val shown = if (secret && value.isNotEmpty()) "•".repeat(value.length) else value
            androidx.tv.material3.Surface(
                onClick = { editing = true },
                shape = androidx.tv.material3.ClickableSurfaceDefaults.shape(RoundedCornerShape(10.dp)),
                colors = androidx.tv.material3.ClickableSurfaceDefaults.colors(
                    containerColor = TunerColors.surface, contentColor = Color.White,
                    focusedContainerColor = Color.White, focusedContentColor = Color.Black,
                ),
                scale = androidx.tv.material3.ClickableSurfaceDefaults.scale(focusedScale = 1f),
                modifier = Modifier.width(720.dp).focusRequester(button).initialFocus(enabled = initialFocus),
            ) {
                Text(shown.ifEmpty { " " }, fontSize = 22.sp, maxLines = 1, modifier = Modifier.padding(14.dp))
            }
            // Back on the field after editing.
            LaunchedEffect(Unit) { if (returnFocus) { returnFocus = false; button.focusWhenReady() } }
        }
        LaunchedEffect(editing) { if (editing) returnFocus = true }
    }
}
