package app.tuner.core

import app.tuner.core.models.CatchupType
import app.tuner.core.models.EndOfMediaStall
import app.tuner.core.parsing.CatchupURLBuilder
import app.tuner.core.parsing.ChannelNameNormalizer
import app.tuner.core.parsing.StableID
import app.tuner.core.providers.XtreamURLs
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.TestFactory
import java.io.File
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Runs every case in Tests/Vectors (shared with the Swift tests, expected values generated from Swift) against the
 * Kotlin port. A case may carry `androidExpected` for a deliberate difference listed in docs/android-parity.md.
 */
class VectorTest {
    private val folder = File(System.getProperty("tuner.vectors") ?: error("tuner.vectors not set"))

    private val functions: Map<String, (JsonElement) -> JsonElement> = mapOf(
        "StableID.hash" to { JsonPrimitive(StableID.hash(it.str())) },
        "StableID.sanitize" to { JsonPrimitive(StableID.sanitize(it.str())) },
        "StableID.slug" to { JsonPrimitive(StableID.slug(it.str())) },
        "ChannelNameNormalizer.normalize" to { JsonPrimitive(ChannelNameNormalizer.normalize(it.str())) },
        "EndOfMediaStall.hasEnded" to { input ->
            val o = input.jsonObject
            JsonPrimitive(EndOfMediaStall.hasEnded(o.double("position"), o.double("duration"), o.double("stalledFor") ?: 0.0))
        },
        "CatchupURLBuilder.m3u" to { input ->
            val o = input.jsonObject
            JsonPrimitive(
                CatchupURLBuilder.m3u(
                    channelURL = o.string("channelURL")!!,
                    type = CatchupType.of(o.string("type")!!) ?: CatchupType.DEFAULT,
                    template = o.string("template"),
                    tvgId = o.string("tvgId"),
                    start = Instant.parse(o.string("start")),
                    end = Instant.parse(o.string("end")),
                    now = Instant.parse(o.string("now")),
                ),
            )
        },
        "XtreamClient.urls" to { input ->
            val o = input.jsonObject
            val x = XtreamURLs(o.string("base")!!, o.string("username")!!, o.string("password")!!)
            val id = o.string("streamId")!!
            val ext = o.string("ext")
            buildJsonObject {
                put("live", x.liveURL(id, XtreamURLs.LiveFormat.TS))
                put("liveM3U8", x.liveURL(id, XtreamURLs.LiveFormat.M3U8))
                put("movie", x.movieURL(id, ext))
                put("episode", x.episodeURL(id, ext))
                put("timeshift", x.timeshiftURL(id, Instant.parse(o.string("start")), o["minutes"]!!.jsonPrimitive.intOrNull ?: 0,
                    o.double("serverTimeOffset") ?: 0.0))
                put("api", x.apiURL("get_live_streams"))
            }
        },
    )

    @TestFactory
    fun vectors(): List<DynamicTest> {
        val files = folder.walkTopDown().filter { it.extension == "json" }.sortedBy { it.path }.toList()
        assertTrue(files.isNotEmpty(), "no vector files under ${folder.absolutePath}")
        return files.flatMap { file ->
            val root = Json.parseToJsonElement(file.readText()).jsonObject
            val function = root.string("function")!!
            val run = functions[function]
            root["cases"]!!.jsonArray.map { case ->
                val o = case.jsonObject
                val name = "${file.parentFile.name}/${file.name} / ${o.string("name")}"
                DynamicTest.dynamicTest(name) {
                    if (run == null) fail("no Kotlin function registered for $function")
                    val expected = o["androidExpected"] ?: o["expected"]
                    if (expected == null || expected is JsonNull) fail("expected is null: regenerate the vectors in Swift")
                    assertEquals(expected.normalized(), run(o["input"] ?: JsonNull).normalized(), name)
                }
            }
        }
    }

    private fun JsonElement.str(): String = jsonPrimitive.content
    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull
    private fun JsonObject.double(key: String): Double? = (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.doubleOrNull

    /** Numbers compare by value (1 == 1.0), booleans and strings by content. */
    private fun JsonElement.normalized(): Any? = when (this) {
        is JsonNull -> null
        is JsonPrimitive -> if (isString) content else booleanOrNull ?: doubleOrNull ?: content
        is JsonObject -> mapValues { it.value.normalized() }
        else -> jsonArray.map { it.normalized() }
    }
}
