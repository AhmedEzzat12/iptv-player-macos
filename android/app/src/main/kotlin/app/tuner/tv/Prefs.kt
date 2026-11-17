package app.tuner.tv

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.tuner.core.skip.SkipMode
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/**
 * The TV app's settings. Same names and defaults as the Apple app's Preferences.swift where the setting exists there;
 * backed by SharedPreferences and observable from Compose (reads are state reads).
 */
class Prefs(context: Context) {
    private val store = context.getSharedPreferences("prefs", Context.MODE_PRIVATE)

    // Playback
    /** Xtream live: "ts" (TS first, HLS if it fails; docs/android-parity.md) or "hls". Android only. */
    var liveFormat by string("liveFormat", "ts")
    var autoFailover by bool("autoFailover", true)
    var resumePlayback by bool("resumePlayback", true)
    var autoplayNextEpisode by bool("autoplayNextEpisode", true)
    /** Seconds; 0 = no countdown. */
    var upNextCountdown by int("upNextCountdown", 10)
    var skipSegmentsRaw by string("skipSegments", SkipMode.BUTTON.raw)
    val skipSegments: SkipMode get() = SkipMode.of(skipSegmentsRaw) ?: SkipMode.BUTTON

    // Guide & Library
    var liveRefreshHours by int("liveRefreshHours", 6)
    var vodRefreshHours by int("vodRefreshHours", 24)
    /** Recent searches, newest first (stored one per line; Apple: `recentSearches`). */
    var recentSearchesRaw by string("recentSearches", "")
    var recentSearches: List<String>
        get() = recentSearchesRaw.split('\n').filter { it.isNotBlank() }
        set(value) { recentSearchesRaw = value.joinToString("\n") }

    private fun bool(key: String, default: Boolean) = Pref(store.getBoolean(key, default)) { store.edit().putBoolean(key, it).apply() }
    private fun int(key: String, default: Int) = Pref(store.getInt(key, default)) { store.edit().putInt(key, it).apply() }
    private fun string(key: String, default: String) = Pref(store.getString(key, default) ?: default) { store.edit().putString(key, it).apply() }

    private class Pref<T>(initial: T, private val save: (T) -> Unit) : ReadWriteProperty<Any?, T> {
        private var state by mutableStateOf(initial)
        override fun getValue(thisRef: Any?, property: KProperty<*>): T = state
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: T) { state = value; save(value) }
    }
}
