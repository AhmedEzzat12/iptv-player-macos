// Port of the URL builders in Sources/TunerCore/Providers/XtreamClient.swift @ 666f598
package app.tuner.core.providers

import app.tuner.core.net.urlPathEncoded
import app.tuner.core.net.urlQueryEncoded
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Xtream Codes URLs. They carry the account's username and password, so they're built when needed and never stored or
 * logged (CLAUDE.md).
 */
public class XtreamURLs(base: String, public val username: String, public val password: String) {
    public val base: String = base.trim().trimEnd('/').let { if (it.lowercase().startsWith("http")) it else "http://$it" }

    public enum class LiveFormat(public val ext: String) { TS("ts"), M3U8("m3u8") }

    /** `player_api.php?username=…&password=…[&action=…][&k=v…]`, extra parameters sorted by key. */
    public fun apiURL(action: String? = null, params: Map<String, String> = emptyMap()): String {
        val s = StringBuilder("$base/player_api.php?username=${username.urlQueryEncoded}&password=${password.urlQueryEncoded}")
        if (action != null) s.append("&action=").append(action)
        for ((k, v) in params.toSortedMap()) s.append('&').append(k).append('=').append(v.urlQueryEncoded)
        return s.toString()
    }

    private val credentials get() = "${username.urlPathEncoded}/${password.urlPathEncoded}"

    public fun liveURL(streamId: String, format: LiveFormat = LiveFormat.TS): String =
        "$base/live/$credentials/$streamId.${format.ext}"

    public fun movieURL(streamId: String, ext: String?): String = "$base/movie/$credentials/$streamId.${extOrMp4(ext)}"

    public fun episodeURL(episodeId: String, ext: String?): String = "$base/series/$credentials/$episodeId.${extOrMp4(ext)}"

    /** `/timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts`, start expressed in server-local time. */
    public fun timeshiftURL(streamId: String, start: Instant, durationMinutes: Int, serverTimeOffsetSeconds: Double): String {
        val local = start.plusMillis((serverTimeOffsetSeconds * 1000).toLong())
        val startString = TIMESHIFT_FORMAT.format(local)
        return "$base/timeshift/$credentials/${maxOf(1, durationMinutes)}/$startString/$streamId.ts"
    }

    /** `xmltv.php` guide URL for this account. */
    public fun xmltvURL(): String = "$base/xmltv.php?username=${username.urlQueryEncoded}&password=${password.urlQueryEncoded}"

    private fun extOrMp4(ext: String?) = ext?.trim()?.takeIf { it.isNotEmpty() } ?: "mp4"

    public companion object {
        private val TIMESHIFT_FORMAT: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd:HH-mm", Locale.ROOT).withZone(ZoneOffset.UTC)

        /** Server/credentials from a pasted `get.php` or `player_api.php` link. */
        public fun parseCredentials(text: String): Triple<String, String, String>? {
            val uri = runCatching { java.net.URI(text.trim()) }.getOrNull() ?: return null
            val scheme = uri.scheme ?: return null
            val host = uri.host ?: return null
            val query = uri.rawQuery ?: return null
            val items = query.split('&').mapNotNull { pair ->
                val i = pair.indexOf('=')
                if (i < 0) null else pair.substring(0, i) to java.net.URLDecoder.decode(pair.substring(i + 1).replace("+", "%2B"), "UTF-8") // the Charset overload needs Android 13
            }
            val user = items.firstOrNull { it.first == "username" }?.second ?: return null
            val pass = items.firstOrNull { it.first == "password" }?.second ?: return null
            val port = if (uri.port >= 0) ":${uri.port}" else ""
            return Triple("$scheme://$host$port", user, pass)
        }
    }
}
