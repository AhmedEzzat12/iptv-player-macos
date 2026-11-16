// Port of Sources/TunerCore/Parsing/XMLTVParser.swift @ 666f598
package app.tuner.core.parsing

import app.tuner.core.models.toIntStrict
import app.tuner.core.nilIfEmpty
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.time.Instant

public data class XMLTVChannel(val id: String, val displayNames: MutableList<String> = mutableListOf(), var iconURL: String? = null)

public data class XMLTVProgramme(
    val channel: String,
    val start: Instant,
    val stop: Instant,
    val title: String,
    val subtitle: String?,
    val desc: String?,
    val category: String?,
    val iconURL: String?,
    val episode: String?,
)

/**
 * Fast, allocation-light XMLTV reader: a purpose-built scanner over raw bytes (several times faster than a generic XML
 * parser on 100 MB+ guides). Supports entities (named + numeric), CDATA, comments, processing instructions, DOCTYPE and
 * nested elements (unknown children like `<credits>` are skipped depth-aware).
 */
public object XMLTVParser {
    public sealed interface Event {
        public data class Channel(val channel: XMLTVChannel) : Event
        public data class Programme(val programme: XMLTVProgramme) : Event
    }

    private val tvRoot = Regex("""<tv[\s>]""")

    /** True if the file starts like an XMLTV document (a `<tv` root within the first 256 KB); `<tv></tv>` is valid. */
    public fun looksLikeXMLTV(file: File): Boolean = runCatching {
        file.inputStream().use { input ->
            val head = input.readNBytes(256 * 1024)
            val text = String(head, Charsets.UTF_8)
            tvRoot.containsMatchIn(text) || text.contains("<tv/>")
        }
    }.getOrDefault(false)

