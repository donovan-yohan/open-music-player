package com.soundq.android.data
import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
class TimelineRepositoryTest {
    @Test fun persistedDraftSurvivesOwnerReplacementAndOldAccountCannotFetchOrWrite() {
        val dir=Files.createTempDirectory("timeline-test").toFile()
        try {
            val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            var requests=0
            val fetch={_:AccountScope,id:TrackId,duration:Long,_:()->Boolean ->requests++;TrackWaveform(id,"v1",duration,listOf(PeakTier("x",floatArrayOf(-0.2f),floatArrayOf(0.3f))))}
            val scope=session.capture()!!;val sources=listOf(TimelineSource("M1",7,"Same",10000,QueueSegment.Manual))
            val repo=TimelineRepository(session,dir,fetch);repo.observe(scope,sources)
            val d=repo.state.value.document
            assertTrue(repo.commit(TimelineEdit(d.revision,d.clips.single(),EditKind.TrimIn,1000)){true})
            val restored=TimelineRepository(session,dir,fetch);restored.observe(scope,sources)
            assertEquals(1000L,restored.state.value.document.clips.single().sourceInMs)
            assertNotNull(repo.waveform(scope,TrackId(7),10000){true})
            assertNotNull(repo.waveform(scope,TrackId(7),10000){true});assertEquals(1,requests)
            session.retire()
            assertNull(repo.waveform(scope,TrackId(7),10000){true})
            assertFalse(repo.undo {true});assertEquals(1,requests)
        } finally {dir.deleteRecursively()}
    }
}
