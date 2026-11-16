package app.tuner.core

import java.io.File

/** The Swift tests' fixtures (Tests/TunerCoreTests/Fixtures), read in place. */
object Fixtures {
    private val folder = File(System.getProperty("tuner.fixtures") ?: error("tuner.fixtures not set"))

    fun file(name: String): File = File(folder, name).also { require(it.exists()) { "missing fixture $name" } }

    fun bytes(name: String): ByteArray = file(name).readBytes()
}
