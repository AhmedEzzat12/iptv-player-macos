package app.tuner.tv.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Typography
import androidx.tv.material3.darkColorScheme

/**
 * Dark only (Appendix D → Global rules), styled after the Apple TV app: near-black pages, translucent "glass" controls
 * that turn white when focused, and white as the focus colour everywhere. The accent (cyan by default) marks state
 * (progress, LIVE, favourites), never focus.
 */
object TunerColors {
    val background = Color(0xFF0B0B0D)
    val surface = Color(0xFF1C1C1F)
    /** Cards and panels lifted off the page (dialogs, the open sidebar). */
    val raised = Color(0xFF26262A)
    /** Unfocused controls on top of artwork or the page. */
    val glass = Color.White.copy(alpha = 0.14f)
    val glassStrong = Color.White.copy(alpha = 0.22f)
    val accent = Color(0xFF00D4FF)
    val live = Color(0xFFE5383B)
    val onBackground = Color.White
    val secondary = Color.White.copy(alpha = 0.64f)
    val tertiary = Color.White.copy(alpha = 0.42f)
    /** Text on a focused (white) control. */
    val onFocus = Color(0xFF111114)
}

/**
 * Every role TV Material reads is set: left to the defaults, focused list rows and chips showed Material's lilac and
 * pink tints, which matched nothing else in the app.
 */
private val colors = darkColorScheme(
    primary = Color.White,
    onPrimary = TunerColors.onFocus,
    primaryContainer = TunerColors.glassStrong,
    onPrimaryContainer = Color.White,
    secondary = Color.White,
    onSecondary = TunerColors.onFocus,
    secondaryContainer = TunerColors.glassStrong,
    onSecondaryContainer = Color.White,
    tertiary = TunerColors.accent,
    onTertiary = TunerColors.onFocus,
    background = TunerColors.background,
    onBackground = Color.White,
    surface = TunerColors.surface,
    onSurface = Color.White,
    surfaceVariant = TunerColors.raised,
    onSurfaceVariant = TunerColors.secondary,
    surfaceTint = Color.Transparent,
    inverseSurface = Color.White,
    inverseOnSurface = TunerColors.onFocus,
    inversePrimary = TunerColors.onFocus,
    error = Color(0xFFFF6B6B),
    onError = TunerColors.onFocus,
    errorContainer = Color(0xFF5C1A1A),
    onErrorContainer = Color.White,
    border = Color.White.copy(alpha = 0.3f),
    borderVariant = Color.White.copy(alpha = 0.16f),
    scrim = Color.Black.copy(alpha = 0.7f),
)

/**
 * Sizes for 10-foot viewing on TV's 960×540 dp canvas (roughly tvOS's point sizes halved), heavier than Material's
 * defaults: the Apple TV app sets titles bold and keeps body text regular.
 */
private val typography = Typography().run {
    copy(
        displayLarge = displayLarge.copy(fontWeight = FontWeight.Bold),
        displayMedium = displayMedium.copy(fontWeight = FontWeight.Bold),
        displaySmall = displaySmall.copy(fontSize = 40.sp, lineHeight = 46.sp, fontWeight = FontWeight.Bold),
        headlineLarge = headlineLarge.copy(fontWeight = FontWeight.Bold),
        headlineMedium = headlineMedium.copy(fontWeight = FontWeight.Bold),
        headlineSmall = headlineSmall.copy(fontSize = 26.sp, lineHeight = 32.sp, fontWeight = FontWeight.Bold),
        titleLarge = titleLarge.copy(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold),
        titleMedium = titleMedium.copy(fontSize = 18.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold),
        titleSmall = titleSmall.copy(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold),
        bodyLarge = bodyLarge.copy(fontSize = 17.sp, lineHeight = 24.sp),
        bodyMedium = bodyMedium.copy(fontSize = 15.sp, lineHeight = 21.sp),
        bodySmall = bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp),
        labelLarge = labelLarge.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
        labelMedium = labelMedium.copy(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
    )
}

/** The small capitals over a title ("MOVIE", "SEASON 2, EPISODE 4"), as on the Apple TV app's hero and player. */
val Eyebrow = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.4.sp)

@Composable
fun TunerTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colors, typography = typography) {
        // TV Material's Text reads LocalContentColor; outside a Surface it would default to black.
        CompositionLocalProvider(LocalContentColor provides TunerColors.onBackground, content = content)
    }
}
