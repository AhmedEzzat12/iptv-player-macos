// Port of the "M3U parser" suite and titleParsing in Tests/TunerCoreTests/ParserTests.swift @ 666f598
package app.tuner.core.parsing

import app.tuner.core.Fixtures
import app.tuner.core.models.CatchupType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class M3UParserTest {
    private val playlist = M3UParser.parse(Fixtures.bytes("sample.m3u"), "src")

    @Test fun headerEPGURLsAreSplit() {
        assertEquals(listOf("http://epg.example.com/guide.xml.gz", "http://epg2.example.com/g.xml"), playlist.epgURLs)
    }

    @Test fun liveChannelsAndAttributes() {
        assertEquals(5, playlist.channels.size)
        val cnn = playlist.channels.first()
        assertEquals("CNN HD", cnn.name)
        assertEquals("cnn.us", cnn.tvgId)
        assertEquals("http://logos/cnn.png", cnn.logoURL)
        assertEquals("src_cnn.us", cnn.id)
        assertEquals("src_news", cnn.categoryId)
        assertEquals(CatchupType.SHIFT, cnn.catchupType)
        assertEquals(5, cnn.catchupDays)
    }

    @Test fun commasInsideQuotesAndTitles() {
        val bbc = playlist.channels.first { it.tvgId == "bbc1.uk" }
        assertEquals("BBC One, London", bbc.name)
        assertEquals(101, bbc.number)
        assertTrue(playlist.categories.any { it.name == "UK, Entertainment" })
    }

    @Test fun vlcOptionsBecomeHeaders() {
        val bbc = playlist.channels.first { it.tvgId == "bbc1.uk" }
        assertEquals("CustomAgent/1.0", bbc.userAgent)
        assertEquals("http://ref.example.com/", bbc.referrer)
        // options don't leak to the next entry
        assertNull(playlist.channels.first { it.name == "CNN Backup" }.userAgent)
    }

    @Test fun duplicateTvgIdGetsHashedId() {
        val backup = playlist.channels.first { it.name == "CNN Backup" }
        assertTrue(backup.id.startsWith("src_cnn.us_"))
        assertNotEquals("src_cnn.us", backup.id)
    }

    @Test fun emptyUnquotedValueDoesNotSwallowNextKey() {
        val ch = playlist.channels.first { it.name == "No Id Channel" }
        assertNull(ch.tvgId)
        assertTrue(ch.id.startsWith("src_url_"))
        assertEquals("udp://239.0.0.1:1234", ch.streamURL)
        assertEquals("src_misc", ch.categoryId) // from #EXTGRP
    }

    @Test fun xtreamPanelLinksAreRecognised() {
        val ch = playlist.channels.first { it.name == "Panel Channel" }
        assertEquals("12345", ch.providerStreamId)
        assertEquals(CatchupType.XTREAM, ch.catchupType)
    }

    @Test fun vodEntriesAreRoutedToLibrary() {
        val movie = playlist.movies.first()
        assertEquals("The Matrix", movie.name)
        assertEquals("1999", movie.year)
        assertEquals("mkv", movie.containerExtension)
        assertEquals(1, playlist.series.size)
        assertEquals("Breaking Bad", playlist.series.first().name)
        assertEquals(2, playlist.episodes.size)
        val ep = playlist.episodes.first { it.number == 2 }
        assertEquals(1, ep.season)
        assertEquals("Cat's in the Bag", ep.title)
    }

    @Test fun idsAreStableAcrossParses() {
        val again = M3UParser.parse(Fixtures.bytes("sample.m3u"), "src")
        assertEquals(playlist.channels.map { it.id }, again.channels.map { it.id })
    }

    @Test fun handlesCRLFAndBOM() {
        val text = "﻿#EXTM3U\r\n#EXTINF:-1,Only\r\nhttp://x/1.ts\r\n"
        val p = M3UParser.parse(text.toByteArray(), "s")
        assertEquals(listOf("Only"), p.channels.map { it.name })
        assertEquals("http://x/1.ts", p.channels.first().streamURL)
    }

    @Test fun titleParsing() {
        assertEquals("Dune Part Two", TitleParser.splitYear("Dune Part Two (2024)").first)
        assertEquals("Blade Runner 2049" to null, TitleParser.splitYear("Blade Runner 2049"))
        assertEquals("Sardar 2" to "2026", TitleParser.splitYear("Sardar 2 ( 2026 )"))
        assertEquals("المهايطية Pure" to "2026", TitleParser.splitYear("المهايطية ( 2026 ) Pure"))
        assertEquals("The Nice Ones" to "2026", TitleParser.splitYear("The Nice Ones [2026]"))
        assertEquals("Heat" to "1995", TitleParser.splitYear("Heat - 1995"))
        val ep = TitleParser.episodeInfo("The Office (US) S03E10 A Benihana Christmas")
        assertEquals("The Office (US)", ep?.show)
        assertEquals(3, ep?.season)
        assertEquals(10, ep?.episode)
    }
}