    /** Parses a (decompressed) XMLTV file, memory-mapped. */
    public fun parse(file: File, handler: (Event) -> Unit) {
        RandomAccessFile(file, "r").use { raf ->
            val buffer = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length())
            parse(buffer, handler)
        }
    }

    public fun parse(bytes: ByteArray, handler: (Event) -> Unit): Unit = parse(ByteBuffer.wrap(bytes), handler)

    public fun parse(buffer: ByteBuffer, handler: (Event) -> Unit) {
        Scanner(buffer).run(handler)
    }

    internal class Tag(val name: String, val attributes: Map<String, String>, val isClosing: Boolean, val isSelfClosing: Boolean)

    internal class Scanner(private val p: ByteBuffer) {
        private val end = p.limit()
        private var i = 0

        fun run(handler: (Event) -> Unit) {
            while (true) {
                val tag = nextTag() ?: break
                if (tag.isClosing) continue
                when (tag.name) {
                    "channel" -> parseChannel(tag)?.let { handler(Event.Channel(it)) }
                    "programme" -> parseProgramme(tag)?.let { handler(Event.Programme(it)) }
                    else -> Unit // <tv>, unknown top-level elements: descend into them
                }
            }
        }

        private fun at(k: Int): Int = p.get(k).toInt() and 0xFF

        /** Advances to the next element tag, skipping text, comments, PIs, DOCTYPE. */
        fun nextTag(): Tag? {
            while (i < end) {
                val lt = find('<'.code, i)
                if (lt == null) { i = end; return null }
                i = lt + 1
                if (i >= end) return null
                when (at(i)) {
                    '!'.code -> i = when {
                        matches("!--", i) -> (findSequence("-->", i + 3) ?: (end - 3)) + 3
                        matches("![CDATA[", i) -> (findSequence("]]>", i + 8) ?: (end - 3)) + 3
                        else -> (find('>'.code, i) ?: (end - 1)) + 1
                    }
                    '?'.code -> i = (findSequence("?>", i) ?: (end - 2)) + 2
                    else -> return readTag()
                }
            }
            return null
        }

        /** Reads a tag starting just after `<`. */
        fun readTag(): Tag {
            var closing = false
            if (at(i) == '/'.code) { closing = true; i++ }
            val nameStart = i
            while (i < end && !isSpace(at(i)) && at(i) != '>'.code && at(i) != '/'.code) i++
            val name = string(nameStart, i)
            val attrs = HashMap<String, String>()
            var selfClosing = false
            while (i < end) {
                while (i < end && isSpace(at(i))) i++
                if (i >= end) break
                if (at(i) == '>'.code) { i++; break }
                if (at(i) == '/'.code) { selfClosing = true; i++; continue }
                val keyStart = i
                while (i < end && at(i) != '='.code && !isSpace(at(i)) && at(i) != '>'.code) i++
                val key = string(keyStart, i)
                while (i < end && isSpace(at(i))) i++
                if (i >= end || at(i) != '='.code) continue
                i++
                while (i < end && isSpace(at(i))) i++
                if (i >= end) break
                val quote = at(i)
                if (quote == '"'.code || quote == '\''.code) {
                    val vStart = i + 1
                    val vEnd = find(quote, vStart) ?: end
                    attrs[key] = decodeEntities(vStart, vEnd)
                    i = minOf(end, vEnd + 1)
                } else {
                    val vStart = i
                    while (i < end && !isSpace(at(i)) && at(i) != '>'.code) i++
                    attrs[key] = decodeEntities(vStart, i)
                }
            }
            return Tag(name, attrs, closing, selfClosing)
        }

        fun parseChannel(tag: Tag): XMLTVChannel? {
            val id = tag.attributes["id"].nilIfEmpty()
            if (id == null) {
                if (!tag.isSelfClosing) skipElement("channel")
                return null
            }
            val channel = XMLTVChannel(id)
            if (tag.isSelfClosing) return channel
            while (true) {
                val child = nextTag() ?: break
                if (child.isClosing) {
                    if (child.name == "channel") break
                    continue
                }
                when (child.name) {
                    "display-name" -> if (!child.isSelfClosing) readText().nilIfEmpty()?.let { channel.displayNames.add(it) }
                    "icon" -> {
                        if (channel.iconURL == null) channel.iconURL = child.attributes["src"].nilIfEmpty()
                        if (!child.isSelfClosing) skipElement("icon")
                    }
                    else -> if (!child.isSelfClosing) skipElement(child.name)
                }
            }
            return channel
        }

        fun parseProgramme(tag: Tag): XMLTVProgramme? {
            val channel = tag.attributes["channel"]
            val start = tag.attributes["start"]?.let { XMLTVDate.parse(it) }
            val stop = tag.attributes["stop"]?.let { XMLTVDate.parse(it) }
            var title: String? = null
            var subtitle: String? = null
            var desc: String? = null
            var category: String? = null
            var icon: String? = null
            var episode: String? = null
            var onscreenEpisode: String? = null

            if (!tag.isSelfClosing) {
                while (true) {
                    val child = nextTag() ?: break
                    if (child.isClosing) {
                        if (child.name == "programme") break
                        continue
                    }
                    if (child.isSelfClosing) {
                        if (child.name == "icon" && icon == null) icon = child.attributes["src"].nilIfEmpty()
                        continue
                    }
                    when (child.name) {
                        "title" -> readText().let { if (title == null) title = it.nilIfEmpty() }
                        "sub-title" -> readText().let { if (subtitle == null) subtitle = it.nilIfEmpty() }
                        "desc" -> readText().let { if (desc == null) desc = it.nilIfEmpty() }
                        "category" -> readText().let { if (category == null) category = it.nilIfEmpty() }
                        "episode-num" -> {
                            val system = child.attributes["system"] ?: ""
                            val t = readText().nilIfEmpty()
                            if (system == "onscreen") onscreenEpisode = t
                            else if (system == "xmltv_ns") episode = t?.let { XMLTVDate.formatXMLTVNS(it) }
                        }
                        "icon" -> {
                            if (icon == null) icon = child.attributes["src"].nilIfEmpty()
                            skipElement("icon")
                        }
                        else -> skipElement(child.name)
                    }
                }
            }
            if (channel == null || start == null || stop == null || !stop.isAfter(start)) return null
            return XMLTVProgramme(channel, start, stop, title ?: "", subtitle, desc, category, icon, onscreenEpisode ?: episode)
        }

        /** Reads character data (text + CDATA, entities decoded) up to the closing tag. */
        fun readText(): String {
            val result = StringBuilder()
            var segmentStart = i
            while (i < end) {
                val lt = find('<'.code, i)
                if (lt == null) { i = end; break }
                if (lt > segmentStart) result.append(decodeEntities(segmentStart, lt))
                i = lt + 1
                if (matches("![CDATA[", i)) {
                    val cStart = i + 8
                    val cEnd = findSequence("]]>", cStart) ?: end
                    result.append(string(cStart, cEnd))
                    i = minOf(end, cEnd + 3)
                    segmentStart = i
                } else if (matches("!--", i)) {
                    i = (findSequence("-->", i + 3) ?: (end - 3)) + 3
                    segmentStart = i
                } else if (i < end && at(i) == '/'.code) {
                    // closing tag: assume it is ours (text elements have no element children)
                    i = (find('>'.code, i) ?: (end - 1)) + 1
                    return result.toString().trim()
                } else {
                    // Unexpected nested element inside text: skip it.
                    if (i < end) {
                        val tag = readTag()
                        if (!tag.isSelfClosing && !tag.isClosing) skipElement(tag.name)
                    }
                    segmentStart = i
                }
            }
            return result.toString().trim()
        }

        /** Skips to the matching `</name>`, honouring nesting of the same element. */
        fun skipElement(name: String) {
            var depth = 1
            while (depth > 0) {
                val tag = nextTag() ?: break
                if (tag.name == name) {
                    if (tag.isClosing) depth-- else if (!tag.isSelfClosing) depth++
                }
            }
        }

        private fun isSpace(b: Int) = b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09

        private fun find(byte: Int, from: Int): Int? {
            var k = from
            while (k < end) {
                if (at(k) == byte) return k
                k++
            }
            return null
        }

        private fun findSequence(seq: String, from: Int): Int? {
            var j = from
            while (true) {
                val k = find(seq[0].code, j) ?: return null
                if (matches(seq, k)) return k
                j = k + 1
            }
        }

        private fun matches(seq: String, pos: Int): Boolean {
            if (pos + seq.length > end) return false
            for (k in seq.indices) if (at(pos + k) != seq[k].code) return false
            return true
        }

        private fun string(from: Int, to: Int): String {
            if (to <= from) return ""
            val bytes = ByteArray(to - from)
            p.get(from, bytes)
            return String(bytes, Charsets.UTF_8)
        }

        private fun decodeEntities(from: Int, to: Int): String {
            if (to <= from) return ""
            if (find('&'.code, from).let { it == null || it >= to }) return string(from, to)
            val out = java.io.ByteArrayOutputStream(to - from)
            var k = from
            while (k < to) {
                val b = at(k)
                val semi = if (b == '&'.code) find(';'.code, k) else null
                if (semi == null || semi >= to || semi - k > 10) {
                    out.write(b)
                    k++
                    continue
                }
                val entity = string(k + 1, semi)
                val replacement: String? = when (entity) {
                    "amp" -> "&"
                    "lt" -> "<"
                    "gt" -> ">"
                    "quot" -> "\""
                    "apos" -> "'"
                    "nbsp" -> " "
                    else -> when {
                        entity.startsWith("#x") || entity.startsWith("#X") -> scalar(entity.substring(2), 16)
                        entity.startsWith("#") -> scalar(entity.substring(1), 10)
                        else -> null
                    }
                }
                if (replacement != null) {
                    out.write(replacement.toByteArray(Charsets.UTF_8))
                    k = semi + 1
                } else {
                    out.write(b)
                    k++
                }
            }
            return String(out.toByteArray(), Charsets.UTF_8)
        }

        /** Swift `UInt32(_, radix:)` + `Unicode.Scalar.init`: a valid scalar (no surrogates), or null. */
        private fun scalar(digits: String, radix: Int): String? {
            val body = digits.removePrefix("+")
            if (body.isEmpty() || !body.all { Character.digit(it, radix) >= 0 }) return null
            val v = body.toLongOrNull(radix) ?: return null
            if (v > 0xFFFFFFFFL || v > 0x10FFFF || v in 0xD800..0xDFFF) return null
            return String(Character.toChars(v.toInt()))
        }
    }
}

