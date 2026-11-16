// Port of Sources/TunerCore/Models/Source.swift @ 666f598
package app.tuner.core.models

import java.time.Instant
import java.util.UUID

/** A playlist provider configured by the user. */
public data class Source(
    var id: String = UUID.randomUUID().toString().uppercase(),
    var name: String,
    var kind: Kind,
    /** Playlist URL (M3U), server base URL (Xtream) or portal URL (Stalker). Local M3U files are `file://` URLs. */
    var url: String,
    var username: String? = null,
    var password: String? = null,
    /** Stalker MAC address, e.g. `00:1A:79:12:34:56`. */
    var mac: String? = null,
    /** Manual EPG URL; when set it replaces the provider-discovered one. */
    var epgURL: String? = null,
    var autoLoadEPG: Boolean = true,
    var extraEPGURLs: List<String> = emptyList(),
    var epgTimeshiftHours: Double = 0.0,
    var userAgent: String? = null,
    var backupURLs: List<String> = emptyList(),
    var enabled: Boolean = true,
    var includeLive: Boolean = true,
    var includeVOD: Boolean = true,
    /** Refresh interval in hours; null uses the global setting, 0 means manual only. */
    var refreshHours: Int? = null,
    var sortIndex: Int = 0,
    var createdAt: Instant = Instant.now(),
    /** No usable password on this device (restored from backup): off until the password is entered again. */
    var needsPassword: Boolean = false,
    // Sync status (written by SyncService)
    var lastSyncedAt: Instant? = null,
    var lastVODSyncedAt: Instant? = null,
    var lastError: String? = null,
    var expiresAt: Instant? = null,
    var activeConnections: Int? = null,
    var maxConnections: Int? = null,
    var discoveredEPGURL: String? = null,
    var channelCount: Int = 0,
    var movieCount: Int = 0,
    var seriesCount: Int = 0,
) {
    public enum class Kind(public val raw: String, public val displayName: String) {
        M3U("m3u", "M3U Playlist"),
        XTREAM("xtream", "Xtream Codes"),
        STALKER("stalker", "Stalker Portal");

        public companion object {
            public fun of(raw: String): Kind? = entries.firstOrNull { it.raw == raw }
        }
    }

    /** Server base URL without trailing slashes (Xtream/Stalker). */
    public val baseURL: String get() = url.trim().trimEnd('/')

    public val supportsVOD: Boolean get() = kind != Kind.M3U

    /** Never prints credentials. */
    override fun toString(): String = "Source(id=$id, name=$name, kind=${kind.raw})"
}
