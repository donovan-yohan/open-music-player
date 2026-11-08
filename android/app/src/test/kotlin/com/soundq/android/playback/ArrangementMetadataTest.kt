package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Test

class ArrangementMetadataTest {
    private val first = ArrangementMetadataClip("a", "First song", "First artist", 0, 8000)
    private val second = ArrangementMetadataClip("b", "Second song", "Second artist", 5000, 12000)

    @Test fun zeroAndSingleSourceUseActualNames() {
        val result = arrangementMetadata(listOf(second, first), 0)
        assertEquals(listOf("a"), result.occurrences)
        assertEquals("First song", result.title)
        assertEquals("First artist", result.artist)
    }

    @Test fun overlapNamesBothSourcesInPlaybackOrder() {
        for (position in listOf(5000L, 7999L)) {
            val result = arrangementMetadata(listOf(second, first), position)
            assertEquals(listOf("a", "b"), result.occurrences)
            assertEquals("First song → Second song", result.title)
            assertEquals("First artist → Second artist", result.artist)
        }
    }

    @Test fun exactOutgoingEndSelectsOnlyTheIncomingSource() {
        val result = arrangementMetadata(listOf(first, second), 8000)
        assertEquals(listOf("b"), result.occurrences)
        assertEquals("Second song", result.title)
        assertEquals("Second artist", result.artist)
    }

    @Test fun beforeStartAndTrimmedGapNameUpcomingSourceAndEndKeepsLastSource() {
        val trimmed = first.copy(startMs = 1000, endMs = 3000)
        for (position in listOf(0L, 999L)) assertEquals("First song", arrangementMetadata(listOf(trimmed, second), position).title)
        for (position in listOf(3000L, 4999L, 12000L, Long.MAX_VALUE)) {
            val result = arrangementMetadata(listOf(trimmed, second), position)
            assertEquals(listOf("b"), result.occurrences)
            assertEquals("Second song", result.title)
        }
    }

    @Test fun repeatedRecordingKeepsBothOccurrencesEvenWhenNamesMatch() {
        val repeated = second.copy(occurrence = "a-again", title = first.title, artist = first.artist)
        val result = arrangementMetadata(listOf(first, repeated), 6000)
        assertEquals(listOf("a", "a-again"), result.occurrences)
        assertEquals("First song → First song", result.title)
        assertEquals("First artist → First artist", result.artist)
    }

    @Test fun metadataNeverInventsDeveloperLabelsOrUnknownArtists() {
        val noArtist = second.copy(artist = "")
        for (position in listOf(0L, 5000L, 8000L, 12000L)) {
            val result = arrangementMetadata(listOf(first, noArtist), position)
            assertFalse(result.title.contains("audition", ignoreCase = true))
            assertFalse(result.artist.contains("frozen revision", ignoreCase = true))
        }
        assertEquals("First artist", arrangementMetadata(listOf(first, noArtist), 6000).artist)
        assertEquals("", arrangementMetadata(listOf(first, noArtist), 8000).artist)
    }
}
