package app.tuner.tv.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/**
 * Focuses this control when it first appears (and again when `key` changes): every page puts focus on its primary
 * control, never leaving it on the drawer (appendix D → Global rules).
 */
@Composable
fun Modifier.initialFocus(key: Any? = Unit, enabled: Boolean = true): Modifier {
    if (!enabled) return this
    val requester = remember { FocusRequester() }
    LaunchedEffect(key) {
        delay(120)
        runCatching { requester.requestFocus() }
    }
    return focusRequester(requester)
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
