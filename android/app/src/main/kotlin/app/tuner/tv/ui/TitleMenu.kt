package app.tuner.tv.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import app.tuner.tv.app
import kotlinx.coroutines.launch

/** A movie or show a poster stands for, for its long-press menu. */
data class TitleRef(val id: String, val title: String, val isSeries: Boolean)

/**
 * Long-press on a movie or show poster: go to its page, or add it to (or remove it from) Favorites. The change runs in
 * the app's scope, since the menu (and the composition that opened it) closes as soon as an action is picked.
 */
@Composable
fun TitleMenu(ref: TitleRef, onOpen: (TitleRef) -> Unit, onDismiss: () -> Unit) {
    val app = LocalContext.current.app
    var favorite by remember(ref.id) { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(ref.id) { favorite = app.library.isVodFavorite(ref.id) }
    val isFavorite = favorite ?: return
    ItemMenu(ref.title, listOf(
        MenuAction(if (ref.isSeries) "Go to Show" else "Go to Movie") { onOpen(ref) },
        MenuAction(if (isFavorite) "Remove from Favorites" else "Add to Favorites") {
            app.scope.launch { app.library.setVodFavorite(ref.id, ref.isSeries, !isFavorite) }
        },
    ), onDismiss)
}
