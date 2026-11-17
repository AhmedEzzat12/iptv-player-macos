package app.tuner.tv.ui.player

import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.tv.material3.ListItem
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import app.tuner.core.audio.SleepTimer
import app.tuner.core.audio.SleepTimerOption
import app.tuner.tv.ui.TunerColors
import app.tuner.tv.ui.initialFocus
import java.util.Locale

/** Picture size choices, as in the Apple player's Aspect Ratio menu (`VideoAspect` in PlaybackEngine.swift). */
enum class VideoAspect(val title: String) {
    FIT("Fit"), FILL("Fill (crop)"), STRETCH("Stretch"), RATIO_16X9("16:9"), RATIO_4X3("4:3");

    /** How PlayerView scales the video inside its frame. */
    val resizeMode: Int @OptIn(UnstableApi::class) get() = when (this) {
        FIT -> AspectRatioFrameLayout.RESIZE_MODE_FIT
        FILL -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
        STRETCH, RATIO_16X9, RATIO_4X3 -> AspectRatioFrameLayout.RESIZE_MODE_FILL
    }

    /** A forced frame shape (the video is stretched into it), or null to use the whole screen. */
    val frameRatio: Float? get() = when (this) {
        RATIO_16X9 -> 16f / 9f
        RATIO_4X3 -> 4f / 3f
        else -> null
    }
}

/** One selectable audio or subtitle track. */
data class TrackChoice(val group: Tracks.Group, val index: Int, val label: String, val selected: Boolean)

@OptIn(UnstableApi::class)
fun trackChoices(tracks: Tracks, type: Int): List<TrackChoice> {
    val out = ArrayList<TrackChoice>()
    for (group in tracks.groups) {
        if (group.type != type) continue
        for (i in 0 until group.length) {
            if (!group.isTrackSupported(i)) continue
            out += TrackChoice(group, i, trackLabel(group.getTrackFormat(i), out.size + 1), group.isTrackSelected(i))
        }
    }
    return out
}

/** "English · 5.1", "Arabic (Forced)", or "Track 2" when the stream names nothing. */
private fun trackLabel(format: Format, number: Int): String {
    val language = format.language?.takeIf { it.isNotEmpty() && it != C.LANGUAGE_UNDETERMINED && it != "und" }
        ?.let { Locale.forLanguageTag(it).getDisplayLanguage(Locale.getDefault()).ifEmpty { it } }
    val name = format.label?.takeIf { it.isNotBlank() } ?: language ?: "Track $number"
    val extras = buildList {
        if (language != null && format.label != null && !format.label!!.contains(language, ignoreCase = true)) add(language)
        when (format.channelCount) { 1 -> add("Mono"); 2 -> {}; 6 -> add("5.1"); 8 -> add("7.1"); Format.NO_VALUE -> {} else -> add("${format.channelCount} ch") }
        if (format.selectionFlags and C.SELECTION_FLAG_FORCED != 0) add("Forced")
    }
    return (listOf(name) + extras).joinToString(" · ")
}

fun ExoPlayer.selectTrack(choice: TrackChoice) {
    trackSelectionParameters = trackSelectionParameters.buildUpon()
        .setTrackTypeDisabled(choice.group.type, false)
        .setOverrideForType(TrackSelectionOverride(choice.group.mediaTrackGroup, choice.index))
        .build()
}

fun ExoPlayer.subtitlesOff() {
    trackSelectionParameters = trackSelectionParameters.buildUpon()
        .clearOverridesOfType(C.TRACK_TYPE_TEXT)
        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        .build()
}

private data class Row(val key: String, val title: String, val selected: Boolean, val onClick: () -> Unit)

/** A shortcut at the top of the options panel (next episode, favourite channel…). */
data class PlayerAction(val title: String, val onClick: () -> Unit)

/**
 * The player's options, a panel on the right like the Apple TV app's: shortcuts first (`actions`: next and previous
 * episode, or add the channel to Favorites), then Audio, Subtitles, Picture and Sleep Timer.
 * Opened with ▼ while the controls are showing (movies and episodes), or with the remote's menu/info/captions
 * key or a long press on OK (live TV, where ▼ changes channel).
 */
@Composable
fun PlayerOptionsPanel(
    tracks: Tracks,
    aspect: VideoAspect,
    sleep: SleepTimer?,
    sleepRemaining: Double?,
    isLive: Boolean,
    onAudio: (TrackChoice) -> Unit,
    onSubtitle: (TrackChoice?) -> Unit,
    onAspect: (VideoAspect) -> Unit,
    onSleep: (SleepTimerOption?) -> Unit,
    actionsTitle: String = "",
    actions: List<PlayerAction> = emptyList(),
) {
    val audio = trackChoices(tracks, C.TRACK_TYPE_AUDIO)
    val subtitles = trackChoices(tracks, C.TRACK_TYPE_TEXT)
    val sections = buildList<Pair<String, List<Row>>> {
        if (actions.isNotEmpty()) add(actionsTitle to actions.mapIndexed { i, a -> Row("x$i${a.title}", a.title, false, a.onClick) })
        if (audio.size > 1) add("Audio" to audio.map { c -> Row("a${c.label}${c.index}", c.label, c.selected) { onAudio(c) } })
        // Ticks come from what the player has selected (a default or forced track can be on without being picked here).
        add("Subtitles" to (listOf(Row("s-off", "Off", subtitles.none { it.selected }) { onSubtitle(null) }) +
            subtitles.map { c -> Row("s${c.label}${c.index}", c.label, c.selected) { onSubtitle(c) } }))
        add("Picture" to VideoAspect.entries.map { a -> Row("p${a.name}", a.title, a == aspect) { onAspect(a) } })
        val timer = sleep?.option
        add("Sleep Timer" to buildList {
            add(Row("t-off", "Off", timer == null) { onSleep(null) })
            SleepTimerOption.presets.forEach { o ->
                val minutes = (o as SleepTimerOption.Minutes).minutes
                add(Row("t$minutes", "$minutes minutes", timer == o) { onSleep(o) })
            }
            add(Row("t-end", if (isLive) "When this programme ends" else "When this ends", timer == SleepTimerOption.EndOfItem) { onSleep(SleepTimerOption.EndOfItem) })
        })
    }
    // The first shortcut when there are any (Next Episode is what's usually wanted), else the first section's choice.
    val firstSelected = if (actions.isNotEmpty()) sections.first().second.first().key
        else sections.firstOrNull()?.second?.firstOrNull { it.selected }?.key

    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f))) {
        LazyColumn(
            Modifier.align(Alignment.CenterEnd).width(420.dp).fillMaxHeight()
                .background(TunerColors.surface.copy(alpha = 0.97f)).padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 32.dp),
        ) {
            for ((title, rows) in sections) {
                item(key = "h$title") {
                    Text(
                        if (title == "Sleep Timer" && sleepRemaining != null) "$title · ${SleepTimer.label(sleepRemaining)} left" else title,
                        style = MaterialTheme.typography.titleSmall, color = TunerColors.accent,
                        modifier = Modifier.padding(start = 12.dp, top = 18.dp, bottom = 6.dp),
                    )
                }
                items(rows, key = { it.key }) { row ->
                    ListItem(
                        selected = row.selected,
                        onClick = row.onClick,
                        headlineContent = { Text(row.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        trailingContent = { if (row.selected) Text("✓") else if (row.key.startsWith("x")) Text("›") },
                        modifier = Modifier.fillMaxWidth().initialFocus(enabled = row.key == firstSelected),
                    )
                }
            }
        }
    }
}
