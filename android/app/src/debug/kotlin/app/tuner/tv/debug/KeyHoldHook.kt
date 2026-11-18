package app.tuner.tv.debug

import android.os.Handler
import android.os.Looper
import android.view.View
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.SystemClock
import android.view.KeyEvent
import kotlin.concurrent.thread

/**
 * Debug builds only. `adb shell am broadcast -a app.tuner.tv.debug.HOLD -p app.antenna.player.debug --ei ms 2000`
 * holds OK the way a remote does: a press, the system's auto-repeats (after 400 ms, every 50 ms), then the release.
 * `adb shell input keyevent` can't (it sends at most one repeat), so long-press behaviour couldn't be tested from adb.
 */
class KeyHoldHook : ContentProvider() {
    override fun onCreate(): Boolean {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                // Only D-pad and OK keys, held for at most 10 s.
                val ms = intent.getIntExtra("ms", 2000).coerceIn(0, 10_000)
                val code = intent.getIntExtra("key", KeyEvent.KEYCODE_DPAD_CENTER).takeIf { it in ALLOWED_KEYS } ?: return
                thread(name = "key-hold") {
                    val down = SystemClock.uptimeMillis()
                    send(KeyEvent(down, down, KeyEvent.ACTION_DOWN, code, 0))
                    Thread.sleep(400)
                    var repeat = 1
                    while (SystemClock.uptimeMillis() - down < ms) {
                        val flags = if (repeat == 1) KeyEvent.FLAG_LONG_PRESS else 0
                        send(KeyEvent(down, SystemClock.uptimeMillis(), KeyEvent.ACTION_DOWN, code, repeat++, 0, 0, 0, flags))
                        Thread.sleep(50)
                    }
                    send(KeyEvent(down, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0))
                }
            }
        }
        // Only senders holding DUMP may trigger it: adb's shell has it, ordinary apps can't get it, so another app on the
        // device can't drive a debug build through this hook.
        context!!.registerReceiver(receiver, IntentFilter("app.tuner.tv.debug.HOLD"), android.Manifest.permission.DUMP, null, Context.RECEIVER_EXPORTED)
        return true
    }

    /** Hands the event to whichever of the app's windows has focus (the page, or a dialog once one opens), as the
     * system does with a real key. Injection through the system needs INJECT_EVENTS, which an app can't hold. */
    private fun send(event: KeyEvent) {
        val main = Handler(Looper.getMainLooper())
        val done = java.util.concurrent.CountDownLatch(1)
        main.post {
            runCatching {
                val global = Class.forName("android.view.WindowManagerGlobal")
                val instance = global.getMethod("getInstance").invoke(null)
                @Suppress("UNCHECKED_CAST")
                val views = global.getDeclaredField("mViews").apply { isAccessible = true }.get(instance) as List<View>
                views.lastOrNull { it.hasWindowFocus() }?.dispatchKeyEvent(event)
            }
            done.countDown()
        }
        done.await()
    }

    private companion object {
        val ALLOWED_KEYS = setOf(KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_DPAD_UP,
            KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT)
    }

    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?) = null
    override fun getType(uri: Uri) = null
    override fun insert(uri: Uri, values: ContentValues?) = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, s: String?, a: Array<out String>?) = 0
}
