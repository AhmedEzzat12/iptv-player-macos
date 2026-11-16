package app.tuner.tv.ui

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tv
import androidx.compose.ui.graphics.vector.ImageVector
import app.tuner.tv.R

/** Drawer items, in order (Appendix D → Navigation shell). Settings sits apart at the bottom. */
enum class Section(@StringRes val title: Int, val icon: ImageVector) {
    Search(R.string.nav_search, Icons.Filled.Search),
    Home(R.string.nav_home, Icons.Filled.Home),
    Live(R.string.nav_live, Icons.Filled.LiveTv),
    Movies(R.string.nav_movies, Icons.Filled.Movie),
    Shows(R.string.nav_shows, Icons.Filled.Tv),
    Favorites(R.string.nav_favorites, Icons.Filled.Favorite),
    Settings(R.string.nav_settings, Icons.Filled.Settings);

    companion object {
        /** Selected on launch (resume-last-channel arrives with live TV in phase 5). */
        val launch = Home
    }
}
