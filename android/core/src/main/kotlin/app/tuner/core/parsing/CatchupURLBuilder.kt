// Port of Sources/TunerCore/Parsing/CatchupURLBuilder.swift @ 666f598
package app.tuner.core.parsing

import app.tuner.core.models.CatchupType
import app.tuner.core.net.urlQueryEncoded
import app.tuner.core.nilIfEmpty
import java.time.Instant
import java.time.ZoneOffset
import java.util.regex.Pattern

/**
 * Builds archive (catchup) URLs for M3U channels, with the conventions of Kodi's pvr.iptvsimple and ynotv:
 * `append` (catchup-source appended to the live URL, default `?utc={utc}&lutc={lutc}`), `shift`, `flussonic`
 * (`…/index.m3u8` → `…/index-{utc}-{duration}.m3u8`, `…/mpegts` → `…/timeshift_abs-{utc}.ts`) and `default`
 * (catchup-source is a full URL template, falling back to `?utc=…&lutc=…`).
 */
public object CatchupURLBuilder {
    public fun m3u(
        channelURL: String,
        type: CatchupType,
        template: String?,
        tvgId: String?,
        start: Instant,
        end: Instant,
        now: Instant = Instant.now(),
    ): String {
        val v = Variables(start, end, now, tvgId)
        val tpl = template.nilIfEmpty()
        if (tpl != null) {
            val filled = substitute(tpl, v)
            if (type == CatchupType.APPEND || !filled.contains("://")) return channelURL + filled
            return filled
        }
        return when (type) {
            CatchupType.FLUSSONIC -> flussonic(channelURL, v)
            else -> appendQuery(channelURL, "utc=${v.startEpoch}&lutc=${v.nowEpoch}")
        }
    }

    internal class Variables(val start: Instant, val end: Instant, val now: Instant, val catchupId: String?) {
        val startEpoch: Long get() = start.epochSecond
        val endEpoch: Long get() = end.epochSecond
        val nowEpoch: Long get() = now.epochSecond
        val durationSeconds: Long get() = maxOf(0, endEpoch - startEpoch)
        val offsetSeconds: Long get() = maxOf(0, nowEpoch - startEpoch)
    }

    internal fun substitute(template: String, v: Variables): String {
        var s = template
        val sp = utcComponents(v.start)
        val ep = utcComponents(v.end)
        // Parameterised forms first: {duration:60} → duration / 60, {offset:60} → offset / 60.
        s = replaceDivided(s, "duration", v.durationSeconds)
        s = replaceDivided(s, "offset", v.offsetSeconds)
        val simple = listOf(
            "utcend" to "${v.endEpoch}", "utc_end" to "${v.endEpoch}", "end_utc" to "${v.endEpoch}",
            "end-timestamp" to "${v.endEpoch}", "end" to "${v.endEpoch}",
            "lutc" to "${v.nowEpoch}", "now" to "${v.nowEpoch}", "timestamp" to "${v.nowEpoch}",
            "utc" to "${v.startEpoch}", "start-timestamp" to "${v.startEpoch}", "start" to "${v.startEpoch}",
            "duration_m" to "${v.durationSeconds / 60}", "duration_min" to "${v.durationSeconds / 60}",
            "duration" to "${v.durationSeconds}", "offset" to "${v.offsetSeconds}",
            "catchup-id" to (v.catchupId ?: "").urlQueryEncoded,
            "EY" to ep[0], "Em" to ep[1], "Ed" to ep[2], "EH" to ep[3], "EM" to ep[4], "ES" to ep[5],
            "Y" to sp[0], "m" to sp[1], "d" to sp[2], "H" to sp[3], "M" to sp[4], "S" to sp[5],
        )
        for ((name, value) in simple) {
            s = s.replace("\${$name}", value)
            s = s.replace("{$name}", value)
        }
        return s
    }

    internal fun replaceDivided(s: String, name: String, value: Long): String {
        val m = Pattern.compile("""\$?\{$name:(\d+)\}""").matcher(s)
        val out = StringBuffer()
        while (m.find()) {
            val divisor = m.group(1).toLongOrNull()
            val replacement = if (divisor != null && divisor > 0) "${value / divisor}" else m.group()
            m.appendReplacement(out, java.util.regex.Matcher.quoteReplacement(replacement))
        }
        m.appendTail(out)
        return out.toString()
    }

    internal fun flussonic(url: String, v: Variables): String {
        val parts = UrlParts.parse(url) ?: return url
        val path = parts.path
        val newPath = when {
            path.endsWith("/mpegts") -> path.dropLast("mpegts".length) + "timeshift_abs-${v.startEpoch}.ts"
            path.endsWith(".m3u8") && path.contains('/') -> {
                val slash = path.lastIndexOf('/')
                val stem = path.substring(slash + 1).dropLast(".m3u8".length)
                path.substring(0, slash + 1) + "$stem-${v.startEpoch}-${v.durationSeconds}.m3u8"
            }
            else -> return appendQuery(url, "timeshift=${v.startEpoch}")
        }
        return parts.copy(path = newPath).toString()
    }

    internal fun appendQuery(url: String, query: String): String = url + (if (url.contains("?")) "&" else "?") + query

    /** Year, month, day, hour, minute, second in UTC, zero-padded (year unpadded), as Swift's `utcComponents`. */
    internal fun utcComponents(date: Instant): List<String> {
        val z = date.atZone(ZoneOffset.UTC)
        fun two(n: Int) = "%02d".format(n)
        return listOf(z.year.toString(), two(z.monthValue), two(z.dayOfMonth), two(z.hour), two(z.minute), two(z.second))
    }
}

/** `scheme://authority` + path + `?query` + `#fragment`, split without re-encoding (URLComponents-like, ASCII URLs). */
internal data class UrlParts(val prefix: String, val path: String, val suffix: String) {
    override fun toString(): String = prefix + path + suffix

    companion object {
        fun parse(url: String): UrlParts? {
            val schemeEnd = url.indexOf("://").takeIf { it > 0 } ?: return null
            val authorityStart = schemeEnd + 3
            val pathStart = url.indexOfAny(charArrayOf('/', '?', '#'), authorityStart).let { if (it < 0) url.length else it }
            val pathEnd = url.indexOfAny(charArrayOf('?', '#'), pathStart).let { if (it < 0) url.length else it }
            return UrlParts(url.substring(0, pathStart), url.substring(pathStart, pathEnd), url.substring(pathEnd))
        }
    }
}
