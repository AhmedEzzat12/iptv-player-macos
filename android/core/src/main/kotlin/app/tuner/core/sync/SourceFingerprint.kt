// Port of Sources/TunerCore/CloudSync/SourceFingerprint.swift @ 666f598
package app.tuner.core.sync

import app.tuner.core.models.Source
import java.security.MessageDigest

/**
 * Identifies "the same playlist" on every device without its secrets, so a later sync version can name a playlist by
 * `"<fingerprint>|<suffix>"` exactly as the Apple apps do. Hash of the kind, the normalised URL (lowercased scheme and
 * host, default port and trailing slashes dropped, no user info, secret query parameters removed, the rest sorted),
 * the lowercased username and, for Stalker, the MAC. Never the password. Checked against Swift by vectors.
 */
public object SourceFingerprint {
    public fun of(source: Source): String = of(source.kind, source.url, source.username, source.mac)

    public fun of(kind: Source.Kind, url: String, username: String?, mac: String?): String {
        val parts = mutableListOf("tuner-source-1", kind.raw, normalizedURL(url), (username ?: "").trim().lowercase())
        if (kind == Source.Kind.STALKER) parts.add((mac ?: "").trim().lowercase())
        val digest = MessageDigest.getInstance("SHA-256").digest(parts.joinToString("\n").toByteArray())
        return digest.take(10).joinToString("") { "%02x".format(it) }
    }

    /** The URL in the form the fingerprint hashes: secrets removed, cosmetic differences evened out. */
    public fun normalizedURL(raw: String): String {
        val trimmed = raw.trim()
        val c = Components.parse(trimmed) ?: return trimmed.lowercase().trimEnd('/')
        val scheme = c.scheme.lowercase()
        val port = if ((scheme == "http" && c.port == "80") || (scheme == "https" && c.port == "443")) null else c.port
        val path = stripPathCredentials(c.path).first.trimEnd('/')
        val items = c.queryItems().filter { !isSecretParameter(it.first) }
            .sortedWith(compareBy<Pair<String, String?>> { it.first.lowercase() }.thenBy { it.second ?: "" })
        return c.copy(scheme = scheme, userInfo = null, host = c.host?.lowercase(), port = port, path = path,
            query = Components.encodeItems(items), fragment = null).string()
    }

    /** Query parameter names that carry a secret (`password`, `pass`, `token`, `api_key`…). */
    public fun isSecretParameter(name: String): Boolean {
        val n = name.lowercase()
        if (n in setOf("p", "pwd", "pw", "key", "apikey", "sig", "signature")) return true
        return listOf("pass", "token", "secret", "auth", "api_key", "apikey").any { n.contains(it) }
    }

    /** `raw` without a password in its user info or secret query parameters, and whether anything was removed. */
    public fun publicURL(raw: String): Pair<String, Boolean> {
        val trimmed = raw.trim()
        var c = Components.parse(trimmed) ?: return trimmed to false
        var removed = false
        val user = c.userInfo
        if (user != null && user.contains(':')) {
            c = c.copy(userInfo = user.substringBefore(':'))
            removed = true
        }
        val (path, pathRemoved) = stripPathCredentials(c.path)
        if (pathRemoved) {
            c = c.copy(path = path)
            removed = true
        }
        if (c.query != null) {
            val items = c.queryItems()
            val kept = items.filter { !isSecretParameter(it.first) }
            if (kept.size != items.size) {
                removed = true
                c = c.copy(query = Components.encodeItems(kept))
            }
        }
        return if (removed) c.string() to true else trimmed to false
    }

    /** Path words after which IPTV panels put the account's username and password. */
    internal val credentialPathKeywords = setOf("playlist", "live", "movie", "series", "m3u", "m3u8", "get", "xmltv", "timeshift", "panel")

    /** The path with the two segments after a credential keyword replaced by `USER` / `PASSWORD`, and whether any were. */
    internal fun stripPathCredentials(path: String): Pair<String, Boolean> {
        val segments = path.split('/').toMutableList()
        var removed = false
        var i = 0
        while (i < segments.size) {
            if (segments[i].lowercase() in credentialPathKeywords && i + 2 < segments.size &&
                segments[i + 1].isNotEmpty() && segments[i + 2].isNotEmpty() &&
                (segments[i + 1] != "USER" || segments[i + 2] != "PASSWORD")
            ) {
                segments[i + 1] = "USER"
                segments[i + 2] = "PASSWORD"
                removed = true
                i += 3
            } else {
                i++
            }
        }
        return segments.joinToString("/") to removed
    }

    /** Whether `raw` carries a secret (left out of synced lists such as backup URLs and extra guides). */
    public fun containsSecret(raw: String): Boolean = publicURL(raw).second
}

/**
 * The parts of Foundation's `URLComponents` the fingerprint relies on: parse-time percent-encoding of invalid characters
 * in the path and query, query items decoded (`+` stays `+`) and re-encoded with `&`/`=` escaped, and `string`.
 */
