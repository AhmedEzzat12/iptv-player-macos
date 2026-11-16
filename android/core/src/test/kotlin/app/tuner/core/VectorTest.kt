package app.tuner.core

import app.tuner.core.models.CatchupType
import app.tuner.core.models.EndOfMediaStall
import app.tuner.core.parsing.CatchupURLBuilder
import app.tuner.core.parsing.ChannelNameNormalizer
import app.tuner.core.parsing.M3UParser
import app.tuner.core.parsing.TitleParser
import app.tuner.core.parsing.XMLTVDate
import app.tuner.core.parsing.XMLTVParser
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
import kotlinx.serialization.json.JsonArray
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
        "M3UParser.parse" to { input ->
            val o = input.jsonObject
            val bytes = o.string("fixture")?.let { app.tuner.core.Fixtures.bytes(it) } ?: o.string("text")!!.toByteArray()
            val p = M3UParser.parse(bytes, o.string("sourceId") ?: "src")
            fun cats(list: List<app.tuner.core.models.Category>) = JsonArray(list.map { obj("id" to it.id, "name" to it.name) })
            obj(
                "epgURLs" to JsonArray(p.epgURLs.map { JsonPrimitive(it) }),
                "categories" to cats(p.categories),
                "channels" to JsonArray(p.channels.map { c ->
                    obj("id" to c.id, "name" to c.name, "categoryId" to c.categoryId, "tvgId" to c.tvgId, "number" to c.number,
                        "logoURL" to c.logoURL, "streamURL" to c.streamURL, "providerStreamId" to c.providerStreamId,
                        "catchupType" to c.catchupType?.raw, "catchupSource" to c.catchupSource, "catchupDays" to c.catchupDays,
                        "userAgent" to c.userAgent, "referrer" to c.referrer, "isAdult" to c.isAdult)
                }),
                "movieCategories" to cats(p.movieCategories),
                "movies" to JsonArray(p.movies.map { m ->
                    obj("id" to m.id, "name" to m.name, "year" to m.year, "categoryId" to m.categoryId,
                        "containerExtension" to m.containerExtension, "posterURL" to m.posterURL)
                }),
                "seriesCategories" to cats(p.seriesCategories),
                "series" to JsonArray(p.series.map { obj("id" to it.id, "name" to it.name, "categoryId" to it.categoryId) }),
                "episodes" to JsonArray(p.episodes.map { e ->
                    obj("id" to e.id, "seriesId" to e.seriesId, "season" to e.season, "number" to e.number, "title" to e.title,
                        "containerExtension" to e.containerExtension)
                }),
            )
        },
        "TitleParser.splitYear" to { input ->
            val (title, year) = TitleParser.splitYear(input.str())
            obj("title" to title, "year" to year)
        },
        "TitleParser.episodeInfo" to { input ->
            val r = TitleParser.episodeInfo(input.str())
            if (r == null) obj("found" to false)
            else obj("found" to true, "show" to r.show, "season" to r.season, "episode" to r.episode, "title" to r.title)
        },
        "XMLTVDate.parse" to { input ->
            val d = XMLTVDate.parse(input.str())
            if (d == null) obj("valid" to false) else obj("valid" to true, "epoch" to d.epochSecond)
        },
        "XMLTVDate.formatXMLTVNS" to { input -> obj("result" to XMLTVDate.formatXMLTVNS(input.str())) },
        "XMLTVParser.parse" to { input ->
            val events = mutableListOf<JsonElement>()
            XMLTVParser.parse(input.str().toByteArray()) { e ->
                events += when (e) {
                    is XMLTVParser.Event.Channel -> obj("channel" to e.channel.id,
                        "displayNames" to JsonArray(e.channel.displayNames.map { JsonPrimitive(it) }), "icon" to e.channel.iconURL)
                    is XMLTVParser.Event.Programme -> with(e.programme) {
                        obj("programme" to channel, "start" to start.epochSecond, "stop" to stop.epochSecond, "title" to title,
                            "subtitle" to subtitle, "desc" to desc, "category" to category, "icon" to iconURL, "episode" to episode)
                    }
                }
            }
            JsonArray(events)
        },
        "JSONObject.accessors" to { input ->
            val o = app.tuner.core.net.LenientObject(input.jsonObject)
            obj("string" to o.string("v"), "int" to o.int("v"), "double" to o.double("v"), "bool" to o.bool("v"))
        },
        "LenientJSON.objects" to { input ->
            JsonArray(app.tuner.core.net.LenientJson.objects(input).map { JsonPrimitive(it.string("id") ?: "?") })
        },
        "CategoryClassifier.classify" to { input ->
            val f = app.tuner.core.models.CategoryClassifier.classify(input.str())
            obj("group" to f.group.raw, "latinName" to f.latinName, "arabicName" to f.arabicName, "yearLabel" to f.yearLabel,
                "latestYear" to f.latestYear, "automatic" to f.displayName(app.tuner.core.models.CategoryNameStyle.AUTOMATIC),
                "arabic" to f.displayName(app.tuner.core.models.CategoryNameStyle.ARABIC))
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

    /** A JSON object from Kotlin values (null → JSON null). */
    private fun obj(vararg pairs: Pair<String, Any?>): JsonObject = JsonObject(pairs.associate { (k, v) ->
        k to when (v) {
            null -> JsonNull
            is JsonElement -> v
            is String -> JsonPrimitive(v)
            is Number -> JsonPrimitive(v)
            is Boolean -> JsonPrimitive(v)
            else -> error("unsupported ${v::class}")
        }
    })
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
