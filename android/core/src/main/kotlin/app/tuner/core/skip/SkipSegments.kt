// Port of Sources/TunerCore/Skip/SkipSegments.swift @ 666f598
package app.tuner.core.skip

import java.text.Normalizer
import kotlin.math.abs

/** A part of a movie or episode the player offers to skip ("Skip Intro", "Skip Recap", "Skip Credits"). */
public data class SkipSegment(
    var kind: Kind,
    /** Seconds from the start of the media. */
    var start: Double,
    /** null: until the end of the media (credits). */
    var end: Double?,
    var source: Source,
    /** False for learned spans the user hasn't confirmed twice: button only, never skipped automatically. */
    var mayAutoSkip: Boolean = true,
) {
    public enum class Kind(public val raw: String) { RECAP("recap"), INTRO("intro"), CREDITS("credits") }

    /** Where the timing came from; `SkipSegments.merge` prefers them in this order. */
    public enum class Source(public val raw: String) {
        /** Chapter markers in the stream itself (exact for this file). */
        CHAPTERS("chapters"),
        /** TheIntroDB (api.theintrodb.org), crowd-sourced, by IMDb/TMDB id. */
        THE_INTRO_DB("theIntroDB"),
        /** IntroDB (api.introdb.app), crowd-sourced, by IMDb id. */
        INTRO_DB("introDB"),
        /** Spans the user skipped by hand in other episodes of the show. */
        LEARNED("learned"),
    }

    /** The end, with an open end resolved against the duration. */
    public fun resolvedEnd(duration: Double?): Double = end ?: duration ?: Double.POSITIVE_INFINITY

    public fun contains(position: Double, duration: Double?): Boolean = position >= start && position < resolvedEnd(duration)
}

/** A chapter marker read from the stream. */
public data class ChapterMark(val title: String?, val start: Double, val end: Double? = null)

/** How the player treats known intros and credits (Settings → Playback). */
public enum class SkipMode(public val raw: String) {
    /** A "Skip Intro" / "Skip Credits" button. */
    BUTTON("button"),
    /** Skip on its own, with a short notice. */
    AUTOMATIC("automatic"),
    OFF("off");

    public companion object {
        public fun of(raw: String): SkipMode? = entries.firstOrNull { it.raw == raw }
    }
}

/** Chapter classification, sanity checks against the playing file and merging of the sources. */
public object SkipSegments {
    private val story = setOf("post", "mid", "after", "scene", "stinger", "bonus", "tag", "preview", "next", "مشهد", "بعد", "القادمة", "القادم")
    private val recap = setOf("recap", "previously", "summary", "ملخص", "سابقا", "السابقة")
    private val arabicEnd = setOf("النهاية", "نهاية", "الختام", "الخاتمة", "ختام", "خاتمة")
    private val intro = setOf("intro", "introduction", "opening", "op", "theme", "titles", "title", "مقدمة", "المقدمة", "شارة", "الشارة", "تتر", "التتر")
    private val strongIntro = setOf("intro", "introduction", "opening", "op")
    private val credits = setOf("credits", "credit", "ending", "ed", "outro", "closing", "end", "endcredits")

    /**
     * The kind of segment a chapter title names, or null for story chapters ("Chapter 3"). English and the obvious Arabic
     * names. Scenes after or in the middle of the credits are story, not credits.
     */
    public fun classify(chapterTitle: String?): SkipSegment.Kind? {
        val words = normalizedWords(chapterTitle ?: return null)
        // Long titles are story chapters that happen to contain a keyword.
        if (words.isEmpty() || words.size > 4) return null
        val set = words.toSet()
        if (set.any { it in story }) return null
        if (set.any { it in recap }) return SkipSegment.Kind.RECAP
        if (set.any { it in arabicEnd }) return SkipSegment.Kind.CREDITS
        // "Opening credits" is the intro, so opening words win over "credits".
        val introWords = set.intersect(intro)
        if (introWords.any { it in strongIntro }) return SkipSegment.Kind.INTRO
        if (set.any { it in credits }) return SkipSegment.Kind.CREDITS
        // "Main titles", "Title sequence", "Theme song", "شارة"/"تتر" on their own.
        if (introWords.isNotEmpty()) {
            if (introWords == setOf("title") || introWords == setOf("titles")) {
                return if ("main" in set || "sequence" in set || "opening" in set) SkipSegment.Kind.INTRO else null
            }
            return SkipSegment.Kind.INTRO
        }
        return null
    }

