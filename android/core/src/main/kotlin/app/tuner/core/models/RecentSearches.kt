// Port of Preferences.rememberSearch (Sources/Tuner/App/Preferences.swift)
package app.tuner.core.models

/** Searches the viewer acted on (opened or played a result from), newest first. */
public object RecentSearches {
    public const val LIMIT: Int = 12

    /** `list` with `query` moved to the front (case-insensitively, so "Batman" replaces "batman"); queries shorter
     * than two characters aren't kept. */
    public fun remember(list: List<String>, query: String, limit: Int = LIMIT): List<String> {
        val trimmed = query.trim()
        if (trimmed.length < 2) return list
        return (listOf(trimmed) + list.filterNot { it.equals(trimmed, ignoreCase = true) }).take(limit)
    }
}
