// Port of the "XMLTV parser" suite in Tests/TunerCoreTests/ParserTests.swift @ 666f598
package app.tuner.core.parsing

import app.tuner.core.Fixtures
import app.tuner.core.services.GuideParse
import java.io.File
import java.io.FilterInputStream
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class XMLTVParserTest {
    private fun events(bytes: ByteArray): Pair<List<XMLTVChannel>, List<XMLTVProgramme>> {
        val channels = mutableListOf<XMLTVChannel>()
        val programmes = mutableListOf<XMLTVProgramme>()
        XMLTVParser.parse(bytes) { e ->
            when (e) {
                is XMLTVParser.Event.Channel -> channels.add(e.channel)
                is XMLTVParser.Event.Programme -> programmes.add(e.programme)
            }
        }
        return channels to programmes
    }

    @Test fun parsesChannelsAndProgrammes() {
        val (channels, programmes) = events(Fixtures.bytes("sample.xml"))
        assertEquals(listOf("cnn.us", "BBC1.uk", "unused.channel"), channels.map { it.id })
        assertEquals(listOf("CNN", "CNN International"), channels[0].displayNames)
        assertEquals("http://logos/cnn-epg.png", channels[0].iconURL)
        assertEquals(4, programmes.size)
        val first = programmes[0]
        assertEquals("News & Views", first.title) // entity decoded, first title wins
        assertEquals("Midday", first.subtitle)
        assertEquals("Top <stories> of the day", first.desc) // CDATA
        assertEquals("News", first.category)
        assertEquals("S02E05", first.episode)
        assertEquals("http://img/p1.jpg", first.iconURL)
    }

    @Test fun timezoneOffsetsAreApplied() {
        val (_, programmes) = events(Fixtures.bytes("sample.xml"))
        val who = programmes.first { it.title == "Doctor Who" }
        // 14:00 +0200 == 12:00 UTC
        assertEquals(XMLTVDate.parse("20260101120000 +0000"), who.start)
        assertEquals("Time & space ©", who.desc)
    }

    @Test fun dateWithoutSecondsOrOffset() {
        assertEquals(1767272400L, XMLTVDate.parse("202601011300")!!.epochSecond)
        assertEquals(1_767_277_800L, XMLTVDate.parse("20260101130000 -0130")!!.epochSecond)
        assertEquals(null, XMLTVDate.parse("garbage"))
    }

    @Test fun emptyGuideIsStillRecognised() {
        val xml = File.createTempFile("empty", ".xml").apply {
            writeText("""<?xml version="1.0" encoding="utf-8" ?><!DOCTYPE tv SYSTEM "xmltv.dtd"><tv generator-info-name="x"></tv>""")
            deleteOnExit()
        }
        assertTrue(XMLTVParser.looksLikeXMLTV(xml))
        val html = File.createTempFile("page", ".html").apply { writeText("<html><body>Login</body></html>"); deleteOnExit() }
        assertFalse(XMLTVParser.looksLikeXMLTV(html))
    }

    @Test fun gzipRejectsGarbage() {
        assertFailsWith<GzipException> { Gzip.decompress(byteArrayOf(0x1F, 0x8B.toByte(), 0x08, 0x00, 0x01, 0x02)) }
    }

    @Test fun gzipSingleAndMultiMember() {
        val plain = Fixtures.bytes("sample.xml")
        assertContentEquals(plain, Gzip.decompress(Fixtures.bytes("sample.xml.gz")))
        assertContentEquals(plain + plain, Gzip.decompress(Fixtures.bytes("multi.xml.gz")))
    }

    /** The trap from appendix A: a stream reporting available() == 0 (like a network stream) must not truncate. */
    @Test fun gzipMultiMemberFileToFile() {
        val out = File.createTempFile("multi", ".xml").apply { deleteOnExit() }
        Gzip.decompress(Fixtures.file("multi.xml.gz"), out)
        val plain = Fixtures.bytes("sample.xml")
        assertContentEquals(plain + plain, out.readBytes())
        val zeroAvailable = object : FilterInputStream(Fixtures.file("multi.xml.gz").inputStream()) {
            override fun available() = 0
        }
        assertTrue(Gzip.isGzipped(Fixtures.file("multi.xml.gz")))
        assertContentEquals(plain + plain, Gzip.decompress(zeroAvailable.readBytes()))
    }

    @Test fun guideIngestFiltersToWantedChannels() {
        val wanted = GuideParse.Wanted(setOf("cnn.us"), setOf(ChannelNameNormalizer.normalize("BBC One HD")))
        val r = GuideParse.parse(Fixtures.file("sample.xml"), "f", wanted, 0, Instant.MIN, Instant.MAX)
        assertEquals(setOf("f|cnn.us", "f|BBC1.uk"), r.programmes.map { it.epgKey }.toSet())
        assertEquals(2, r.counts["f|cnn.us"])
        assertFalse(r.programmes.any { it.title == "Filtered Out" })
    }

    @Test fun guideIngestAppliesShift() {
        val r = GuideParse.parse(Fixtures.file("sample.xml"), "f", null, 3600, Instant.MIN, Instant.MAX)
        assertEquals(XMLTVDate.parse("20260101130000 +0000"), r.programmes.first().start)
    }

    @Test fun trimOverlapsClampsEndAndDropsDuplicateStart() {
        val t0 = Instant.ofEpochSecond(1_000)
        val t1 = Instant.ofEpochSecond(2_000)
        val t2 = Instant.ofEpochSecond(2_500)
        val t3 = Instant.ofEpochSecond(3_600)
        val list = listOf(
            app.tuner.core.models.Program(epgKey = "f|a", start = t0, end = t2, title = "First"),
            app.tuner.core.models.Program(epgKey = "f|a", start = t0, end = t3, title = "DuplicateStart"),
            app.tuner.core.models.Program(epgKey = "f|a", start = t1, end = t3, title = "Second"),
        )
        val trimmed = GuideParse.trimOverlaps(list)
        assertEquals(2, trimmed.size)
        assertEquals("First", trimmed[0].title)
        assertEquals(t1, trimmed[0].end)
        assertEquals("Second", trimmed[1].title)
        assertEquals(t1, trimmed[1].start)
        assertEquals(t3, trimmed[1].end)
    }
}
