package app.tuner.core.models

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CatchupAvailabilityTest {
    private val now = Instant.parse("2026-11-17T12:00:00Z")
    private fun channel(type: CatchupType? = CatchupType.XTREAM, days: Int? = 3) =
        Channel(id = "c", sourceId = "s", categoryId = null, name = "C", providerOrder = 0, streamURL = "x", catchupType = type, catchupDays = days)
    private fun program(startHoursAgo: Long, lengthHours: Long = 1) = Program(
        epgKey = "f|c", start = now.minusSeconds(startHoursAgo * 3600),
        end = now.minusSeconds(startHoursAgo * 3600).plusSeconds(lengthHours * 3600), title = "P")

    @Test fun endedProgrammeInsideTheArchive() { assertTrue(channel().catchupAvailable(program(5), now)) }

    @Test fun liveProgrammeCanStartOver() { assertTrue(channel().catchupAvailable(program(0, 2).copy(start = now.minusSeconds(600)), now)) }

    @Test fun olderThanTheArchiveIsNotOffered() { assertFalse(channel(days = 3).catchupAvailable(program(4 * 24), now)) }

    @Test fun futureProgrammeIsNotOffered() { assertFalse(channel().catchupAvailable(program(-2), now)) }

    @Test fun noCatchupTypeOrZeroDays() {
        assertFalse(channel(type = null).catchupAvailable(program(5), now))
        assertFalse(channel(days = 0).catchupAvailable(program(5), now))
    }

    @Test fun unknownDaysAllowsAnyPastProgramme() { assertTrue(channel(days = null).catchupAvailable(program(10 * 24), now)) }
}
