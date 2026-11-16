// Port of Sources/TunerCore/Parsing/Gzip.swift @ 666f598
package app.tuner.core.parsing

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.zip.Inflater
import java.util.zip.ZipException

public sealed class GzipException(message: String) : IOException(message) {
    public class Unreadable : GzipException("Could not read the compressed file")
    public class WriteFailed : GzipException("Could not write the decompressed file")
    public class Corrupt : GzipException("The compressed file is damaged or truncated")
}

/**
 * gzip, including multi-member files (some EPG providers concatenate members). `java.util.zip.GZIPInputStream` only
 * reads past the first member when the underlying stream reports `available() > 0`, so this inflates member by member
 * itself and never truncates a guide silently.
 */
public object Gzip {
    public fun isGzipped(bytes: ByteArray): Boolean = bytes.size >= 2 && bytes[0] == 0x1F.toByte() && bytes[1] == 0x8B.toByte()

    public fun isGzipped(file: File): Boolean = runCatching {
        file.inputStream().use { val head = ByteArray(2); it.read(head) == 2 && isGzipped(head) }
    }.getOrDefault(false)

    /** Streams `input` to `output` without holding the decompressed bytes in memory. */
    public fun decompress(input: File, output: File) {
        val source = try { BufferedInputStream(input.inputStream(), 1 shl 16) } catch (e: IOException) { throw GzipException.Unreadable() }
        source.use { inp ->
            val sink = try { output.outputStream().buffered(1 shl 16) } catch (e: IOException) { throw GzipException.WriteFailed() }
            sink.use { out -> inflateMembers(inp) { buf, len -> try { out.write(buf, 0, len) } catch (e: IOException) { throw GzipException.WriteFailed() } } }
        }
    }

    public fun decompress(bytes: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(bytes.size * 4)
        inflateMembers(bytes.inputStream()) { buf, len -> out.write(buf, 0, len) }
        return out.toByteArray()
    }

    private fun inflateMembers(input: InputStream, emit: (ByteArray, Int) -> Unit) {
        val stream = java.io.PushbackInputStream(input, 1 shl 16)
        val inBuf = ByteArray(1 shl 16)
        val outBuf = ByteArray(1 shl 16)
        var members = 0
        while (true) {
            val first = stream.read()
            if (first == -1) {
                if (members == 0) throw GzipException.Corrupt()
                return
            }
            stream.unread(first)
            try {
                readHeader(stream)
            } catch (e: IOException) {
                if (members > 0) return // trailing garbage after a complete member, as zlib's gzread tolerates
                throw GzipException.Corrupt()
            }
            val inflater = Inflater(true)
            try {
                var lastRead = 0
                while (!inflater.finished()) {
                    if (inflater.needsInput()) {
                        lastRead = stream.read(inBuf)
                        if (lastRead <= 0) throw GzipException.Corrupt()
                        inflater.setInput(inBuf, 0, lastRead)
                    }
                    val produced = try { inflater.inflate(outBuf) } catch (e: java.util.zip.DataFormatException) { throw GzipException.Corrupt() }
                    if (produced > 0) emit(outBuf, produced)
                    if (produced == 0 && inflater.needsDictionary()) throw GzipException.Corrupt()
                }
                // Bytes read past this member's deflate data belong to its trailer and the next member.
                val remaining = inflater.remaining
                if (remaining > 0) stream.unread(inBuf, lastRead - remaining, remaining)
            } finally {
                inflater.end()
            }
            // 8-byte trailer (CRC32 + size).
            for (k in 0 until 8) if (stream.read() == -1) throw GzipException.Corrupt()
            members++
        }
    }

    private fun readHeader(s: java.io.PushbackInputStream) {
        fun byte(): Int = s.read().also { if (it == -1) throw EOFException() }
        if (byte() != 0x1F || byte() != 0x8B) throw ZipException("not gzip")
        if (byte() != 8) throw ZipException("unknown method")
        val flags = byte()
        repeat(6) { byte() } // mtime, xfl, os
        if (flags and 0x04 != 0) { val len = byte() or (byte() shl 8); repeat(len) { byte() } }
        if (flags and 0x08 != 0) while (byte() != 0) continue
        if (flags and 0x10 != 0) while (byte() != 0) continue
        if (flags and 0x02 != 0) { byte(); byte() }
    }
}
