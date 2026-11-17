// Port of Sources/TunerCore/Services/StreamResolver.swift @ 666f598 (downloads aren't in v1).
package app.tuner.data

import app.tuner.core.models.Channel
import app.tuner.core.models.Episode
import app.tuner.core.models.Movie
import app.tuner.core.models.Program
import app.tuner.core.models.Source
import app.tuner.core.net.HttpClient
import app.tuner.core.parsing.CatchupURLBuilder
import app.tuner.core.providers.StalkerClient
import app.tuner.core.providers.StalkerLocator
import app.tuner.core.providers.XtreamClient
import app.tuner.core.providers.XtreamURLs
import java.time.Instant

/** A fully resolved stream ready for a playback engine. Never logged (Xtream URLs carry credentials). */
public data class PlayableStream(val url: String, val userAgent: String, val referrer: String? = null, val kind: Kind) {
    public enum class Kind { LIVE, CATCHUP, VOD }

    public val headers: Map<String, String> get() = buildMap { put("User-Agent", userAgent); referrer?.let { put("Referer", it) } }

    override fun toString(): String = "PlayableStream(kind=$kind)"
}

public class StreamException(message: String) : Exception(message)

public class StreamResolver(private val library: Library, private val sync: SyncService) {
    private val xtreamOffsets = HashMap<String, Double>()
    public var defaultUserAgent: String = HttpClient.DEFAULT_USER_AGENT

    private suspend fun source(id: String) = library.source(id) ?: throw StreamException("This item's playlist was removed")

    private fun userAgent(channel: Channel?, source: Source) =
        channel?.userAgent?.ifBlank { null } ?: source.userAgent?.ifBlank { null }
            ?: if (source.kind == Source.Kind.STALKER) StalkerClient.MAG_USER_AGENT else defaultUserAgent

    /** Android requests Xtream live as TS first (docs/android-parity.md); the player retries M3U8 on failure. */
    public suspend fun live(channel: Channel, format: XtreamURLs.LiveFormat = XtreamURLs.LiveFormat.TS): PlayableStream {
        val source = source(channel.sourceId)
        val ua = userAgent(channel, source)
        return when (source.kind) {
            Source.Kind.XTREAM -> {
                val id = channel.providerStreamId ?: throw StreamException("Invalid stream: ${channel.name}")
                PlayableStream(XtreamClient(source).urls.liveURL(id, format), ua, kind = PlayableStream.Kind.LIVE)
            }
            Source.Kind.STALKER -> {
                val locator = StalkerLocator.decode(channel.streamURL) ?: throw StreamException("Invalid stream: ${channel.name}")
                PlayableStream(sync.stalkerClient(source).resolve(locator), ua, kind = PlayableStream.Kind.LIVE)
            }
            Source.Kind.M3U -> {
                var url = channel.streamURL.trim()
                if (format == XtreamURLs.LiveFormat.M3U8 && channel.providerStreamId != null && url.endsWith(".ts")) url = url.dropLast(3) + ".m3u8"
                PlayableStream(url, ua, channel.referrer, PlayableStream.Kind.LIVE)
            }
        }
    }

    public suspend fun catchup(channel: Channel, program: Program, paddingSeconds: Long = 0): PlayableStream {
        val type = channel.catchupType ?: throw StreamException("This channel has no archive for that programme")
        val source = source(channel.sourceId)
        val ua = userAgent(channel, source)
        val start = program.start.minusSeconds(paddingSeconds)
        val end = minOf(program.end.plusSeconds(paddingSeconds), Instant.now()).let { if (it.isAfter(start)) it else program.end }
        val minutes = kotlin.math.ceil((end.epochSecond - start.epochSecond) / 60.0).toInt()
        return when (source.kind) {
            Source.Kind.STALKER -> {
                val cmd = (StalkerLocator.decode(channel.streamURL) as? StalkerLocator.ChannelCmd)?.cmd ?: ""
                PlayableStream(sync.stalkerClient(source).catchupURL(channel.providerStreamId ?: "", cmd, start, end), ua, kind = PlayableStream.Kind.CATCHUP)
            }
            Source.Kind.XTREAM -> {
                val id = channel.providerStreamId ?: throw StreamException("This channel has no archive for that programme")
                val client = XtreamClient(source)
                PlayableStream(client.urls.timeshiftURL(id, start, minutes, offset(client, source.id)), ua, kind = PlayableStream.Kind.CATCHUP)
            }
            Source.Kind.M3U -> PlayableStream(
                CatchupURLBuilder.m3u(channel.streamURL, type, channel.catchupSource, channel.tvgId, start, end), ua, channel.referrer, PlayableStream.Kind.CATCHUP)
        }
    }

    private suspend fun offset(client: XtreamClient, key: String): Double =
        xtreamOffsets[key] ?: (runCatching { client.authenticate().serverTimeOffset }.getOrDefault(0.0)).also { xtreamOffsets[key] = it }

    public suspend fun movie(movie: Movie): PlayableStream {
        val source = source(movie.sourceId)
        val ua = userAgent(null, source)
        return when (source.kind) {
            Source.Kind.XTREAM -> PlayableStream(XtreamClient(source).urls.movieURL(movie.providerId, movie.containerExtension), ua, kind = PlayableStream.Kind.VOD)
            Source.Kind.STALKER -> PlayableStream(sync.stalkerClient(source).resolve(StalkerLocator.decode(movie.streamURL)
                ?: throw StreamException("Invalid stream")), ua, kind = PlayableStream.Kind.VOD)
            Source.Kind.M3U -> PlayableStream(movie.streamURL.trim(), ua, kind = PlayableStream.Kind.VOD)
        }
    }

    public suspend fun episode(episode: Episode): PlayableStream {
        val source = source(episode.sourceId)
        val ua = userAgent(null, source)
        return when (source.kind) {
            Source.Kind.XTREAM -> PlayableStream(XtreamClient(source).urls.episodeURL(episode.providerId, episode.containerExtension), ua, kind = PlayableStream.Kind.VOD)
            Source.Kind.STALKER -> PlayableStream(sync.stalkerClient(source).resolve(StalkerLocator.decode(episode.streamURL)
                ?: throw StreamException("Invalid stream")), ua, kind = PlayableStream.Kind.VOD)
            Source.Kind.M3U -> PlayableStream(episode.streamURL.trim(), ua, kind = PlayableStream.Kind.VOD)
        }
    }
}
