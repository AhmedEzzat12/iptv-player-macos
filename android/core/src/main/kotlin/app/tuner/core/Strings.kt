package app.tuner.core

/** Swift's `nilIfEmpty`: trimmed, or null when blank. Trims Unicode whitespace like `whitespacesAndNewlines`. */
public fun String?.nilIfEmpty(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
