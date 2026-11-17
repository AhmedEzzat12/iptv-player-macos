package app.tuner.tv.share

import app.tuner.core.models.Source
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.BufferedInputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.security.SecureRandom

/**
 * "Add a playlist from your phone": while the add-playlist screen is open, the TV serves a page on the home network at
 * `http://<tv-ip>:<port>/<token>`. A phone camera opens it as a form (POST form-encoded); Antenna on iPhone/iPad scans the
 * same QR code and POSTs the playlist as JSON (`SharedPlaylist`). The one-time token (128-bit, base62) is required, works
 * for one submission or 10 minutes, and the server stops when the screen closes. Nothing leaves the home network.
 */
class PlaylistShareServer(private val scope: CoroutineScope, private val onReceived: (Source) -> Unit) {
    /** The JSON Antenna sends (`POST /<token>`, `Content-Type: application/json`). */
    @Serializable
    data class SharedPlaylist(
        val version: Int = 1,
        val name: String,
        val kind: String,
        val url: String,
        val username: String? = null,
        val password: String? = null,
        val mac: String? = null,
        val epgURL: String? = null,
        val userAgent: String? = null,
        val includeLive: Boolean = true,
        val includeVOD: Boolean = true,
        val backupURLs: List<String> = emptyList(),
        val extraEPGURLs: List<String> = emptyList(),
    )

    private val json = Json { ignoreUnknownKeys = true }
    private var socket: ServerSocket? = null
    private var job: Job? = null
    private var expiresAt = 0L
    // Bad requests per client address: a client that keeps guessing is ignored, the others can still submit.
    private val failures = java.util.concurrent.ConcurrentHashMap<String, Int>()
    val token: String = randomToken()
    var url: String? = null
        private set

    /** Starts listening; returns the URL to show (null without a network). */
    fun start(): String? {
        val ip = lanAddress() ?: return null
        val server = runCatching { ServerSocket(8790) }.getOrElse { ServerSocket(0) }
        socket = server
        expiresAt = System.currentTimeMillis() + 10 * 60_000
        url = "http://$ip:${server.localPort}/$token"
        job = scope.launch(Dispatchers.IO) {
            while (isActive) {
                val client = runCatching { server.accept() }.getOrNull() ?: break
                launch { runCatching { client.use { handle(it) } } }
            }
        }
        return url
    }

    fun stop() {
        job?.cancel()
        runCatching { socket?.close() }
        socket = null
    }

    private fun handle(client: Socket) {
        client.soTimeout = 15_000
        val input = BufferedInputStream(client.getInputStream())
        val requestLine = readLine(input) ?: return
        val headers = HashMap<String, String>()
        while (true) {
            val line = readLine(input) ?: break
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
        }
        val (method, path) = requestLine.split(' ').let { (it.getOrNull(0) ?: "") to (it.getOrNull(1) ?: "") }
        val out = client.getOutputStream()
        val peer = client.inetAddress?.hostAddress ?: "?"
        val requested = path.trimEnd('/').removePrefix("/").substringBefore('?')
        val blocked = (failures[peer] ?: 0) >= 5
        val valid = !blocked && requested == token && System.currentTimeMillis() < expiresAt
        if (!valid) {
            // Browsers ask for these on their own; they aren't guesses.
            if (requested != "favicon.ico" && requested != "robots.txt") failures.merge(peer, 1, Int::plus)
            respond(out, 404, "text/plain", "Not found")
            return
        }
        when (method) {
            "GET" -> respond(out, 200, "text/html; charset=utf-8", page())
            "POST" -> {
                val length = headers["content-length"]?.toIntOrNull()?.coerceAtMost(64 * 1024) ?: 0
                val body = String(input.readNBytes(length), Charsets.UTF_8)
                val shared = runCatching {
                    if (headers["content-type"]?.startsWith("application/json") == true) json.decodeFromString(SharedPlaylist.serializer(), body)
                    else fromForm(body)
                }.getOrNull()
                val source = shared?.toSource()
                if (source == null) {
                    respond(out, 400, "application/json", """{"ok":false,"error":"Missing name, type or URL"}""")
                    return
                }
                expiresAt = 0 // one submission per code
                onReceived(source)
                if (headers["content-type"]?.startsWith("application/json") == true) respond(out, 200, "application/json", """{"ok":true}""")
                else respond(out, 200, "text/html; charset=utf-8", donePage())
            }
            else -> respond(out, 405, "text/plain", "Method not allowed")
        }
    }

