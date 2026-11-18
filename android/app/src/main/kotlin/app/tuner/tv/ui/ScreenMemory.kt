package app.tuner.tv.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.LocalContext
import app.tuner.tv.app
import java.util.concurrent.ConcurrentHashMap

/**
 * What each screen last showed, for the life of the app. A section is rebuilt each time it's chosen, and its state
 * started empty: Home drew a blank page (and Live TV and the grids empty lists) until its queries came back. Seeded
 * from here, a screen draws its last content on the first frame and refreshes it quietly (the library's own cache
 * makes that refresh quick, and it replaces only what changed).
 */
class ScreenMemory {
    private val values = ConcurrentHashMap<String, Any>()

    @Suppress("UNCHECKED_CAST")
    operator fun <T : Any> get(key: String): T? = values[key] as T?

    operator fun set(key: String, value: Any) { values[key] = value }

    @Suppress("UNCHECKED_CAST")
    fun <T : Any> getOrPut(key: String, make: () -> T): T = values.getOrPut(key, make) as T
}

/** A screen's state that starts from what it last showed (`ScreenMemory`) and is remembered there as it changes. */
@Composable
fun <T : Any> rememberScreenState(key: String, initial: () -> T): MutableState<T> {
    val memory = LocalContext.current.app.screens
    val state = remember(key) { mutableStateOf<T>(memory.get<T>(key) ?: initial()) }
    LaunchedEffect(key) { snapshotFlow { state.value }.collect { memory[key] = it } }
    return state
}