public object XMLTVDate {
    /** Parses `YYYYMMDDhhmmss ±hhmm` (seconds, minutes and offset optional). Missing offset = UTC. */
    public fun parse(s: String): Instant? {
        val bytes = s.toByteArray(Charsets.UTF_8)
        if (bytes.size < 8) return null
        fun num(from: Int, len: Int): Int? {
            if (from + len > bytes.size) return null
            var v = 0
            for (k in from until from + len) {
                val d = (bytes[k].toInt() and 0xFF) - 48
                if (d < 0 || d > 9) return null
                v = v * 10 + d
            }
            return v
        }
        val year = num(0, 4) ?: return null
        val month = num(4, 2) ?: return null
        val day = num(6, 2) ?: return null
        val hour = num(8, 2) ?: 0
        val minute = num(10, 2) ?: 0
        val second = num(12, 2) ?: 0

        var offsetSeconds = 0
        var k = 8
        while (k < bytes.size && bytes[k] in 48..57) k++
        while (k < bytes.size && bytes[k] == 0x20.toByte()) k++
        if (k < bytes.size && (bytes[k] == '+'.code.toByte() || bytes[k] == '-'.code.toByte())) {
            val sign = if (bytes[k] == '-'.code.toByte()) -1 else 1
            val hh = num(k + 1, 2)
            if (hh != null) {
                val mm = num(k + 3, 2) ?: 0
                offsetSeconds = sign * (hh * 3600 + mm * 60)
            }
        }
        val days = daysFromCivil(year, month, day)
        val epoch = days * 86400 + hour * 3600L + minute * 60L + second - offsetSeconds
        return Instant.ofEpochSecond(epoch)
    }

    /** Howard Hinnant's days-from-civil (proleptic Gregorian). Same arithmetic as Swift, including invalid dates. */
    internal fun daysFromCivil(y0: Int, m: Int, d: Int): Long {
        val y = (if (m <= 2) y0 - 1 else y0).toLong()
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val mp = ((m + 9) % 12).toLong()
        val doy = (153 * mp + 2) / 5 + d - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /** `xmltv_ns` "season.episode.part" (zero-based) → "S01E05". */
    internal fun formatXMLTVNS(s: String): String? {
        val parts = s.split('.').map { it.trim(' ', '\t') }
        if (parts.size < 2) return null
        val season = parts[0].split('/').firstOrNull { it.isNotEmpty() }?.toIntStrict()
        val episode = parts[1].split('/').firstOrNull { it.isNotEmpty() }?.toIntStrict()
        return when {
            season != null && episode != null -> "S%02dE%02d".format(season + 1, episode + 1)
            season == null && episode != null -> "E${episode + 1}"
            season != null -> "S${season + 1}"
            else -> null
        }
    }
}