    /** Lowercased words with digits, punctuation and diacritics removed ("OP 2" → ["op"]), alef forms folded. */
    internal fun normalizedWords(text: String): List<String> {
        // ICU's Any-StripDiacritics: NFD, drop non-spacing marks, NFC (Arabic harakat and hamza marks go too).
        val decomposed = Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD)
        val stripped = StringBuilder()
        decomposed.codePoints().forEach { if (Character.getType(it).toByte() != Character.NON_SPACING_MARK) stripped.appendCodePoint(it) }
        val folded = Normalizer.normalize(stripped, Normalizer.Form.NFC).replace("ـ", "").replace(Regex("[أإآ]"), "ا")
        val words = mutableListOf<String>()
        val word = StringBuilder()
        folded.codePoints().forEach { cp ->
            if (Character.isAlphabetic(cp)) word.appendCodePoint(cp)
            else if (word.isNotEmpty()) { words.add(word.toString()); word.setLength(0) }
        }
        if (word.isNotEmpty()) words.add(word.toString())
        return words
    }

    /** Segments named by chapter titles. A chapter runs until the next one starts (or the end of the media). */
    public fun fromChapters(chapters: List<ChapterMark>, duration: Double?): List<SkipSegment> {
        val ordered = chapters.filter { it.start.isFinite() && it.start >= 0 }.sortedBy { it.start }
        val out = mutableListOf<SkipSegment>()
        ordered.forEachIndexed { i, chapter ->
            val kind = classify(chapter.title) ?: return@forEachIndexed
            val next = ordered.getOrNull(i + 1)?.start
            var end = chapter.end ?: next ?: duration
            // The last chapter of a file running to the end: credits stay open-ended.
            if (next == null && kind == SkipSegment.Kind.CREDITS) end = null
            out.add(SkipSegment(kind, chapter.start, end, SkipSegment.Source.CHAPTERS))
        }
        // Adjacent chapters of the same kind ("OP part 1", "OP part 2") become one.
        val merged = mutableListOf<SkipSegment>()
        for (segment in out) {
            val last = merged.lastOrNull()
            val lastEnd = last?.end
            if (last != null && last.kind == segment.kind && lastEnd != null && abs(lastEnd - segment.start) < 1) {
                merged[merged.size - 1] = last.copy(end = segment.end)
            } else {
                merged.add(segment)
            }
        }
        return merged
    }

    /** Limits for timings from the online databases and learned spans (they describe a specific release). */
    public object Limits {
        /** An intro or recap ends within the first quarter and the first 10 minutes. */
        public const val INTRO_END_FRACTION: Double = 0.25
        public const val INTRO_END_MAX: Double = 600.0
        public val INTRO_LENGTH: ClosedFloatingPointRange<Double> = 5.0..300.0
        /** Credits start in the last 15 %. */
        public const val CREDITS_START_FRACTION: Double = 0.85
        /** Chapters are exact for the file, so they only have to be in the right half. */
        public const val CHAPTER_INTRO_START_FRACTION: Double = 0.4
        public const val CHAPTER_CREDITS_START_FRACTION: Double = 0.6
        /** Slack for rounding at the end of the file. */
        public const val END_SLACK: Double = 2.0
    }

    /** The segment if its times are plausible for a file of `duration` seconds, with the end clamped to the duration. */
    public fun sanitized(segment: SkipSegment, duration: Double?): SkipSegment? {
        var s = segment.copy()
        if (!s.start.isFinite() || s.start < 0) return null
        s.end?.let { end -> if (!end.isFinite() || end <= s.start + 1) return null }
        val d = duration?.takeIf { it.isFinite() && it > 0 }
        if (d != null) {
            if (s.start >= d - 1) return null
            s.end?.let { end ->
                // Times beyond the file's end come from another cut or an offset encode.
                if (end > d + Limits.END_SLACK) return null
                s = s.copy(end = minOf(end, d))
            }
        }
        if (s.source == SkipSegment.Source.CHAPTERS) {
            if (d == null) return s
            return when (s.kind) {
                SkipSegment.Kind.RECAP, SkipSegment.Kind.INTRO -> if (s.start < d * Limits.CHAPTER_INTRO_START_FRACTION) s else null
                SkipSegment.Kind.CREDITS -> if (s.start >= d * Limits.CHAPTER_CREDITS_START_FRACTION) s else null
            }
        }
        return when (s.kind) {
            SkipSegment.Kind.RECAP, SkipSegment.Kind.INTRO -> {
                val end = s.end ?: return null
                if (end - s.start !in Limits.INTRO_LENGTH || end > Limits.INTRO_END_MAX) return null
                if (d != null && end > d * Limits.INTRO_END_FRACTION) return null
                s
            }
            SkipSegment.Kind.CREDITS -> if (d != null && s.start >= d * Limits.CREDITS_START_FRACTION) s else null
        }
    }

    /**
     * The segments to offer, best source first per kind: chapters, then the online databases (TheIntroDB before
     * IntroDB), then learned spans. Each kind comes from a single source. Sorted by start.
     */
    public fun merge(candidates: List<SkipSegment>, duration: Double?): List<SkipSegment> {
        val sane = candidates.mapNotNull { sanitized(it, duration) }
        val out = mutableListOf<SkipSegment>()
        for (kind in SkipSegment.Kind.entries) {
            for (source in SkipSegment.Source.entries) {
                val picked = sane.filter { it.kind == kind && it.source == source }
                if (picked.isNotEmpty()) { out += picked; break }
            }
        }
        // Drop exact duplicates (two equal entries from one database).
        return out.distinct().sortedBy { it.start }
    }
}

