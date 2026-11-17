// Port of Sources/TunerCore/Networking/HTTPClient.swift @ 666f598
package app.tuner.core.net

import app.tuner.core.nilIfEmpty
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/** Errors with the same user-facing messages as Swift's `HTTPError`. */
public sealed class HttpException(message: String) : IOException(message) {
    public class BadURL(url: String) : HttpException("Invalid URL: ${HttpClient.redacted(url)}")
    public class Status(public val code: Int) : HttpException(
        when (code) {
            401 -> "Access denied (401): authentication required"
            403 -> "Access denied (403): blocked by server"
            404 -> "Not found (404)"
            in 500..599 -> "Server error ($code)"
            else -> "HTTP error $code"
        },
    )
    public class EmptyBody : HttpException("The server returned an empty response")
    /** The body wasn't JSON; carries the first bytes of what the server sent, for diagnosis. */
    public class InvalidJSON(preview: String?) : HttpException(
        preview?.let { "The server returned invalid data ($it)" } ?: "The server returned invalid data",
    )
    public class AuthFailed(message: String) : HttpException(message)
}

/** Thin coroutine wrapper over OkHttp with IPTV-friendly defaults. Never logs URLs (they carry credentials). */
public class HttpClient(userAgent: String? = null, public val timeoutSeconds: Long = 30, client: OkHttpClient = shared) {
    public val userAgent: String = userAgent.nilIfEmpty() ?: DEFAULT_USER_AGENT
    private val client: OkHttpClient = client.newBuilder()
        .callTimeout(0, TimeUnit.SECONDS)
        .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .build()

    /** GET with retries (backoff 0.5 s, 1 s, …); client errors (4xx) aren't retried. */
    public suspend fun data(url: String, headers: Map<String, String> = emptyMap(), retries: Int = 2): ByteArray =
        // Reading the body is blocking I/O: never on the caller's (possibly main) thread.
        withContext(Dispatchers.IO) { dataWithRetries(url, headers, retries) }

    private suspend fun dataWithRetries(url: String, headers: Map<String, String>, retries: Int): ByteArray {
        var attempt = 0
        while (true) {
            try {
                return execute(request(url, headers)).use { response ->
                    check(response)
                    response.body.bytes()
                }
            } catch (e: HttpException.Status) {
                if (e.code in 400..499) throw e
                attempt++
                if (attempt > retries) throw e
            } catch (e: HttpException.BadURL) {
                throw e
            } catch (e: IOException) {
                attempt++
                if (attempt > retries) throw e
            }
            delay(500L * (1L shl (attempt - 1)))
        }
    }

    /** Downloads to a temporary file (for multi-hundred-MB guides and playlists). `file://` URLs are returned as is. */
    public suspend fun download(url: String, headers: Map<String, String> = emptyMap(), directory: File? = null): File {
        if (url.startsWith("file://")) return File(java.net.URI(url))
        return withContext(Dispatchers.IO) { downloadFile(url, headers, directory) }
    }

    private suspend fun downloadFile(url: String, headers: Map<String, String>, directory: File?): File {
        val slow = client.newBuilder().readTimeout(maxOf(timeoutSeconds, 120), TimeUnit.SECONDS).build()
        val dest = File.createTempFile("tuner-", ".download", directory)
        try {
            execute(request(url, headers), slow).use { response ->
                check(response)
                withContext(Dispatchers.IO) { dest.outputStream().use { out -> response.body.byteStream().copyTo(out, 1 shl 16) } }
            }
        } catch (e: Exception) {
            dest.delete()
            throw e
        }
        return dest
    }

    /**
     * Fetches and parses JSON. Panels sometimes prepend PHP warnings or return a transient error page, so a malformed
     * body is re-parsed from its first `[`/`{` to the last `]`/`}`, then re-fetched with backoff before giving up with a
     * preview of what the server sent.
     */
    public suspend fun json(url: String, headers: Map<String, String> = emptyMap(), attempts: Int = 3): JsonElement {
        var lastError: HttpException = HttpException.EmptyBody()
        for (attempt in 1..maxOf(1, attempts)) {
            if (attempt > 1) delay((attempt - 1) * 1500L)
            val body = data(url, headers)
            if (body.isEmpty()) { lastError = HttpException.EmptyBody(); continue }
            parseJSONLeniently(body)?.let { return it }
            lastError = HttpException.InvalidJSON(preview(body))
        }
        throw lastError
    }

    private fun request(url: String, headers: Map<String, String>): Request {
        val builder = try { Request.Builder().url(url) } catch (e: IllegalArgumentException) { throw HttpException.BadURL(url) }
        builder.header("User-Agent", userAgent).header("Accept", "*/*")
        for ((k, v) in headers) builder.header(k, v)
        return builder.build()
    }

    private fun check(response: Response) {
        if (response.code !in 200..299) throw HttpException.Status(response.code)
    }

    private suspend fun execute(request: Request, using: OkHttpClient = client): Response =
        suspendCancellableCoroutine { cont ->
            val call = using.newCall(request)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) = cont.resumeWithException(e)
                override fun onResponse(call: Call, response: Response) = cont.resume(response) { _, _, _ -> response.close() }
            })
        }

    public companion object {
        public const val DEFAULT_USER_AGENT: String = "VLC/3.0.20 LibVLC/3.0.20"

        /** One connection pool for the app; no HTTP cache (playlists are huge and always fresh). */
        public val shared: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .cache(null)
                .followRedirects(true)
                .followSslRedirects(true)
                .retryOnConnectionFailure(true)
                .build()
        }

        private val json = Json { isLenient = false }

        /** Strict parse, then a parse of the outermost `[...]`/`{...}` span (strips leading/trailing junk). */
        public fun parseJSONLeniently(bytes: ByteArray): JsonElement? {
            val text = String(bytes, Charsets.UTF_8)
            runCatching { return json.parseToJsonElement(text) }
            val start = text.indexOfFirst { it == '[' || it == '{' }.takeIf { it >= 0 } ?: return null
            val close = if (text[start] == '[') ']' else '}'
            val end = text.lastIndexOf(close).takeIf { it > start } ?: return null
            return runCatching { json.parseToJsonElement(text.substring(start, end + 1)) }.getOrNull()
        }

        /** A short, single-line description of a non-JSON body (size + first characters). */
        public fun preview(bytes: ByteArray): String {
            val head = String(bytes.copyOf(minOf(120, bytes.size)), Charsets.UTF_8)
                .replace('\n', ' ').replace('\r', ' ').trim(' ', '\t')
            val size = formatBytes(bytes.size.toLong())
            return if (head.isEmpty()) "$size, empty" else "$size: $head"
        }

        /** Foundation's ByteCountFormatter(.file) style: decimal units. */
        internal fun formatBytes(n: Long): String = when {
            n < 1000 -> "$n bytes"
            n < 1_000_000 -> "${(n + 500) / 1000} KB"
            else -> "%.1f MB".format(n / 1_000_000.0)
        }

        /** URL without credentials, for diagnostics only (logs carry ids and status codes, not URLs). */
        public fun redacted(url: String): String = url
            .replace(Regex("""(username|password|token)=[^&]*"""), "$1=***")
            .replace(Regex("""/(live|movie|series|timeshift)/[^/]+/[^/]+/"""), "/$1/***/***/")
    }
}
