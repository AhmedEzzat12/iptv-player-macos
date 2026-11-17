package app.tuner.tv.ui.settings

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

/** Settings → Playlists: the sources with their status, Refresh, Remove, and Add a Playlist. */
@Composable
fun PlaylistsScreen(onAdd: () -> Unit) {
    val app = LocalContext.current.app
    val scope = rememberCoroutineScope()
    var sources by remember { mutableStateOf<List<Source>>(emptyList()) }
    val progress by app.sync.progress.collectAsState()
    var revision by remember { mutableStateOf(0) }
    LaunchedEffect(revision, progress?.done) { sources = app.library.sources() }

    Column(Modifier.fillMaxSize()) {
        PageTitle("Playlists")
        Spacer(Modifier.height(20.dp))
        Button(onClick = onAdd, modifier = Modifier.initialFocus()) { Text("Add a Playlist") }
        Spacer(Modifier.height(24.dp))
        LazyColumn(verticalArrangement = Arrangement.spacedBy(16.dp)) {
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
                        OutlinedButton(onClick = { scope.launch { app.library.deleteSource(s.id); revision++ } }) { Text("Remove") }
                    }
                }
            }
        }
    }
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
