// Port of the String extensions in Sources/TunerCore/Networking/HTTPClient.swift @ 666f598
package app.tuner.core.net

/** Foundation's `urlQueryAllowed` minus `&=+?/#`: what Xtream usernames/passwords keep unescaped in a query. */
private const val QUERY_ALLOWED = "!$'()*,-.:;@_~"

/** Foundation's `urlPathAllowed` minus `/?#`. */
private const val PATH_ALLOWED = "!$&'()*+,-.:;=@_~"

private fun String.percentEncoded(allowedPunctuation: String): String {
    val out = StringBuilder(length)
    for (b in toByteArray(Charsets.UTF_8)) {
        val c = b.toInt() and 0xFF
        val ch = c.toChar()
        if (c < 0x80 && (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch in allowedPunctuation)) {
            out.append(ch)
        } else {
            out.append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 0xF])
        }
    }
    return out.toString()
}

/** Percent-encodes a value for use inside a query string. */
public val String.urlQueryEncoded: String get() = percentEncoded(QUERY_ALLOWED)

/** Percent-encodes a value for use as one path segment. */
public val String.urlPathEncoded: String get() = percentEncoded(PATH_ALLOWED)
