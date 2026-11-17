// Port of Sources/TunerCore/Models/Channel.swift @ 666f598
package app.tuner.core.models

import app.tuner.core.nilIfEmpty
import java.time.Instant

public enum class CategoryKind(public val raw: String) {
    LIVE("live"), MOVIE("movie"), SERIES("series");

    public companion object {
        public fun of(raw: String): CategoryKind? = entries.firstOrNull { it.raw == raw }
    }
}

public data class Category(
    var id: String,
    var sourceId: String,
    var kind: CategoryKind,
    var name: String,
    var providerOrder: Int,
    // User state (joined from categoryPref)
    var isHidden: Boolean = false,
    var alias: String? = null,
    var sortIndex: Int? = null,
    /** Number of visible items (filled by list queries). */
    var itemCount: Int = 0,
) {
    public val displayName: String get() = alias.nilIfEmpty() ?: name
}

/** How a channel's archive (catchup) is addressed. */
public enum class CatchupType(public val raw: String) {
    /** Xtream `timeshift/` endpoint. */
    XTREAM("xtream"),
    /** `?utc=START&lutc=NOW` */
    APPEND("append"),
    /** `?utc=START` (also "siptv"). */
    SHIFT("shift"),
    /** Flussonic `video-START-DURATION.m3u8`. */
    FLUSSONIC("flussonic"),
    /** `?start=START` or a `catchup-source` template. */
    DEFAULT("default"),
    /** Stalker `tv_archive` create_link. */
    STALKER("stalker");

    public companion object {
        public fun of(raw: String): CatchupType? = entries.firstOrNull { it.raw == raw }

        /** The M3U `catchup="…"` attribute. */
        public fun fromM3U(value: String): CatchupType = when (value.lowercase()) {
            "append" -> APPEND
            "shift", "siptv", "timeshift" -> SHIFT
            "flussonic", "flussonic-hls", "flussonic-ts", "fs" -> FLUSSONIC
            "xc" -> XTREAM
            else -> DEFAULT
        }
    }
}

public data class Channel(
    var id: String,
    var sourceId: String,
    var categoryId: String?,
    var name: String,
    var number: Int? = null,
    var providerOrder: Int,
    var logoURL: String? = null,
    /** The provider's EPG channel id (`tvg-id`, Xtream `epg_channel_id`, Stalker `xmltv_id`). */
    var tvgId: String? = null,
    /** Direct URL, or an opaque `stalker:` locator. Empty for Xtream (built from `providerStreamId` at play time). */
    var streamURL: String,
    /** Raw provider id (Xtream stream_id, Stalker channel id). */
    var providerStreamId: String? = null,
    var catchupType: CatchupType? = null,
    var catchupSource: String? = null,
    var catchupDays: Int? = null,
    /** Per-channel HTTP headers from `#EXTVLCOPT`. */
    var userAgent: String? = null,
    var referrer: String? = null,
    var isAdult: Boolean = false,
    /** Resolved EPG key (`feedId|xmltvId`) computed after guide ingestion. */
    var epgKey: String? = null,
    // User state (joined from channelPref)
    var isFavorite: Boolean = false,
    var favoriteOrder: Int? = null,
    var isHidden: Boolean = false,
    var alias: String? = null,
    var epgIdOverride: String? = null,
) {
    public val displayName: String get() = alias.nilIfEmpty() ?: name
    public val hasCatchup: Boolean get() = catchupType != null && (catchupDays ?: 1) > 0

    /**
     * A programme that has started and that the provider's archive still holds (`catchupDays` back from now).
     * Port of LiveGuideStore.catchupAvailable (Sources/Tuner/Views/Live/LiveGuideStore.swift).
     */
    public fun catchupAvailable(program: Program, now: Instant): Boolean {
        if (!hasCatchup || !program.start.isBefore(now)) return false
        val days = catchupDays
        return if (days != null && days > 0) !program.start.isBefore(now.minusSeconds(days * 86_400L)) else true
    }
}