internal data class Components(
    val scheme: String,
    val hasAuthority: Boolean,
    val userInfo: String?,
    val host: String?,
    val port: String?,
    val path: String,
    val query: String?,
    val fragment: String?,
) {
    fun string(): String = buildString {
        append(scheme).append(':')
        if (hasAuthority) {
            append("//")
            if (userInfo != null) append(userInfo).append('@')
            append(host ?: "")
            if (port != null) append(':').append(port)
        }
        append(path)
        if (query != null) append('?').append(query)
        if (fragment != null) append('#').append(fragment)
    }

    /** Decoded (name, value) pairs; a bare `name` has a null value. An empty query has no items. */
    fun queryItems(): List<Pair<String, String?>> {
        val q = query ?: return emptyList()
        if (q.isEmpty()) return emptyList()
        return q.split('&').map { item ->
            val eq = item.indexOf('=')
            if (eq < 0) decode(item) to null else decode(item.substring(0, eq)) to decode(item.substring(eq + 1))
        }
    }

    companion object {
        private val SCHEME = Regex("^[A-Za-z][A-Za-z0-9+.\\-]*:")
        private const val PATH_ALLOWED = "!$&'()*+,-./:=@_~"
        private const val QUERY_ALLOWED = "!$&'()*+,-./:;=?@_~"
        private const val ITEM_ALLOWED = "!$'()*+,-./:;?@_~"

        fun parse(s: String): Components? {
            val m = SCHEME.find(s) ?: return null
            val scheme = m.value.dropLast(1)
            var rest = s.substring(m.value.length)
            var hasAuthority = false
            var userInfo: String? = null
            var host: String? = null
            var port: String? = null
            if (rest.startsWith("//")) {
                hasAuthority = true
                rest = rest.substring(2)
                val end = rest.indexOfAny(charArrayOf('/', '?', '#')).let { if (it < 0) rest.length else it }
                var authority = rest.substring(0, end)
                rest = rest.substring(end)
                val at = authority.lastIndexOf('@')
                if (at >= 0) { userInfo = authority.substring(0, at); authority = authority.substring(at + 1) }
                val colon = authority.lastIndexOf(':')
                if (colon >= 0 && !authority.substring(colon).contains(']')) {
                    host = authority.substring(0, colon)
                    port = authority.substring(colon + 1).ifEmpty { null }
                } else {
                    host = authority
                }
            }
            val fragmentAt = rest.indexOf('#')
            val fragment = if (fragmentAt >= 0) rest.substring(fragmentAt + 1) else null
            if (fragmentAt >= 0) rest = rest.substring(0, fragmentAt)
            val queryAt = rest.indexOf('?')
            val query = if (queryAt >= 0) encode(rest.substring(queryAt + 1), QUERY_ALLOWED) else null
            val path = encode(if (queryAt >= 0) rest.substring(0, queryAt) else rest, PATH_ALLOWED)
            return Components(scheme, hasAuthority, userInfo, host, port, path, query, fragment)
        }

        /** Re-encodes query items the way `URLComponents.queryItems = …` does; null when there are none. */
        fun encodeItems(items: List<Pair<String, String?>>): String? = if (items.isEmpty()) null else
            items.joinToString("&") { (k, v) -> encode(k, ITEM_ALLOWED, keepEscapes = false) + (v?.let { "=" + encode(it, ITEM_ALLOWED, keepEscapes = false) } ?: "") }

        /** Percent-encodes characters outside `allowed` (UTF-8); existing `%XX` escapes are kept when `keepEscapes`. */
        fun encode(s: String, allowed: String, keepEscapes: Boolean = true): String {
            val out = StringBuilder()
            var i = 0
            val bytes = s.toByteArray(Charsets.UTF_8)
            while (i < bytes.size) {
                val c = bytes[i].toInt() and 0xFF
                val ch = c.toChar()
                val isEscape = keepEscapes && ch == '%' && i + 2 < bytes.size && isHex(bytes[i + 1]) && isHex(bytes[i + 2])
                if (isEscape || (c < 0x80 && (ch.isLetterOrDigit() || ch in allowed))) out.append(ch)
                else out.append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 0xF])
                i++
            }
            return out.toString()
        }

        private fun isHex(b: Byte) = (b.toInt() and 0xFF).toChar().let { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

        fun decode(s: String): String {
            if (!s.contains('%')) return s
            val out = java.io.ByteArrayOutputStream()
            val bytes = s.toByteArray(Charsets.UTF_8)
            var i = 0
            while (i < bytes.size) {
                if (bytes[i] == '%'.code.toByte() && i + 2 < bytes.size && isHex(bytes[i + 1]) && isHex(bytes[i + 2])) {
                    out.write(String(byteArrayOf(bytes[i + 1], bytes[i + 2])).toInt(16))
                    i += 3
                } else {
                    out.write(bytes[i].toInt())
                    i++
                }
            }
            return String(out.toByteArray(), Charsets.UTF_8)
        }
    }
}
