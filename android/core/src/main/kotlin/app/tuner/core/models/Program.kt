// Port of Sources/TunerCore/Models/Program.swift @ 666f598
package app.tuner.core.models

import app.tuner.core.parsing.ChannelNameNormalizer
import java.time.Duration
import java.time.Instant

/** A guide entry (XMLTV `<programme>`). */
public data class Program(
    var id: Long? = null,
    /** `feedId|xmltvId` */
    var epgKey: String,
    var start: Instant,
    var end: Instant,
    var title: String,
    var subtitle: String? = null,
    var summary: String? = null,
    var category: String? = null,
    var iconURL: String? = null,
    var episode: String? = null,
) {
    /** Seconds. */
    public val duration: Double get() = Duration.between(start, end).toMillis() / 1000.0

    public fun isLive(at: Instant = Instant.now()): Boolean = !start.isAfter(at) && at.isBefore(end)

    public fun progress(at: Instant = Instant.now()): Double {
        if (duration <= 0) return 0.0
        return (Duration.between(start, at).toMillis() / 1000.0 / duration).coerceIn(0.0, 1.0)
    }

    /** Stable identity independent of the database row id. */
    public val stableKey: String get() = "$epgKey@${start.epochSecond}"
}

/** An XMLTV feed tracked by the guide service. */
public data class EPGFeed(
    var id: String,
    var url: String,
    /** Owning source, or null for a global feed. */
    var sourceId: String?,
    var priority: Int,
    var lastFetchedAt: Instant? = null,
    var lastError: String? = null,
    var channelCount: Int = 0,
    var programCount: Int = 0,
)

public data class EPGChannel(
    var feedId: String,
    var xmltvId: String,
    var displayName: String,
    var iconURL: String?,
) {
    public val key: String get() = "$feedId|$xmltvId"
    public val normalizedName: String by lazy { ChannelNameNormalizer.normalize(displayName) }
}
