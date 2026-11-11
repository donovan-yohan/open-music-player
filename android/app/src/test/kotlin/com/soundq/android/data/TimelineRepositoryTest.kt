package com.soundq.android.data
import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
class TimelineRepositoryTest {
    @Test fun oversizedListeningContextRetiresEditorSourceLeasesAndAuditionWithoutWriting() {
        val dir=Files.createTempDirectory("timeline-context").toFile()
        try {
            val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val scope=session.capture()!!;var requests=0
            val repo=TimelineRepository(session,dir){_,id,duration,_->requests++;TrackWaveform(id,"v1",duration,listOf(PeakTier("x",floatArrayOf(-0.2f),floatArrayOf(0.3f))))}
            val sources=listOf(TimelineSource("M1",7,"Same",10000,QueueSegment.Manual));repo.observe(scope,sources)
            val d=repo.state.value.document;val clip=d.clips.single()
            val wave=repo.waveform(scope,TrackId(7),10000){true}!!
            val lease=repo.captureWaveformSource(scope,clip,wave)
            val tempo=repo.authorTempoBpm(scope,d,clip,wave,120.0){true}!!
            val tempoLease=repo.qualifyTempo(scope,tempo)!!
            val audition=repo.captureAudition(scope,d){true}!!
            assertTrue(lease());assertTrue(tempoLease())
            val large=(1..1001).map {TimelineSource("M$it",7,"Same",10000,QueueSegment.Manual)}
            repo.observe(scope,large)
            assertFalse(repo.state.value.writable);assertEquals(d,repo.state.value.document)
            assertFalse(lease());assertFalse(tempoLease());assertNull(repo.qualifyTempo(scope,tempo))
            assertNull(repo.waveform(scope,TrackId(7),10000){true});assertEquals(1,requests)
            assertNull(repo.authorTempoBpm(scope,d,clip,wave,125.0){true})
            assertFalse(repo.admitsAudition(audition,scope,d));assertFalse(repo.accepts(scope,d))
            assertNull(repo.captureAudition(scope,d){true});assertFalse(repo.undo {true})
            assertTrue(dir.listFiles().orEmpty().isEmpty())
            repo.observe(scope,sources)
            assertTrue(repo.state.value.writable);assertFalse(lease());assertFalse(tempoLease())
            assertFalse(repo.admitsAudition(audition,scope,d));assertFalse(repo.accepts(scope,d))
            assertNotNull(repo.waveform(scope,TrackId(7),10000){true});assertEquals(2,requests)
            assertNotNull(repo.captureAudition(scope,repo.state.value.document){true})
        } finally {dir.deleteRecursively()}
    }
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
