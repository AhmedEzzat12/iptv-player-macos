package app.tuner.tv.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.Button
import androidx.tv.material3.ButtonDefaults
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.Icon
import androidx.tv.material3.IconButton
import androidx.tv.material3.IconButtonDefaults
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import coil3.compose.AsyncImage

/** How much a focused card grows (Appendix D → Focus). `FocusBleed` leaves room for it at the start of a row. */
const val CARD_FOCUS_SCALE = 1.08f

/** Card sizes, the same everywhere: posters six to a row beside the rail, landscape cards three and a bit. */
object CardSize {
    const val POSTER = 124
    const val WIDE = 248
    const val CHANNEL = 200
}

private val cardShape = RoundedCornerShape(12.dp)

/** The focused card's lift: a white rim and a soft shadow-glow, so focus reads on dark and bright artwork alike. */
@Composable
private fun cardBorder() = CardDefaults.border(
    focusedBorder = Border(BorderStroke(2.5.dp, Color.White.copy(alpha = 0.95f)), shape = cardShape),
)

@Composable
private fun cardGlow() = CardDefaults.glow(focusedGlow = Glow(elevationColor = Color.Black.copy(alpha = 0.8f), elevation = 18.dp))

/**
 * Artwork with its title as the placeholder: surface-coloured, never a spinner (Appendix D → Images). The title stays
 * until the picture has actually loaded, since provider image servers often answer with nothing.
 */
@Composable
fun Artwork(url: String?, title: String, modifier: Modifier = Modifier, fit: Boolean = false, titleLines: Int = 3) {
    var loaded by remember(url) { mutableStateOf(false) }
    Box(modifier.background(Brush.verticalGradient(listOf(TunerColors.raised, TunerColors.surface))), contentAlignment = Alignment.Center) {
        if (url == null || !loaded) {
            Text(title, Modifier.padding(12.dp), maxLines = titleLines, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.titleSmall, color = TunerColors.secondary)
        }
        if (url != null) AsyncImage(url, null, if (fit) Modifier.fillMaxSize().padding(18.dp) else Modifier.fillMaxSize(),
            contentScale = if (fit) ContentScale.Fit else ContentScale.Crop, onSuccess = { loaded = true })
    }
}

/** The title and caption under a card; brighter while the card has focus, like the Apple TV app's. */
@Composable
private fun CardCaption(title: String, subtitle: String?, focused: Boolean) {
    Spacer(Modifier.height(10.dp))
    Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall,
        color = if (focused) Color.White else Color.White.copy(alpha = 0.86f))
    if (subtitle != null) Text(subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis,
        color = if (focused) TunerColors.secondary else TunerColors.tertiary, style = MaterialTheme.typography.bodySmall)
}

/** A 2:3 poster card with the title under it. */
@Composable
fun PosterCard(title: String, imageURL: String?, subtitle: String? = null, width: Int = CardSize.POSTER, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Column(Modifier.width(width.dp)) {
        Card(onClick = onClick, onLongClick = onLongClick, interactionSource = interaction,
            modifier = Modifier.fillMaxWidth().aspectRatio(2f / 3f),
            scale = CardDefaults.scale(focusedScale = CARD_FOCUS_SCALE), shape = CardDefaults.shape(cardShape),
            border = cardBorder(), glow = cardGlow(),
            colors = CardDefaults.colors(containerColor = TunerColors.surface)) {
            Artwork(imageURL, title, Modifier.fillMaxSize(), titleLines = 4)
        }
        CardCaption(title, subtitle, focused)
    }
}

/** A 16:9 card (Continue Watching, channels, episodes) with an optional progress bar and badge. */
@Composable
fun WideCard(
    title: String, subtitle: String?, imageURL: String?, progress: Double? = null, width: Int = CardSize.WIDE,
    fitImage: Boolean = false, badge: String? = null, onLongClick: (() -> Unit)? = null, onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Column(Modifier.width(width.dp)) {
        Card(onClick = onClick, onLongClick = onLongClick, interactionSource = interaction,
            modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f),
            scale = CardDefaults.scale(focusedScale = CARD_FOCUS_SCALE), shape = CardDefaults.shape(cardShape),
            border = cardBorder(), glow = cardGlow(),
            colors = CardDefaults.colors(containerColor = TunerColors.surface)) {
            Box(Modifier.fillMaxSize()) {
                Artwork(imageURL, title, Modifier.fillMaxSize(), fit = fitImage)
                if (badge != null) Text(badge, style = Eyebrow, color = Color.White,
                    modifier = Modifier.align(Alignment.TopStart).padding(8.dp)
                        .background(if (badge == "LIVE") TunerColors.live else Color.Black.copy(alpha = 0.6f), RoundedCornerShape(5.dp))
                        .padding(horizontal = 7.dp, vertical = 3.dp))
                if (progress != null) ProgressLine(progress, Modifier.align(Alignment.BottomStart).padding(10.dp))
            }
        }
        CardCaption(title, subtitle, focused)
    }
}

