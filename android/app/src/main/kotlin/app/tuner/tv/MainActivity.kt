package app.tuner.tv

import android.content.Intent
import android.os.Bundle
import app.tuner.tv.integration.WatchNext
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import app.tuner.tv.ui.AppShell
import app.tuner.tv.ui.TunerTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Playlists older than their refresh interval update shortly after launch (Swift: AppModel's refresh loop).
        app.scope.launch {
            kotlinx.coroutines.delay(3000)
            runCatching { app.sync.refreshStale(app.prefs.liveRefreshHours, app.prefs.vodRefreshHours) }
            WatchNext.sync(app)
        }
        handle(intent)
        setContent {
            TunerTheme {
                AppShell()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** A Continue watching entry on Google TV's home screen opens the player at its resume point. */
    private fun handle(intent: Intent?) {
        intent?.data?.takeIf { it.scheme == "antenna" }?.let { app.playRequests.value = it }
    }
}
