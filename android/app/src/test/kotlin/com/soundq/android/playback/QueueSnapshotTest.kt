package com.soundq.android.playback
import org.junit.Assert.*
import org.junit.Test
class QueueSnapshotTest {
    @Test fun deviceOnlyOccurrenceIntentSurvivesPausedPersistenceWithoutChangingLegacyRows() {
        val raw="""{"version":1,"endpoint":"https://fixture.test/api/v1","account":"A","selected":0,"position":17,"items":[{"occurrence":"device","track":7,"title":"Device","artist":"Fixture","manual":false,"localOnly":true}]}"""
        val saved=QueueSnapshot.decode(raw,"https://fixture.test/api/v1","A")!!
        assertTrue("device-only queue reconstruction cannot silently become streaming",saved.encode().contains("\"localOnly\":true"))
        assertEquals(17L,saved.position)
    }
    @Test fun duplicateOccurrenceRestoreIsScopedAndNeverContainsPlayIntentOrSignedUrls() {
        val saved=QueueSnapshot("https://fixture.test/api/v1","A",listOf(SavedOccurrence("occ-1",7,"One","Fixture",false),SavedOccurrence("occ-2",7,"One","Fixture",true)),1,2300)
        val encoded=saved.encode();val restored=QueueSnapshot.decode(encoded,saved.endpoint,"A")
        assertEquals(saved,restored);assertFalse(encoded.contains("playWhenReady"));assertFalse(encoded.contains("signature"))
        assertNull(QueueSnapshot.decode(encoded,saved.endpoint,"B"));assertNull(QueueSnapshot.decode(encoded,"https://other.test/api/v1","A"))
        assertNull(QueueSnapshot.decode(encoded.replace("\"version\":3","\"version\":999"),saved.endpoint,"A"))
    }
}
