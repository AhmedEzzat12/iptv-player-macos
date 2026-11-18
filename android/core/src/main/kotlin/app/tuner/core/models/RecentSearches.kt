// Port of Preferences.rememberSearch (Sources/Tuner/App/Preferences.swift)
package app.tuner.core.models

/** Searches the viewer acted on (opened or played a result from, or typed on Android TV), newest first. */
public object RecentSearches {
    public const val LIMIT: Int = 12

    /** `list` with `query` moved to the front (case-insensitively, so "Batman" replaces "batman"); queries shorter
     * than two characters aren't kept. */
    public fun remember(list: List<String>, query: String, limit: Int = LIMIT): List<String> {
        val trimmed = query.trim()
        if (trimmed.length < 2) return list
        return (listOf(trimmed) + list.filterNot { it.equals(trimmed, ignoreCase = true) }).take(limit)
    }

    /** A search kept because it was typed (Android TV: on pausing with results, or leaving the field for them). A
     * pause mid-word keeps "brea", so a newer search that extends the newest entry replaces it instead of adding
     * another ("brea" → "breaking"). */
    public fun rememberTyped(list: List<String>, query: String, limit: Int = LIMIT): List<String> {
        val trimmed = query.trim()
        val newest = list.firstOrNull()
        val rest = if (newest != null && trimmed.length > newest.length && trimmed.startsWith(newest, ignoreCase = true)) list.drop(1) else list
        return remember(rest, trimmed, limit)
    }
}