    private fun SharedPlaylist.toSource(): Source? {
        val kind = Source.Kind.of(kind) ?: return null
        if (url.isBlank()) return null
        return Source(
            name = name.ifBlank { kind.displayName }, kind = kind, url = url.trim(), username = username?.trim()?.ifEmpty { null },
            password = password?.ifEmpty { null }, mac = mac?.trim()?.ifEmpty { null }, epgURL = epgURL?.trim()?.ifEmpty { null },
            userAgent = userAgent?.trim()?.ifEmpty { null }, includeLive = includeLive, includeVOD = includeVOD,
            backupURLs = backupURLs.filter { it.isNotBlank() }, extraEPGURLs = extraEPGURLs.filter { it.isNotBlank() },
        )
    }

    private fun fromForm(body: String): SharedPlaylist {
        val f = body.split('&').mapNotNull { pair ->
            val i = pair.indexOf('=')
            if (i < 0) null else URLDecoder.decode(pair.substring(0, i), "UTF-8") to URLDecoder.decode(pair.substring(i + 1), "UTF-8")
        }.toMap()
        return SharedPlaylist(name = f["name"].orEmpty(), kind = f["kind"].orEmpty(), url = f["url"].orEmpty(), username = f["username"],
            password = f["password"], mac = f["mac"], epgURL = f["epgURL"], includeVOD = f["includeVOD"] != null || f["kind"] == null)
    }

    private fun respond(out: OutputStream, code: Int, type: String, body: String) {
        val bytes = body.toByteArray()
        val status = mapOf(200 to "OK", 400 to "Bad Request", 404 to "Not Found", 405 to "Method Not Allowed")[code] ?: "OK"
        out.write("HTTP/1.1 $code $status\r\nContent-Type: $type\r\nContent-Length: ${bytes.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(bytes)
        out.flush()
    }

    private fun readLine(input: BufferedInputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val b = input.read()
            if (b == -1) return if (sb.isEmpty()) null else sb.toString()
            if (b == '\n'.code) return sb.toString().trimEnd('\r')
            if (sb.length > 8192) return null
            sb.append(b.toChar())
        }
    }

    private fun page() = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Add a playlist to Antenna</title><style>
body{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:24px;background:#0b0b0d;color:#fff}
h1{font-size:24px}label{display:block;margin:14px 0 6px;color:#bbb}input,select{width:100%;box-sizing:border-box;padding:12px;border-radius:10px;
border:1px solid #333;background:#1a1a1e;color:#fff;font-size:17px}button{margin-top:22px;width:100%;padding:14px;border:0;border-radius:12px;
background:#00d4ff;color:#000;font-size:18px;font-weight:600}.x{display:none}.hint{color:#888;font-size:14px;margin-top:18px}</style></head><body>
<h1>Add a playlist to your TV</h1><form method="post">
<label>Type</label><select name="kind" id="kind" onchange="sync()"><option value="xtream">Xtream Codes</option><option value="m3u">M3U playlist URL</option><option value="stalker">Stalker portal</option></select>
<label>Name</label><input name="name" placeholder="My playlist">
<label id="urlLabel">Server URL</label><input name="url" required autocapitalize="off" autocorrect="off" placeholder="http://example.com:8080">
<div id="xt"><label>Username</label><input name="username" autocapitalize="off" autocorrect="off"><label>Password</label><input name="password" type="password"></div>
<div id="st" class="x"><label>MAC address</label><input name="mac" placeholder="00:1A:79:XX:XX:XX" autocapitalize="characters"></div>
<label>Guide URL (optional)</label><input name="epgURL" autocapitalize="off" autocorrect="off">
<input type="hidden" name="includeVOD" value="1"><button>Send to TV</button></form>
<p class="hint">This page is served by your TV on your home network. Nothing is sent anywhere else.</p>
<script>function sync(){var k=document.getElementById('kind').value;document.getElementById('xt').className=k=='xtream'?'':'x';
document.getElementById('st').className=k=='stalker'?'':'x';document.getElementById('urlLabel').textContent=k=='m3u'?'Playlist URL':k=='stalker'?'Portal URL':'Server URL'}</script>
</body></html>"""

    private fun donePage() = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:18px -apple-system,system-ui,sans-serif;padding:32px;background:#0b0b0d;color:#fff}</style></head>
<body><h1>Sent to your TV</h1><p>Confirm on the TV to add the playlist.</p></body></html>"""

    companion object {
        private const val ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        private fun randomToken(): String {
            val r = SecureRandom()
            return (0 until 22).map { ALPHABET[r.nextInt(ALPHABET.length)] }.joinToString("")
        }

        /** The TV's IPv4 address on Wi-Fi or Ethernet. */
        fun lanAddress(): String? = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            .filter { it.isUp && !it.isLoopback && !it.isVirtual }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is Inet4Address && it.isSiteLocalAddress }?.hostAddress
    }
}
