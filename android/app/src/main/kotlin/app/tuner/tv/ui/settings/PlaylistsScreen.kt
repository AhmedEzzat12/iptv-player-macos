package app.tuner.tv.ui.settings

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
import app.tuner.tv.ui.initialFocus
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** Settings: Playlists (status, Refresh, Remove, Add a Playlist), then Playback and Guide & Library options. */
@Composable
fun PlaylistsScreen(onAdd: () -> Unit) {
    val app = LocalContext.current.app
    val prefs = app.prefs
    val scope = rememberCoroutineScope()
    var sources by remember { mutableStateOf<List<Source>>(emptyList()) }
    val progress by app.sync.progress.collectAsState()
    var revision by remember { mutableStateOf(0) }
    var pendingRemove by remember { mutableStateOf<Source?>(null) }
    var hiddenChannels by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var hiddenCategories by remember { mutableStateOf<List<Triple<String, String, CategoryKind>>>(emptyList()) }
    LaunchedEffect(revision, progress?.done) { sources = app.library.sources() }
    LaunchedEffect(Unit) { app.database.changes.collect { revision++ } }
    LaunchedEffect(revision) {
        hiddenChannels = app.library.hiddenChannels()
        hiddenCategories = app.library.hiddenCategories()
    }

    Box(Modifier.fillMaxSize()) {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(bottom = 48.dp)) {
            item { PageTitle("Settings") }
            item { SectionTitle("Playlists") }
            item { Button(onClick = onAdd, modifier = Modifier.initialFocus()) { Text("Add a Playlist") } }
            items(sources, key = { it.id }) { s ->
                Column(Modifier.fillMaxWidth().background(TunerColors.surface, RoundedCornerShape(14.dp)).padding(20.dp)) {
                    Text(s.name, style = MaterialTheme.typography.titleLarge)
                    Text("${s.kind.displayName} · ${host(s.url)}", color = Color.White.copy(alpha = 0.6f))
                    val counts = "${s.channelCount} channels · ${s.movieCount} movies · ${s.seriesCount} shows"
                    val synced = s.lastSyncedAt?.let { " · updated " + DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it.toEpochMilli())) } ?: ""
                    Text(counts + synced, color = Color.White.copy(alpha = 0.6f))
                    s.expiresAt?.let { Text("Expires " + DateFormat.getDateInstance().format(Date(it.toEpochMilli())), color = Color.White.copy(alpha = 0.6f)) }
                    if (progress?.sourceId == s.id && progress?.done == false) Text(progress!!.step, color = TunerColors.accent)
                    if (s.needsPassword) Text("Password needed: add the playlist again", color = Color(0xFFFFB74D))
                    s.lastError?.let { Text(it, color = Color(0xFFFF6E6E), maxLines = 3) }
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedButton(onClick = { scope.launch { app.sync.sync(s.id); revision++ } }) { Text("Refresh") }
                        OutlinedButton(onClick = { pendingRemove = s }) { Text("Remove") }
                    }
                }
            }

            item { SectionTitle("Playback") }
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

            if (hiddenChannels.isNotEmpty() || hiddenCategories.isNotEmpty()) {
                item { SectionTitle("Hidden") }
                items(hiddenCategories, key = { "cat" + it.first }) { (id, name, kind) ->
                    val where = when (kind) { CategoryKind.LIVE -> "Live TV category"; CategoryKind.MOVIE -> "Movies category"; else -> "TV Shows category" }
                    OptionRow(name, "Show", where) { scope.launch { app.library.setCategoryHidden(id, false) } }
                }
                items(hiddenChannels, key = { "ch" + it.id }) { ch ->
                    OptionRow(ch.displayName, "Show", "Channel") { scope.launch { app.library.setChannelHidden(ch.id, false) } }
                }
            }

            item { SectionTitle("Guide & Library") }
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

        pendingRemove?.let { s ->
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.78f)), contentAlignment = Alignment.Center) {
                Column(Modifier.width(620.dp).background(TunerColors.surface, RoundedCornerShape(18.dp)).padding(28.dp)) {
                    Text("Remove “${s.name}”?", style = MaterialTheme.typography.headlineSmall)
                    Spacer(Modifier.height(10.dp))
                    Text("Its channels, movies, shows and guide are removed from Antenna. You can add it again at any time.",
                        color = Color.White.copy(alpha = 0.78f))
                    Spacer(Modifier.height(22.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Button(onClick = { pendingRemove = null; scope.launch { app.library.deleteSource(s.id); revision++ } }) { Text("Remove Playlist") }
                        OutlinedButton(onClick = { pendingRemove = null }, modifier = Modifier.initialFocus(s.id)) { Text("Cancel") }
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleMedium, color = TunerColors.accent, modifier = Modifier.padding(top = 12.dp))
}

/** A setting: OK moves to the next value. */
@Composable
private fun OptionRow(title: String, value: String, detail: String? = null, onClick: () -> Unit) {
    ListItem(
        selected = false,
        onClick = onClick,
        headlineContent = { Text(title) },
        // No fixed colours: the row darkens its text when focused (grey on the white focus would be unreadable).
        supportingContent = detail?.let { { Text(it) } },
        trailingContent = { Text(value, style = MaterialTheme.typography.titleSmall) },
        modifier = Modifier.fillMaxWidth(),
    )
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
                Button(onClick = { add(pending) }, modifier = Modifier.initialFocus(pending)) { Text("Add Playlist") }
                OutlinedButton(onClick = { received = null; onDone() }) { Text("Discard") }
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
                    OutlinedButton(onClick = { typing = true }, modifier = Modifier.initialFocus()) { Text("Type It In Instead") }
                    OutlinedButton(onClick = onDone) { Text("Cancel") }
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
@Composable
private fun TypeItIn(status: String?, onAdd: (Source) -> Unit) {
    var kind by remember { mutableStateOf(Source.Kind.XTREAM) }
    var name by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var mac by remember { mutableStateOf("") }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item { PageTitle("Add a Playlist") }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Source.Kind.entries.forEach { k ->
                    if (k == kind) Button(onClick = {}, modifier = Modifier.initialFocus()) { Text(k.displayName) } else OutlinedButton(onClick = { kind = k }) { Text(k.displayName) }
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
            Button(onClick = {
                if (url.isNotBlank()) onAdd(Source(name = name.ifBlank { kind.displayName }, kind = kind, url = url.trim(),
                    username = username.trim().ifEmpty { null }, password = password.ifEmpty { null }, mac = mac.trim().ifEmpty { null }))
            }) { Text("Add Playlist") }
        }
        status?.let { item { Text(it, color = TunerColors.accent) } }
    }
}

@Composable
private fun Field(label: String, value: String, keyboard: KeyboardType = KeyboardType.Text, secret: Boolean = false, onChange: (String) -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Column {
        Text(label, color = Color.White.copy(alpha = 0.7f))
        Spacer(Modifier.height(6.dp))
        BasicTextField(
            value, onChange, singleLine = true,
            textStyle = TextStyle(color = Color.White, fontSize = 22.sp),
            cursorBrush = SolidColor(TunerColors.accent),
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(keyboardType = keyboard, autoCorrectEnabled = false),
            modifier = Modifier.width(720.dp).onFocusChanged { focused = it.isFocused }
                .background(if (focused) Color.White.copy(alpha = 0.18f) else TunerColors.surface, RoundedCornerShape(10.dp)).padding(14.dp),
        )
    }
}
