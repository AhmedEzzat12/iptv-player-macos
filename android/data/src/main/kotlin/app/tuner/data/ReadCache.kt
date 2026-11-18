package app.tuner.data

/**
 * Library reads kept in memory, each tagged with the kinds of change that make it stale (`Change`). A write forgets
 * the entries that depend on what it changed. A read that started before such a write isn't stored when it finishes
 * (its generation is out of date), so a slow query can't put stale rows back after the write cleared them.
 * Least recently used entries go first once there are `capacity` of them (a big playlist's channel list is a few MB).
 */
internal class ReadCache(private val capacity: Int = 48) {
    private class Entry(val value: Any?, val dependsOn: Array<out Change>)

    private val entries = object : LinkedHashMap<String, Entry>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>): Boolean = size > capacity
    }
    private val generations = LongArray(Change.entries.size)

    @Suppress("UNCHECKED_CAST")
    @Synchronized
    fun <T> get(key: String): T? = entries[key]?.value as T?

    /** The generation of `dependsOn` now, to pass to `put` once the read has finished. */
    @Synchronized
    fun generation(dependsOn: Array<out Change>): Long = dependsOn.sumOf { generations[it.ordinal] }

    @Synchronized
    fun put(key: String, value: Any?, dependsOn: Array<out Change>, generation: Long) {
        if (value != null && generation(dependsOn) == generation) entries[key] = Entry(value, dependsOn)
    }

    @Synchronized
    fun invalidate(change: Change) {
        generations[change.ordinal]++
        entries.values.removeAll { change in it.dependsOn }
    }
}
