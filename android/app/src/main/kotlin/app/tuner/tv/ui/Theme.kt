package app.tuner.tv.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme

/** Dark only (Appendix D → Global rules). Accent: the `accent` preference, cyan by default. */
object TunerColors {
    val background = Color(0xFF0B0B0D)
    val surface = Color(0xFF1A1A1E)
    val accent = Color(0xFF00D4FF)
    val onBackground = Color.White
}

@Composable
fun TunerTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = TunerColors.accent,
            background = TunerColors.background,
            surface = TunerColors.surface,
            onBackground = TunerColors.onBackground,
            onSurface = TunerColors.onBackground,
        ),
    ) {
        // TV Material's Text reads LocalContentColor; outside a Surface it would default to black.
        CompositionLocalProvider(LocalContentColor provides TunerColors.onBackground, content = content)
    }
}
