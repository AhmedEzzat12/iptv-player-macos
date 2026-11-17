package app.tuner.tv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import app.tuner.tv.ui.AppShell
import app.tuner.tv.ui.TunerTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Playlists older than their refresh interval update shortly after launch (Swift: AppModel's refresh loop).
        app.scope.launch { kotlinx.coroutines.delay(3000); runCatching { app.sync.refreshStale() } }
        setContent {
            TunerTheme {
                AppShell()
            }
        }
    }
}
