package app.tuner.tv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import coil3.compose.AsyncImage

/** A 2:3 poster card with the title under it; the title shows inside the card when there's no artwork. */
@Composable
fun PosterCard(title: String, imageURL: String?, subtitle: String? = null, width: Int = 150, onClick: () -> Unit) {
    Column(Modifier.width(width.dp)) {
        Card(onClick = onClick, modifier = Modifier.fillMaxWidth().aspectRatio(2f / 3f),
            scale = CardDefaults.scale(focusedScale = 1.05f), shape = CardDefaults.shape(RoundedCornerShape(10.dp))) {
            Box(Modifier.fillMaxSize().background(TunerColors.surface), contentAlignment = Alignment.Center) {
                Text(title, Modifier.padding(10.dp), maxLines = 4, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                if (imageURL != null) AsyncImage(imageURL, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
        }
        Spacer(Modifier.height(12.dp))
        Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
        if (subtitle != null) Text(subtitle, maxLines = 1, color = Color.White.copy(alpha = 0.6f), style = MaterialTheme.typography.bodySmall)
    }
}

/** A 16:9 card (Continue Watching, channels) with an optional progress bar. */
@Composable
fun WideCard(title: String, subtitle: String?, imageURL: String?, progress: Double? = null, width: Int = 260, onClick: () -> Unit) {
    Column(Modifier.width(width.dp)) {
        Card(onClick = onClick, modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f),
            scale = CardDefaults.scale(focusedScale = 1.05f), shape = CardDefaults.shape(RoundedCornerShape(10.dp))) {
            Box(Modifier.fillMaxSize().background(TunerColors.surface), contentAlignment = Alignment.Center) {
                Text(title, Modifier.padding(10.dp), maxLines = 3, overflow = TextOverflow.Ellipsis)
                if (imageURL != null) AsyncImage(imageURL, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                if (progress != null) {
                    Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color.White.copy(alpha = 0.25f)))
                    Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(progress.toFloat().coerceIn(0f, 1f)).height(4.dp).background(TunerColors.accent))
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
        if (subtitle != null) Text(subtitle, maxLines = 1, color = Color.White.copy(alpha = 0.6f), style = MaterialTheme.typography.bodySmall)
    }
}

/** A titled horizontal row (Home shelves). */
@Composable
fun <T> Shelf(title: String, items: List<T>, key: (T) -> String, focusFirst: Boolean = false, content: @Composable (T) -> Unit) {
    if (items.isEmpty()) return
    Column(Modifier.padding(bottom = 28.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(bottom = 4.dp))
        // Vertical room so a focused (grown) card never reaches the row title above.
        LazyRow(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(20.dp),
            contentPadding = PaddingValues(start = 6.dp, end = 48.dp, top = 12.dp, bottom = 6.dp)) {
            items(items.size, key = { key(items[it]) }) { i ->
                Box(if (focusFirst && i == 0) Modifier.initialFocus(key(items[0])) else Modifier) { content(items[i]) }
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
fun Placeholder(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, style = MaterialTheme.typography.titleMedium, color = Color.White.copy(alpha = 0.7f))
    }
}
