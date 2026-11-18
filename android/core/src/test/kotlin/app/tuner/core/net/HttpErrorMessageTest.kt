package app.tuner.core.net

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class HttpErrorMessageTest {
    @Test fun networkErrorsDontNameTheServer() {
        val cases = listOf(
            java.net.ConnectException("Failed to connect to /203.0.113.5:8080"),
            java.net.UnknownHostException("Unable to resolve host \"panel.example\": No address associated with hostname"),
            java.net.SocketTimeoutException("timeout"),
            javax.net.ssl.SSLHandshakeException("Chain validation failed for panel.example"),
        )
        for (e in cases) {
            val text = HttpClient.describe(e)
            assertFalse("203.0.113.5" in text || "panel.example" in text, text)
        }
        assertEquals("Couldn't connect to the server.", HttpClient.describe(cases[0]))
        assertEquals("Couldn't find the server. Check the address.", HttpClient.describe(cases[1]))
    }

    @Test fun ourOwnMessagesStay() {
        assertEquals("Not found (404)", HttpClient.describe(HttpException.Status(404)))
        assertEquals("Wrong username or password", HttpClient.describe(HttpException.AuthFailed("Wrong username or password")))
    }

    @Test fun otherMessagesWithAddressesAreHidden() {
        assertEquals("Couldn't load", HttpClient.describe(IllegalStateException("bad http://x/y"), "Couldn't load"))
        assertEquals("Playlist is empty", HttpClient.describe(IllegalStateException("Playlist is empty")))
    }
}
