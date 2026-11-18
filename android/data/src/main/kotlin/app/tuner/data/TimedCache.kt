package app.tuner.data

/** A small in-memory map whose entries expire after `ttlMillis`; least recently used entries go first past `capacity`. */
internal class TimedCache<K, V : Any>(private val capacity: Int, private val ttlMillis: Long, private val clock: () -> Long = System::currentTimeMillis) {
    private class Entry<V>(val value: V, val at: Long)

    private val entries = object : LinkedHashMap<K, Entry<V>>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, Entry<V>>): Boolean = size > capacity
    }

    @Synchronized
    fun get(key: K): V? {
        val e = entries[key] ?: return null
        if (clock() - e.at > ttlMillis) { entries.remove(key); return null }
        return e.value
    }

    @Synchronized
    fun put(key: K, value: V) { entries[key] = Entry(value, clock()) }
}