/** A thin rounded progress bar: a white fill on a translucent track (the Apple TV app's, over artwork). */
@Composable
fun ProgressLine(fraction: Double, modifier: Modifier = Modifier, color: Color = Color.White) {
    Box(modifier.fillMaxWidth().height(4.dp).background(Color.White.copy(alpha = 0.28f), RoundedCornerShape(2.dp))) {
        Box(Modifier.fillMaxWidth(fraction.toFloat().coerceIn(0f, 1f)).height(4.dp).background(color, RoundedCornerShape(2.dp)))
    }
}

/**
 * The Apple TV app's capsule button: translucent while unfocused, white with dark text and a slight lift when focused.
 * Every button looks the same until focused, so the white one is always the one OK will press.
 */
@Composable
fun PillButton(
    text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, selected: Boolean = false,
    onLongClick: (() -> Unit)? = null,
) {
    // A selected option (a season, a category, a playlist type) keeps a brighter fill and a tick while unfocused.
    val shownIcon = icon ?: if (selected) Icons.Filled.Check else null
    Button(
        onClick = onClick, onLongClick = onLongClick, modifier = modifier.height(44.dp),
        shape = ButtonDefaults.shape(CircleShape),
        colors = ButtonDefaults.colors(containerColor = if (selected) Color.White.copy(alpha = 0.3f) else TunerColors.glass, contentColor = Color.White,
            focusedContainerColor = Color.White, focusedContentColor = TunerColors.onFocus,
            pressedContainerColor = Color.White.copy(alpha = 0.8f), pressedContentColor = TunerColors.onFocus),
        scale = ButtonDefaults.scale(focusedScale = 1.06f),
        glow = ButtonDefaults.glow(focusedGlow = Glow(Color.Black.copy(alpha = 0.6f), 12.dp)),
        contentPadding = PaddingValues(start = if (shownIcon != null) 18.dp else 24.dp, end = 24.dp),
    ) {
        if (shownIcon != null) {
            Icon(shownIcon, null, Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, style = MaterialTheme.typography.titleSmall, maxLines = 1)
    }
}

/** A round glass button with an icon (favourite, more): white when focused. */
@Composable
fun RoundButton(icon: ImageVector, contentDescription: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Color? = null) {
    IconButton(
        onClick = onClick, modifier = modifier.size(44.dp),
        colors = IconButtonDefaults.colors(containerColor = TunerColors.glass, contentColor = tint ?: Color.White,
            focusedContainerColor = Color.White, focusedContentColor = tint ?: TunerColors.onFocus),
        scale = IconButtonDefaults.scale(focusedScale = 1.08f),
    ) {
        Icon(icon, contentDescription, Modifier.size(22.dp))
    }
}

/** A row's title, with an optional quieter note after it ("Favorites", "3 episodes"). */
@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier, note: String? = null) {
    Row(modifier, verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        if (note != null) Text(note, style = MaterialTheme.typography.bodySmall, color = TunerColors.tertiary, modifier = Modifier.padding(bottom = 2.dp))
    }
}

/** A titled horizontal row (Home shelves, search results). */
@Composable
fun <T> Shelf(title: String, items: List<T>, key: (T) -> String, focusFirst: Boolean = false, note: String? = null, content: @Composable (T) -> Unit) {
    if (items.isEmpty()) return
    // The first card takes focus once, when the page first shows it. Keyed on the first item, it took focus again
    // whenever the row changed (Continue Watching reorders after anything is watched, and Home reloads on every
    // database change) or the card scrolled back into view: coming back from a title or the player always landed on
    // the first Continue Watching card.
    var tookFocus by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    Column(Modifier.padding(bottom = 22.dp)) {
        SectionHeader(title, note = note)
        // Vertical room so a focused (grown) card and its glow never reach the row title above.
        LazyRow(Modifier.bleedStart(), horizontalArrangement = Arrangement.spacedBy(22.dp),
            contentPadding = PaddingValues(start = FocusBleed, end = 48.dp, top = 14.dp, bottom = 6.dp)) {
            items(items.size, key = { key(items[it]) }) { i ->
                Box(Modifier.rememberedFocus(key(items[i])).then(if (focusFirst && i == 0 && !tookFocus) Modifier.initialFocus().onFocusChanged { if (it.hasFocus) tookFocus = true } else Modifier)) { content(items[i]) }
            }
        }
    }
}

/** A page's title: small, like the Apple TV app's, so the content gets the screen. */
@Composable
fun PageTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.headlineSmall, modifier = modifier.padding(bottom = 8.dp))
}

@Composable
fun Placeholder(text: String, detail: String? = null) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text, style = MaterialTheme.typography.titleMedium, color = TunerColors.secondary)
            if (detail != null) {
                Spacer(Modifier.height(6.dp))
                Text(detail, style = MaterialTheme.typography.bodyMedium, color = TunerColors.tertiary)
            }
        }
    }
}
