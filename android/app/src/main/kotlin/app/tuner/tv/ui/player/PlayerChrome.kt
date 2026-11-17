package app.tuner.tv.ui.player

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import app.tuner.core.models.Program
import app.tuner.tv.ui.PlaybackItem
import app.tuner.tv.ui.TunerColors
import app.tuner.tv.ui.browse.fmtClock
import coil3.compose.AsyncImage
import java.time.Instant

private val dim = Color.White.copy(alpha = 0.7f)

/**
 * The player's controls, laid out like the Apple TV app's: a top bar (channel or show, and the clock) and a bottom
 * panel with the title, a progress bar (played, buffered, and the scrub target while seeking) and the times.
 * Live TV shows the channel, a LIVE badge and the programme on now with what's next.
 */
@Composable
fun PlayerChrome(
    item: PlaybackItem,
    position: Double,
    duration: Double,
    buffered: Double,
    scrubTo: Double?,
    liveNow: Program?,
    liveNext: Program?,
) {
    Box(Modifier.fillMaxSize()) {
        // Top bar
        Row(
            Modifier.align(Alignment.TopStart).fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.7f), Color.Transparent)))
                .padding(start = 56.dp, end = 56.dp, top = 32.dp, bottom = 48.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val channel = (item as? PlaybackItem.Live)?.channel ?: (item as? PlaybackItem.Catchup)?.channel
            if (channel?.logoURL != null) {
                Box(Modifier.size(72.dp, 44.dp).background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
                    AsyncImage(channel.logoURL, null, Modifier.fillMaxSize().padding(5.dp), contentScale = ContentScale.Fit)
                }
                Spacer(Modifier.width(14.dp))
            }
            Text(
                when (item) {
                    is PlaybackItem.Live -> listOfNotNull(item.channel.number?.toString(), item.channel.displayName).joinToString("  ")
                    is PlaybackItem.Catchup -> item.channel.displayName
                    is PlaybackItem.EpisodeItem -> item.series.name
                    is PlaybackItem.MovieItem -> ""
                },
                style = MaterialTheme.typography.titleMedium, color = dim, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(fmtClock(Instant.now()), style = MaterialTheme.typography.titleMedium, color = dim)
        }

        // Bottom panel
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f), Color.Black.copy(alpha = 0.9f))))
                .padding(start = 56.dp, end = 56.dp, bottom = 36.dp, top = 80.dp),
        ) {
            when (item) {
                is PlaybackItem.Live -> LivePanel(liveNow, liveNext)
                else -> VodPanel(item, position, duration, buffered, scrubTo)
            }
        }
    }
}

