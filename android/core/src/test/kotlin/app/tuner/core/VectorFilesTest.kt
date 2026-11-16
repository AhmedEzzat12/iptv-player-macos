package app.tuner.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/** The shared vectors (Tests/Vectors) are reachable from the Kotlin tests; phase 2 runs every case against the port. */
class VectorFilesTest {
    private val folder = File(System.getProperty("tuner.vectors") ?: error("tuner.vectors not set"))

    @Test
    fun vectorFolderHasCaseFiles() {
        val files = folder.walkTopDown().filter { it.extension == "json" }.toList()
        assertTrue(files.isNotEmpty(), "no vector files under ${folder.absolutePath}")
        assertTrue(files.all { it.readText().contains("\"cases\"") }, "a vector file has no cases")
    }
}