/**
 * What the player shows or does for skip segments as the position moves (pure state; the player's SkipController
 * drives it from the 0.5 s poll). The button shows while inside a segment, pinned for the first `PINNED_SECONDS`
 * unless the controls are up; automatic mode skips a segment once; a segment seeked into or undone is never skipped
 * automatically again; credits only skip automatically when the caller allows it.
 */
public class SkipTracker(segments: List<SkipSegment> = emptyList()) {
    public data class Prompt(val segment: SkipSegment, val isFresh: Boolean)

    public sealed class Action {
        public object None : Action()
        public data class AutoSkip(val segment: SkipSegment) : Action()
    }

    public var segments: List<SkipSegment> = segments
        private set
    private val noAuto = HashSet<SkipSegment>()
    private val enteredAt = HashMap<SkipSegment, Double>()

    /** Replaces the segments (new information arrived); what happened to unchanged segments is kept. */
    public fun setSegments(new: List<SkipSegment>) {
        segments = new
        noAuto.retainAll(new.toSet())
        enteredAt.keys.retainAll(new.toSet())
    }

    /** The segment the position is in, if any (with enough of it left to be worth skipping). */
    public fun segment(position: Double, duration: Double?): SkipSegment? =
        segments.firstOrNull { it.contains(position, duration) && it.resolvedEnd(duration) - position >= MINIMUM_REMAINING }

    public fun update(position: Double, duration: Double?, mode: SkipMode, autoSkipCredits: Boolean): Pair<Prompt?, Action> {
        if (mode == SkipMode.OFF) return null to Action.None
        val current = segment(position, duration)
        // Leaving a segment resets its "fresh" window, so coming back shows the button again.
        enteredAt.keys.removeAll { it != current }
        if (current == null) return null to Action.None
        if (mode == SkipMode.AUTOMATIC && current.mayAutoSkip && current !in noAuto &&
            (current.kind != SkipSegment.Kind.CREDITS || autoSkipCredits)
        ) {
            noAuto.add(current)
            return null to Action.AutoSkip(current)
        }
        val entered = enteredAt[current] ?: position
        enteredAt[current] = entered
        val fresh = position - entered < PINNED_SECONDS && position >= entered
        return Prompt(current, fresh) to Action.None
    }

    /** A seek by the user: landing inside a segment means they want to watch it. */
    public fun userSeeked(position: Double, duration: Double?) {
        segment(position, duration)?.let { noAuto.add(it) }
    }

    /** The user undid an automatic skip (it isn't skipped again). */
    public fun undoAutoSkip(segment: SkipSegment) {
        noAuto.add(segment)
        enteredAt.remove(segment)
    }

    public companion object {
        public const val PINNED_SECONDS: Double = 6.0
        /** A segment with less than this left isn't offered any more. */
        public const val MINIMUM_REMAINING: Double = 1.5
    }
}
