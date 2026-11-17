package app.tuner.tv.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
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
