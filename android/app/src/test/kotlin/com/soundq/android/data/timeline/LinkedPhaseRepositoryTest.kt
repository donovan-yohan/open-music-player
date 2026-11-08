package com.soundq.android.data.timeline

import com.soundq.android.data.*
import com.soundq.android.playback.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class LinkedPhaseRepositoryTest {
    private fun sources()=listOf(TimelineSource("a",7,"Fixture",2000,QueueSegment.Context),TimelineSource("b",7,"Fixture",2000,QueueSegment.Context))
    @Test fun durableRepositoryAccountRouteGridReadinessAndServerLossBoundary() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"));val scope=session.capture()!!
            val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-repository-").toFile()
            try {
                val repo=TimelineRepository(session,dir){_,track,duration,_->TrackWaveform(track,"analysis-new",duration,emptyList())}
                repo.observe(scope,sources());var d=repo.state.value.document
                val e=PhaseEdit(d.revision,d.clips[0],d.clips[1],PhaseGrid("manual:7:2000","1",500,0,0),PhaseGrid("manual:7:2000","2",500,0,0),1,500)
                assertTrue(repo.preview(e).accepted);assertFalse(repo.commit(e){false});assertTrue(repo.commit(e){true});d=repo.state.value.document
                val bytes=dir.listFiles()!!.single().readText();assertTrue(bytes.contains("\"version\":3"))
                val save=ArrangementSave(SoundQApi(session,f.client),repo)
                assertNull(save.save(scope,d,"Linked"){true});assertEquals(0,f.server.requestCount);assertTrue(save.state.value.message!!.contains("Unlock"))
                assertFalse(d.matchesArrangement(d.arrangementPlan()))
                val reload=TimelineRepository(session,dir){_,track,duration,_->TrackWaveform(track,"analysis-new",duration,emptyList())}
                reload.observe(scope,sources());val frozen=reload.state.value.document
                assertEquals(d.clips,frozen.clips);assertEquals(d.phaseLink,frozen.phaseLink)
                assertTrue(reload.accepts(scope,frozen))
                reload.waveform(scope,TrackId(7),2000){true}
                assertFalse("Fresh different source identity invalidates readiness, never relocates audio",reload.accepts(scope,frozen));assertEquals(frozen,reload.state.value.document)
                assertNull(reload.captureAudition(scope,frozen){true})
                assertTrue(reload.unlock(frozen.revision){true});assertEquals(frozen.clips,reload.state.value.document.clips)
                val afterUnlockBytes=dir.listFiles()!!.single().readText()
                val before=repo.state.value.document;session.accept(session.beginIntent(),SecretTokens("new","r","fixture"))
                assertFalse(repo.unlock(before.revision){true});assertFalse(repo.commit(e){true});assertFalse(repo.accepts(scope,before));assertEquals(afterUnlockBytes,dir.listFiles()!!.single().readText()) // old owner cannot write
            } finally {dir.deleteRecursively()}
        }
    }
    @Test fun explicitRefreshRejectsHeldPreviewAndInstalledReadinessWithoutRecomputing() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"));val scope=session.capture()!!
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-refresh-").toFile()
        try {
            var generation="analysis-one"
            val repo=TimelineRepository(session,dir){_,track,duration,_->TrackWaveform(track,generation,duration,emptyList())}
            repo.observe(scope,sources());repo.waveform(scope,TrackId(7),2000){true}
            val d=repo.state.value.document
            val grid=PhaseGrid("analysis-one","1",500,0,0)
            val e=PhaseEdit(d.revision,d.clips[0],d.clips[1],grid,grid,1,500)
            assertTrue(repo.preview(e).accepted)
            generation="analysis-two";repo.waveform(scope,TrackId(7),2000,refresh=true){true}
            assertFalse(repo.commit(e){true});assertSame(d,repo.state.value.document)
            val next=e.copy(referenceGrid=grid.copy(sourceKey=generation),incomingGrid=grid.copy(sourceKey=generation))
            assertTrue(repo.commit(next){true});val accepted=repo.state.value.document
            val token=repo.captureAudition(scope,accepted){true}!!
            assertTrue(repo.installAudition(token,scope,accepted){})
            generation="analysis-three";repo.waveform(scope,TrackId(7),2000,refresh=true){true}
            var played=false;assertFalse(repo.completeAudition(token,scope,accepted){played=true});assertFalse(played)
            assertEquals(accepted,repo.state.value.document);assertTrue(repo.state.value.message!!.contains("timing changed"))
        }finally{dir.deleteRecursively()}
    }
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","fixture"))}
    private fun sources(duration:Long)=sources().map {it.copy(durationMs=duration)}
    private fun edit(repo:TimelineRepository,grid:PhaseGrid):PhaseEdit {
        val d=repo.state.value.document
        return PhaseEdit(d.revision,d.clips[0],d.clips[1],grid,grid,1,500)
    }
    private fun qualified(track:TrackId,duration:Long,key:String="analysis-$duration")=TrackWaveform(track,key,duration,emptyList(),phaseTiming=PhaseGrid(key,"server:1",500,0,provenance="manual_timing_v2"))
    @Test fun durationChangeRefusesFreshCurrentEditWithOldQualificationUntilMatchingFetch() {
        val session=session();val scope=session.capture()!!
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-duration-").toFile()
        try {
            var requests=0
            val repo=TimelineRepository(session,dir){_,track,duration,_->requests++;qualified(track,duration)}
            repo.observe(scope,sources(2000));val old=repo.waveform(scope,TrackId(7),2000){true}!!
            assertTrue(repo.preview(edit(repo,old.phaseTiming!!)).accepted) // unchanged descriptor control
            assertTrue(repo.commit(TimelineEdit(repo.state.value.document.revision,repo.state.value.document.clips[0],EditKind.Placement,100)){true})
            repo.observe(scope,sources(3000));val current=repo.state.value.document
            val bytes=dir.listFiles()!!.single().readBytes()
            val stale=edit(repo,old.phaseTiming!!)
            assertSame(current.clips[0],stale.reference);assertSame(current.clips[1],stale.incoming)
            assertEquals(current.revision,stale.revision);assertEquals(3000L,stale.reference.sourceDurationMs)
            val preview=repo.preview(stale).accepted;val committed=repo.commit(stale){true}
            val after=repo.state.value.document
            val audition=if(after.phaseLink!=null)repo.captureAudition(scope,after){true} else null
            assertFalse("A fresh edit must not borrow the old 2000ms qualification for a 3000ms source (commit=$committed, audition=$audition)",preview)
            assertFalse(committed);assertNull(audition);assertSame(current,after)
            assertArrayEquals(bytes,dir.listFiles()!!.single().readBytes());assertTrue(repo.accepts(scope,current)) // ordinary no-link admission remains
            assertFalse(repo.preview(edit(repo,old.phaseTiming!!.copy(sourceKey="manual:7:3000"))).accepted) // no remint of adopted timing
            assertFalse(repo.preview(edit(repo,old.phaseTiming!!.copy(provenance="local_manual"))).accepted) // old analysis key is still unqualified
            val fresh=repo.waveform(scope,TrackId(7),3000){true}!!
            assertEquals(2,requests);assertEquals(3000L,fresh.durationMs)
            assertTrue(repo.commit(edit(repo,fresh.phaseTiming!!)){true})
            val accepted=repo.state.value.document
            assertEquals(3000L,accepted.phaseLink!!.referenceDurationMs);assertEquals(fresh.sourceKey,accepted.phaseLink!!.referenceGrid.sourceKey)
            assertTrue(repo.accepts(scope,accepted));assertNotNull(repo.captureAudition(scope,accepted){true})
            assertTrue(dir.listFiles()!!.single().readText().contains("\"version\":3"))
        }finally{dir.deleteRecursively()}
    }
    @Test fun heldOldDurationFetchCannotReplaceFreshQualificationAfterObserve() {
        val session=session();val scope=session.capture()!!
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-held-duration-").toFile()
        val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
        val worker=java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val repo=TimelineRepository(session,dir){_,track,duration,_->
                if(duration==2000L){entered.countDown();check(release.await(10,java.util.concurrent.TimeUnit.SECONDS))}
                qualified(track,duration)
            }
            repo.observe(scope,sources(2000))
            val held=worker.submit<TrackWaveform?> {repo.waveform(scope,TrackId(7),2000){true}}
            assertTrue(entered.await(10,java.util.concurrent.TimeUnit.SECONDS))
            repo.observe(scope,sources(3000));val fresh=repo.waveform(scope,TrackId(7),3000){true}!!
            assertTrue(repo.commit(edit(repo,fresh.phaseTiming!!)){true})
            val document=repo.state.value.document;val bytes=dir.listFiles()!!.single().readBytes()
            val token=repo.captureAudition(scope,document){true}!!;assertTrue(repo.installAudition(token,scope,document){})
            release.countDown();val late=held.get(10,java.util.concurrent.TimeUnit.SECONDS)
            assertNull("Old-duration completion must retire instead of republishing source readiness",late)
            assertTrue(repo.accepts(scope,document));var played=false
            assertTrue(repo.completeAudition(token,scope,document){played=true});assertTrue(played)
            assertSame(document,repo.state.value.document);assertArrayEquals(bytes,dir.listFiles()!!.single().readBytes())
            assertSame(fresh,repo.waveform(scope,TrackId(7),3000){true})
        }finally{release.countDown();worker.shutdownNow();assertTrue(worker.awaitTermination(10,java.util.concurrent.TimeUnit.SECONDS));dir.deleteRecursively()}
    }
    @Test fun knownChangedOrAmbiguousDurationRefusesBeforeFetchAndHonestNewManualTimingWorks() {
        val session=session();val scope=session.capture()!!
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-descriptor-").toFile()
        try {
            var requests=0
            val repo=TimelineRepository(session,dir){_,track,duration,_->requests++;qualified(track,duration)}
            repo.observe(scope,sources(2000));repo.waveform(scope,TrackId(7),2000){true}
            repo.observe(scope,sources(3000))
            assertNull(repo.waveform(scope,TrackId(7),2000,refresh=true){true});assertEquals(1,requests)
            val manual=PhaseGrid.manual("manual:7:3000","explicit-new-descriptor","120",0,null)
            assertTrue(repo.commit(edit(repo,manual)){true});assertTrue(repo.accepts(scope,repo.state.value.document))
            repo.observe(scope,listOf(sources(2000)[0],sources(3000)[1]))
            assertFalse(repo.preview(edit(repo,manual)).accepted)
            assertNull(repo.waveform(scope,TrackId(7),2000){true});assertNull(repo.waveform(scope,TrackId(7),3000){true});assertEquals(1,requests)
            repo.observe(scope,sources(3000));val fresh=repo.waveform(scope,TrackId(7),3000){true}!!
            assertTrue(repo.preview(edit(repo,fresh.phaseTiming!!)).accepted);assertEquals(2,requests)
        }finally{dir.deleteRecursively()}
    }
    @Test fun sourceAbsenceRetiresHeldFetchEvenWhenDurationReturns()=heldSourceAba(true)
    @Test fun durationAbaRetiresHeldFetchEvenWhenDurationReturns()=heldSourceAba(false)
    private fun heldSourceAba(absent:Boolean) {
        val session=session();val scope=session.capture()!!
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-source-aba-").toFile()
        val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
        val worker=java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val requests=java.util.concurrent.atomic.AtomicInteger()
            val repo=TimelineRepository(session,dir){_,track,duration,_->
                val n=requests.incrementAndGet()
                if(n==1){entered.countDown();check(release.await(10,java.util.concurrent.TimeUnit.SECONDS))}
                qualified(track,duration,"analysis-request-$n")
            }
            repo.observe(scope,sources(2000))
            val held=worker.submit<TrackWaveform?> {repo.waveform(scope,TrackId(7),2000){true}}
            assertTrue(entered.await(10,java.util.concurrent.TimeUnit.SECONDS))
            repo.observe(scope,if(absent)emptyList() else sources(3000));repo.observe(scope,sources(2000))
            release.countDown();assertNull("Returning duration cannot revive a retired source observation (absent=$absent)",held.get(10,java.util.concurrent.TimeUnit.SECONDS))
            val fresh=repo.waveform(scope,TrackId(7),2000){true}!!
            assertEquals(2,requests.get());assertTrue(repo.commit(edit(repo,fresh.phaseTiming!!)){true})
        }finally{release.countDown();worker.shutdownNow();assertTrue(worker.awaitTermination(10,java.util.concurrent.TimeUnit.SECONDS));dir.deleteRecursively()}
    }
    @Test fun unchangedDescriptorRetainsQualificationAcrossObservationAndPeakLruEviction() {
        val session=session();val scope=session.capture()!!
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-lru-").toFile()
        try {
            var requests=0
            val repo=TimelineRepository(session,dir){_,track,duration,_->
                requests++
                if(track.value==7L)qualified(track,duration) else TrackWaveform(track,"analysis-${track.value}",duration,listOf(PeakTier("analysis",FloatArray(131072),FloatArray(131072))))
            }
            val observed=sources(2000)+(8L..23L).map {TimelineSource("large-$it",it,"Large",2000,QueueSegment.Manual)}
            repo.observe(scope,observed);val wave=repo.waveform(scope,TrackId(7),2000){true}!!
            repo.observe(scope,observed.map {it.copy(title="Renamed")})
            assertSame(wave,repo.waveform(scope,TrackId(7),2000){true});assertEquals(1,requests)
            assertTrue(repo.commit(edit(repo,wave.phaseTiming!!)){true});val document=repo.state.value.document
            for(track in 8L..23L)repo.waveform(scope,TrackId(track),2000){true} // producer-bounded arrays evict peaks, not qualification
            assertTrue(repo.accepts(scope,document));assertTrue(repo.preview(edit(repo,wave.phaseTiming!!)).accepted)
            assertEquals(wave.sourceKey,repo.waveform(scope,TrackId(7),2000){true}!!.sourceKey);assertEquals(18,requests)
        }finally{dir.deleteRecursively()}
    }
    @Test fun sourceReappearanceCannotBorrowPreviouslyCachedQualification() {
        val session=session();val scope=session.capture()!!
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-reappear-").toFile()
        try {
            var requests=0
            val repo=TimelineRepository(session,dir){_,track,duration,_->requests++;qualified(track,duration,"analysis-$requests")}
            repo.observe(scope,sources(2000));val old=repo.waveform(scope,TrackId(7),2000){true}!!
            repo.observe(scope,emptyList());assertNull(repo.waveform(scope,TrackId(7),2000){true});assertEquals(1,requests)
            repo.observe(scope,sources(2000));assertFalse(repo.preview(edit(repo,old.phaseTiming!!)).accepted)
            val fresh=repo.waveform(scope,TrackId(7),2000){true}!!
            assertEquals(2,requests);assertNotEquals(old.sourceKey,fresh.sourceKey)
            assertTrue(repo.commit(edit(repo,fresh.phaseTiming!!)){true})
        }finally{dir.deleteRecursively()}
    }
    @Test fun unchangedDescriptorAllowsHeldFetchThroughTitleAndQueueObservation() {
        val session=session();val scope=session.capture()!!
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-held-same-").toFile()
        val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
        val worker=java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val repo=TimelineRepository(session,dir){_,track,duration,valid->
                entered.countDown();check(release.await(10,java.util.concurrent.TimeUnit.SECONDS));assertTrue(valid());qualified(track,duration)
            }
            repo.observe(scope,sources(2000));val held=worker.submit<TrackWaveform?> {repo.waveform(scope,TrackId(7),2000){true}}
            assertTrue(entered.await(10,java.util.concurrent.TimeUnit.SECONDS))
            repo.observe(scope,sources(2000).reversed().map {it.copy(title="Renamed")});release.countDown()
            val fresh=held.get(10,java.util.concurrent.TimeUnit.SECONDS)!!
            assertTrue(repo.commit(edit(repo,fresh.phaseTiming!!)){true})
        }finally{release.countDown();worker.shutdownNow();assertTrue(worker.awaitTermination(10,java.util.concurrent.TimeUnit.SECONDS));dir.deleteRecursively()}
    }
    @Test fun heldAccountRetirementCannotPublishQualificationIntoReplacementOwner() {
        val session=session();val scope=session.capture()!!
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"phase-account-held-").toFile()
        val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
        val worker=java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val repo=TimelineRepository(session,dir){_,track,duration,_->entered.countDown();check(release.await(10,java.util.concurrent.TimeUnit.SECONDS));qualified(track,duration)}
            repo.observe(scope,sources(2000));val held=worker.submit<TrackWaveform?> {repo.waveform(scope,TrackId(7),2000){true}}
            assertTrue(entered.await(10,java.util.concurrent.TimeUnit.SECONDS))
            session.accept(session.beginIntent(),SecretTokens("new","r","replacement"));val replacement=session.capture()!!
            repo.observe(replacement,sources(2000));release.countDown();assertNull(held.get(10,java.util.concurrent.TimeUnit.SECONDS))
            assertFalse(repo.preview(edit(repo,qualified(TrackId(7),2000).phaseTiming!!)).accepted)
            assertTrue(repo.preview(edit(repo,PhaseGrid.manual("manual:7:2000","new","120",0,null))).accepted)
        }finally{release.countDown();worker.shutdownNow();assertTrue(worker.awaitTermination(10,java.util.concurrent.TimeUnit.SECONDS));dir.deleteRecursively()}
    }
    @Test fun manualTimingParserUsesRevisionProvenanceAndNeverPromotesSparseGeneratedArrays() {
        fun body(bpm:String="120",provenance:String="manual_override",revision:Int=1)=Json.parseToJsonElement("""{"track_id":7,"schema_version":1,"status":"analyzed","override_revision":$revision,"overrides":{"manual_timing_v2":{"schema_version":2,"bpm":$bpm,"beat_anchor_ms":125,"revision":$revision,"provenance":"$provenance"}},"effective_timing":{"beat_grid":{"beats_ms":[125,625]},"downbeats":{"positions_ms":[125,1625]}}}""").jsonObject
        val wave=AnalysisWaveformJson.parse(body(),TrackId(7),4000)
        assertEquals(500L,wave.phaseTiming!!.periodMs);assertNull(wave.phaseTiming!!.groupOriginMs)
        assertEquals("manual_timing_v2",wave.phaseTiming!!.provenance);assertEquals("server:1",wave.phaseTiming!!.revision)
        assertNull(AnalysisWaveformJson.parse(body("128"),TrackId(7),4000).phaseTiming)
        assertNull(AnalysisWaveformJson.parse(body(provenance="generated"),TrackId(7),4000).phaseTiming)
        assertNotEquals(wave.sourceKey,AnalysisWaveformJson.parse(body(revision=2),TrackId(7),4000).sourceKey)
        val generated=JsonObject(body()-"overrides")
        assertNull(AnalysisWaveformJson.parse(generated,TrackId(7),4000).phaseTiming)
        assertEquals(listOf(125L,1625L),wave.downbeats) // actual 3-beat meter evidence independent of groups
    }
}
