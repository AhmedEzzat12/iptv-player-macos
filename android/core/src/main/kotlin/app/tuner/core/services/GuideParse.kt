// Port of GuideService.Wanted / ParseResult / parse(fileAt:…) in Sources/TunerCore/Services/GuideService.swift @ 666f598
package app.tuner.core.services

import app.tuner.core.models.EPGChannel
import app.tuner.core.models.Program
import app.tuner.core.parsing.ChannelNameNormalizer
import app.tuner.core.parsing.XMLTVParser
import java.io.File
import java.time.Instant

/**
 * The pure parse step of guide ingest (no I/O besides reading the file). Smart (fuzzy) matching isn't in v1, so only
 * the exact filter (tvg-ids, normalised names incl. alternative display names) applies.
 */
public object GuideParse {
    /** Which guide channels to keep: lowercased tvg-ids/overrides and normalised channel names from the library. */
    public data class Wanted(val tvgIds: Set<String>, val names: Set<String>)

    public class Result {
        public var channels: List<EPGChannel> = emptyList()
        public val programmes: MutableList<Program> = mutableListOf()
        public val counts: MutableMap<String, Int> = HashMap()
        public var sawGuide: Boolean = false
    }

    /** Programmes older than this are dropped (bounded by the longest catchup window people use). */
    public const val PAST_RETENTION_SECONDS: Long = 7 * 86_400

    public const val FUTURE_RETENTION_SECONDS: Long = 10 * 86_400

    public fun parse(
        file: File,
        feedId: String,
        wanted: Wanted?,
        shiftSeconds: Long,
        windowStart: Instant,
        windowEnd: Instant,
    ): Result {
        val result = Result()
        val channelsById = LinkedHashMap<String, EPGChannel>()
        val allNames = HashMap<String, List<String>>()
        var wantedIds: Set<String>? = null // computed at the first programme
        val filterActive = wanted != null && (wanted.tvgIds.isNotEmpty() || wanted.names.isNotEmpty())

        fun computeWanted(): Set<String> {
            val w = wanted ?: return emptySet()
            val set = HashSet<String>()
            for ((id, ch) in channelsById) {
                if (id.lowercase() in w.tvgIds || ch.normalizedName in w.names) set.add(id)
            }
            // Also accept any of a channel's alternative display names.
            for ((id, names) in allNames) {
                if (id !in set && names.any { ChannelNameNormalizer.normalize(it) in w.names }) set.add(id)
            }
            return set
        }

        XMLTVParser.parse(file) { event ->
            when (event) {
                is XMLTVParser.Event.Channel -> {
                    result.sawGuide = true
                    val c = event.channel
                    channelsById[c.id] = EPGChannel(feedId, c.id, c.displayNames.firstOrNull() ?: c.id, c.iconURL)
                    allNames[c.id] = c.displayNames
                }
                is XMLTVParser.Event.Programme -> {
                    result.sawGuide = true
                    val p = event.programme
                    if (filterActive) {
                        val ids = wantedIds ?: computeWanted().also { wantedIds = it }
                        val known = channelsById.containsKey(p.channel)
                        val accepted = p.channel in ids || (!known && wanted.tvgIds.contains(p.channel.lowercase()))
                        if (!accepted) return@parse
                    }
                    val start = p.start.plusSeconds(shiftSeconds)
                    val end = p.stop.plusSeconds(shiftSeconds)
                    if (!end.isAfter(windowStart) || !start.isBefore(windowEnd)) return@parse
                    val key = "$feedId|${p.channel}"
                    result.programmes.add(
                        Program(epgKey = key, start = start, end = end, title = p.title.ifEmpty { "Untitled" },
                            subtitle = p.subtitle, summary = p.desc, category = p.category, iconURL = p.iconURL, episode = p.episode),
                    )
                    result.counts[key] = (result.counts[key] ?: 0) + 1
                    if (!channelsById.containsKey(p.channel)) {
                        channelsById[p.channel] = EPGChannel(feedId, p.channel, p.channel, null)
                    }
                }
            }
        }
        result.channels = channelsById.values.toList()
        return result
    }

    /** Clamps each programme's end to the next programme's start so cells never overlap. */
    public fun trimOverlaps(list: List<Program>): List<Program> {
        if (list.size <= 1) return list
        val out = ArrayList<Program>(list.size)
        for (p in list) {
            val last = out.lastOrNull()
            if (last != null) {
                if (!p.start.isAfter(last.start)) continue
                if (last.end.isAfter(p.start)) out[out.lastIndex] = last.copy(end = p.start)
            }
            out.add(p)
        }
        return out
    }
}
