package com.soundq.android.product

import com.soundq.android.data.LibraryAnalysisFacts
import com.soundq.android.data.preferences.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class LibraryRowMetadataTest {
    private val ready=KeyNotationState(ready=true)
    private val facts=LibraryAnalysisFacts("analyzed",127.5," A minor ","8a")
    @Test fun allKnownValuesKeepWholeFieldsAndMeaningfulSpeechInOrder() {
        assertEquals(listOf(LibraryMetadataField("3:42","Duration 3 minutes 42 seconds"),LibraryMetadataField("128 BPM","Tempo 128 BPM",LibraryMetadataKind.Tempo),LibraryMetadataField("8A","Key 8A",LibraryMetadataKind.Key,"8A")),libraryRowMetadata(222999,facts,ready))
    }
    @Test fun durationOmitsUnknownButPreservesPositiveSubsecondAndHours() {
        assertTrue(libraryRowMetadata(0,null,ready).isEmpty());assertTrue(libraryRowMetadata(-1,null,ready).isEmpty())
        assertEquals(LibraryMetadataField("0:00","Duration 0 seconds"),libraryRowMetadata(1,null,ready).single())
        assertEquals(LibraryMetadataField("01:01:01","Duration 1 hour 1 minute 1 second"),libraryRowMetadata(3661000,null,ready).single())
    }
    @Test fun malformedOrAbsentFactsNeverInventLabelsAndSiblingValuesRemain() {
        assertTrue(libraryRowMetadata(0,null,ready).isEmpty())
        for(bpm in listOf(Double.NaN,Double.POSITIVE_INFINITY,0.0,-1.0))assertTrue(libraryRowMetadata(0,LibraryAnalysisFacts(bpm=bpm,camelot="13A",musicalKey=" "),ready).isEmpty())
        assertEquals(listOf("8A"),libraryRowMetadata(0,facts.copy(bpm=null),ready).map {it.display})
        assertEquals(listOf("128 BPM"),libraryRowMetadata(0,LibraryAnalysisFacts(bpm=127.5),ready).map {it.display})
        assertEquals(listOf("A minor"),libraryRowMetadata(0,facts.copy(camelot="08A",bpm=null),ready).map {it.display})
    }
    @Test fun keyDefersUntilReadyAndUsesPreferredExistingFactWithFallback() {
        assertEquals(listOf("128 BPM"),libraryRowMetadata(0,facts,KeyNotationState()).map {it.display})
        assertEquals(listOf("128 BPM","A minor"),libraryRowMetadata(0,facts,ready.copy(choice=KeyNotation.Musical)).map {it.display})
        assertEquals(listOf("128 BPM","8A"),libraryRowMetadata(0,facts.copy(musicalKey=null),ready.copy(choice=KeyNotation.Musical)).map {it.display})
        val unicode="F♯ minor / 長い調性の名前"
        assertEquals(unicode,libraryRowMetadata(0,facts.copy(musicalKey=unicode),ready.copy(choice=KeyNotation.Musical)).last().display)
    }
    @Test fun analysisAppearanceKeepsWheelForMusicalNotationAndRejectsMalformedWheel() {
        val fields=libraryRowMetadata(0,facts,ready.copy(choice=KeyNotation.Musical))
        assertEquals(LibraryMetadataKind.Tempo,fields.first().kind)
        assertEquals(LibraryMetadataKind.Key,fields.last().kind)
        assertEquals("A minor",fields.last().display)
        assertEquals("8A",fields.last().camelot)
        assertNull(libraryRowMetadata(0,facts.copy(camelot="08A"),ready).last().camelot)
        assertEquals(LibraryMetadataKind.Duration,memberDurationMetadata(0).single().kind)
        assertEquals("—:—",memberDurationMetadata(0).single().display)
    }
    @Test fun acceptedPreferenceUpdatesAndRejectedWriteKeepsLastAcceptedLabel() {
        val dir=Files.createTempDirectory("library-notation-").toFile()
        try {
            val file=dir.resolve("notation.json");val owner=KeyNotationPreferences(file);owner.load()
            assertEquals("8A",libraryRowMetadata(0,facts,owner.state.value).last().display)
            assertTrue(owner.setChoice(owner.capture()!!,KeyNotation.Musical){true})
            assertEquals("A minor",libraryRowMetadata(0,facts,owner.state.value).last().display)
            file.writeText("not accepted")
            assertFalse(owner.setChoice(owner.capture()!!,KeyNotation.Camelot){true})
            assertEquals("A minor",libraryRowMetadata(0,facts,owner.state.value).last().display)
            assertEquals(KeyNotationError.Read,owner.state.value.error)
        }finally {dir.deleteRecursively()}
    }
}