@Composable
private fun VodPanel(item: PlaybackItem, position: Double, duration: Double, buffered: Double, scrubTo: Double?) {
    val eyebrow = when (item) {
        is PlaybackItem.EpisodeItem -> "Season ${item.episode.season}, Episode ${item.episode.number}"
        is PlaybackItem.MovieItem -> item.movie.year
        is PlaybackItem.Catchup -> "Catchup  ·  ${fmtClock(item.program.start)}–${fmtClock(item.program.end)}"
        else -> null
    }
    eyebrow?.let { Text(it.uppercase(), style = MaterialTheme.typography.labelLarge, color = dim) }
    Text(item.title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
    Spacer(Modifier.height(18.dp))
    val shown = scrubTo ?: position
    ProgressBar(
        played = if (duration > 0) (shown / duration).toFloat() else 0f,
        buffered = if (duration > 0) (buffered / duration).toFloat() else 0f,
        thumb = scrubTo != null,
    )
    Spacer(Modifier.height(10.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(time(shown), style = MaterialTheme.typography.titleSmall,
            color = if (scrubTo != null) TunerColors.accent else Color.White, fontWeight = if (scrubTo != null) FontWeight.Bold else null)
        if (scrubTo != null) {
            val delta = scrubTo - position
            Text("   ${if (delta >= 0) "+" else "−"}${time(kotlin.math.abs(delta))}", style = MaterialTheme.typography.titleSmall, color = dim)
        }
        Spacer(Modifier.weight(1f))
        Text("▼ Audio, subtitles and more", style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.5f))
        Spacer(Modifier.width(24.dp))
        Text(if (duration > 0) "−" + time(duration - shown) else "", style = MaterialTheme.typography.titleSmall, color = dim)
    }
}

@Composable
private fun LivePanel(now: Program?, next: Program?) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("LIVE", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = Color.White,
            modifier = Modifier.background(Color(0xFFE53935), RoundedCornerShape(4.dp)).padding(horizontal = 8.dp, vertical = 2.dp))
        if (now != null) {
            Spacer(Modifier.width(12.dp))
            Text("${fmtClock(now.start)} – ${fmtClock(now.end)}", style = MaterialTheme.typography.labelLarge, color = dim)
        }
    }
    Spacer(Modifier.height(6.dp))
    Text(now?.title ?: "No programme information", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold,
        maxLines = 1, overflow = TextOverflow.Ellipsis, color = if (now == null) dim else Color.White)
    now?.subtitle?.let { Text(it, color = dim, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    Spacer(Modifier.height(16.dp))
    if (now != null) ProgressBar(played = now.progress().toFloat(), buffered = 0f, thumb = false)
    Spacer(Modifier.height(10.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(next?.let { "Next  ${fmtClock(it.start)}  ${it.title}" } ?: "", style = MaterialTheme.typography.titleSmall, color = dim,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Text("▲▼ Channels   ·   Hold OK for audio, subtitles and more", style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.5f))
    }
}

/** A rounded bar: track, buffered part, played part, and a thumb while scrubbing. */
@Composable
private fun ProgressBar(played: Float, buffered: Float, thumb: Boolean) {
    BoxWithConstraints(Modifier.fillMaxWidth().height(14.dp), contentAlignment = Alignment.CenterStart) {
        val w = maxWidth
        Box(Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(Color.White.copy(alpha = 0.22f))) {
            Box(Modifier.fillMaxWidth(buffered.coerceIn(0f, 1f)).height(6.dp).background(Color.White.copy(alpha = 0.32f)))
            Box(Modifier.fillMaxWidth(played.coerceIn(0f, 1f)).height(6.dp).background(Color.White))
        }
        if (thumb) Box(Modifier.offset(x = w * played.coerceIn(0f, 1f) - 7.dp).size(14.dp).background(Color.White, CircleShape))
    }
}

/** Centre of the screen: a spinner while loading, a pause symbol while paused. */
@Composable
fun PlayerCenterIndicator(buffering: Boolean, paused: Boolean) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        when {
            buffering -> Spinner()
            paused -> Box(Modifier.size(96.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Pause, null, Modifier.size(56.dp), tint = Color.White)
            }
        }
    }
}

/** A brief play/pause flash in the centre when playback is toggled. */
@Composable
fun PlayPauseFlash(playing: Boolean) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Box(Modifier.size(96.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(if (playing) Icons.Filled.PlayArrow else Icons.Filled.Pause, null, Modifier.size(56.dp), tint = Color.White)
        }
    }
}

@Composable
private fun Spinner() {
    val angle by rememberInfiniteTransition(label = "spin").animateFloat(
        0f, 360f, infiniteRepeatable(tween(900, easing = LinearEasing), RepeatMode.Restart), label = "angle",
    )
    Canvas(Modifier.size(64.dp)) {
        drawArc(Color.White.copy(alpha = 0.2f), 0f, 360f, false, style = Stroke(6.dp.toPx()))
        drawArc(Color.White, angle, 100f, false, style = Stroke(6.dp.toPx(), cap = StrokeCap.Round))
    }
}

fun time(seconds: Double): String {
    val s = seconds.toLong().coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}
