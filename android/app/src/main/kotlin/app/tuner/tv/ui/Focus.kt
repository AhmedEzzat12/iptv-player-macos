package app.tuner.tv.ui

import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.focus.FocusDirection

/**
 * Focuses this control when it first appears (and again when `key` changes): every page puts focus on its primary
 * control, never leaving it on the drawer (appendix D → Global rules).
 */
@Composable
fun Modifier.initialFocus(key: Any? = Unit, enabled: Boolean = true): Modifier {
    if (!enabled) return this
    val requester = remember { FocusRequester() }
    // As soon as the control is laid out: waiting longer left focus with nothing on the page, so it landed on the
    // drawer, which opened and closed again (a flash of the sidebar on every new page).
    LaunchedEffect(key) { requester.focusWhenReady() }
    return focusRequester(requester)
}

/**
 * Focuses this requester as soon as its control is composed and placed, trying once a frame for up to `frames` frames
 * (a page's controls usually appear on the next frame; a lazy list's items can take a few). The one place the app
 * waits for focus targets: no fixed delays, which were too short on a slow TV and needlessly long on a fast one.
 */
suspend fun FocusRequester.focusWhenReady(frames: Int = 10): Boolean {
    repeat(frames) {
        withFrameNanos { }
        if (runCatching { requestFocus(FocusDirection.Enter) }.getOrDefault(false)) return true
    }
    return false
}

/** Room a focused card needs to grow at the start of a row (cards grow 5%; the widest are about 260 dp). */
val FocusBleed: Dp = 12.dp

/**
 * Widens a lazy row or grid by `amount` to the left, into the page's margin. Lazy layouts clip their content, so
 * without this the first card is cut off when it grows on focus, as if it slid under the sidebar. Pair it with
 * `contentPadding(start = amount)` so the first card still lines up with the titles above.
 */
fun Modifier.bleedStart(amount: Dp = FocusBleed): Modifier = layout { measurable, constraints ->
    val px = amount.roundToPx()
    val wide = if (constraints.hasBoundedWidth) constraints.copy(maxWidth = constraints.maxWidth + px, minWidth = constraints.minWidth + px) else constraints
    val placeable = measurable.measure(wide)
    layout((placeable.width - px).coerceAtLeast(0), placeable.height) { placeable.place(-px, 0) }
}

/**
 * Scrolls a list only as far as needed to show the focused control. Android TV's default pulls the focused item
 * toward the upper third, which on the movie and show pages scrolled the backdrop and title off the top as soon as
 * the page opened, although Play was already on screen.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
val KeepInView: androidx.compose.foundation.gestures.BringIntoViewSpec = object : androidx.compose.foundation.gestures.BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        val end = offset + size
        return when {
            offset >= 0f && end <= containerSize -> 0f
            offset < 0f || size > containerSize -> offset
            else -> end - containerSize
        }
    }
}

/**
 * Which card had focus, so Back from a page (or the player) lands on the card that opened it. Cards in rows and grids
 * record their key when focused and stay registered while composed (`rememberedFocus`); AppShell calls `restore` when
 * a page or the player closes.
 */
class FocusMemory {
    var lastKey: String? = null
    // Only read when restoring, never drawn: a plain map, not snapshot state.
    private val targets = HashMap<String, FocusRequester>()

    internal fun register(key: String, requester: FocusRequester) { targets[key] = requester }
    internal fun unregister(key: String, requester: FocusRequester) { if (targets[key] === requester) targets.remove(key) }

    /**
     * Gives focus back to the card recorded under `key` once it's composed again (a lazy row may need a few frames),
     * else to `fallback` (the page, whose restorer picks its own first control). Returns whether either took it.
     */
    suspend fun restore(key: String?, fallback: FocusRequester?, frames: Int = 8): Boolean {
        if (key != null) repeat(frames) {
            withFrameNanos { }
            val target = targets[key]
            if (target != null && runCatching { target.requestFocus(FocusDirection.Enter) }.getOrDefault(false)) return true
        }
        return fallback?.focusWhenReady() ?: false
    }
}

val LocalFocusMemory = androidx.compose.runtime.staticCompositionLocalOf { FocusMemory() }

/**
 * Records this card as focused under `key` (unique on the page: rows prefix their own name, as the same title can sit
 * in several Home rows), and registers it so `FocusMemory.restore` can focus it directly.
 */
@Composable
fun Modifier.rememberedFocus(key: String): Modifier {
    val memory = LocalFocusMemory.current
    val requester = remember { FocusRequester() }
    androidx.compose.runtime.DisposableEffect(key) {
        memory.register(key, requester)
        onDispose { memory.unregister(key, requester) }
    }
    return focusRequester(requester).onFocusChanged { if (it.hasFocus) memory.lastKey = key }
}
