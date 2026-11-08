package com.soundq.android.data.timeline

import com.soundq.android.data.*
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class TempoRepositoryIntegrationTest {
    private class Store:SessionStore {
        override fun load(endpoint:ApiEndpoint):SecretTokens?=null
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
        override fun clear(){}
    }
    @Test fun authoredFadeTrimIsRefusedUnchangedWithAutoOffAndOn() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-fade-trim").toFile()
        try {
            val inputs=listOf(TimelineSource("a",1,"A",20000,QueueSegment.Manual),TimelineSource("b",2,"B",20000,QueueSegment.Manual))
            val repo=TimelineRepository(session,directory){_,track,duration,_->TrackWaveform(track,"s-${track.value}",duration,emptyList(),suggestedBpm=120.0)}
            repo.observe(scope,inputs);inputs.forEach {repo.waveform(scope,TrackId(it.track),it.durationMs,valid={true})}
            var d=repo.state.value.document
            assertTrue(repo.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,16000)){true})
            d=repo.state.value.document
            assertTrue(repo.commit(TimelineFadeEdit(d.revision,d.clips[0],d.clips[1],4000)){true})
            fun refused() {
                val accepted=repo.state.value.document;val bytes=directory.listFiles()!!.single().readText()
                for((clip,kind,value) in listOf(Triple(accepted.clips[0],EditKind.TrimOut,19000L),Triple(accepted.clips[1],EditKind.TrimIn,1000L))) {
                    val edit=TimelineEdit(accepted.revision,clip,kind,value)
                    val decision=repo.preview(edit)
                    assertFalse("Auto=${accepted.autoBpmCrossfade} must not retime an authored fade",decision.accepted)
                    assertTrue(decision.reason.orEmpty().contains("authored fade"))
                    assertFalse(repo.commit(edit){true})
                    assertEquals(accepted,repo.state.value.document);assertEquals(bytes,directory.listFiles()!!.single().readText())
                }
            }
            refused()
            d=repo.state.value.document
            val auto=d.withAutoBpmCrossfade(true,d.clips.map {repo.tempoSource(it)!!})
            assertTrue(repo.commit(TimelineTempoEdit(d,auto)){true})
            assertEquals(16000L,repo.state.value.document.clips[0].globalEndMs-4000)
            refused()
        }finally {directory.deleteRecursively()}
    }
    @Test fun currentGeneratedAnalysisQualifiesPlaybackWithoutAuthoringBeatPhase() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-analysis").toFile()
        try {
            val raw="""{"track_id":1,"schema_version":2,"status":"analyzed","summary":{"bpm":{"value":138.0}}}"""
            val wave=AnalysisWaveformJson.parse(kotlinx.serialization.json.Json.parseToJsonElement(raw) as kotlinx.serialization.json.JsonObject,TrackId(1),12347)
            assertNull("Generated BPM is not phase authority",wave.phaseTiming)
            assertNull("No manual timing was authored",wave.tempoTiming)
            val repo=TimelineRepository(session,directory){_,_,_,_->wave}
            repo.observe(scope,listOf(TimelineSource("a",1,"A",12347,QueueSegment.Manual)))
            repo.waveform(scope,TrackId(1),12347,valid={true})
            val d=repo.state.value.document
            val id=repo.tempoSource(d.clips.single())
            assertNotNull("Current generated source BPM must immediately qualify ordinary playback without a beat anchor",id)
            assertEquals("analysis_bpm",id!!.gridProvenance)
            assertFalse(id.beatAnchorKnown)
            assertNull(repo.qualifyTempo(scope,id.copy(sourceBpm=150.0)))
            assertNull(repo.qualifyTempo(scope,id.copy(gridRevision="other")))
            assertNull(repo.qualifyTempo(scope,id.copy(beatAnchorKnown=true)))
            val lease=repo.captureTempoSources(listOf(id));assertTrue(lease())
            assertTrue(repo.commit(TimelineTempoEdit(d,d.withPlaybackTempo(TempoPlaybackIntent(id,140.25))),lease))
            assertEquals(140.25/138.0,repo.state.value.document.clips.single().rates.baseRate,1e-12)
            val bytes=directory.listFiles()!!.single().readText()
            assertTrue(bytes.contains("\"beatAnchorKnown\":false"))
            val restored=TimelineRepository(session,directory){_,_,_,_->wave}
            restored.observe(scope,listOf(TimelineSource("a",1,"A",12347,QueueSegment.Manual)))
            assertFalse(restored.accepts(scope,restored.state.value.document))
            restored.waveform(scope,TrackId(1),12347,valid={true})
            assertTrue(restored.accepts(scope,restored.state.value.document))
            assertEquals(id,restored.tempoSource(restored.state.value.document.clips.single()))
            val accepted=repo.state.value.document
            repo.observe(scope,emptyList())
            assertFalse(repo.state.value.writable)
            repo.observe(scope,listOf(TimelineSource("a",1,"A",12347,QueueSegment.Manual)))
            assertTrue(repo.state.value.writable)
            assertFalse("Restored occurrence still needs a fresh source read",repo.accepts(scope,repo.state.value.document))
            repo.waveform(scope,TrackId(1),12347,valid={true})
            val returned=repo.state.value.document
            assertEquals(accepted.playbackTempos,returned.playbackTempos)
            assertTrue(repo.commit(TimelineTempoEdit(returned,returned.withPlaybackTempo(TempoPlaybackIntent(id,141.0)))){true})
        } finally {directory.deleteRecursively()}
    }
    @Test fun missingBpmRequiresExplicitLocalConfirmationAndRetiresAcrossAnalysisAba() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-bpm-only").toFile()
        try {
            var suggestion:Double?=null
            val inputs=listOf(TimelineSource("a",1,"A",12347,QueueSegment.Manual))
            val repo=TimelineRepository(session,directory){_,track,duration,_->TrackWaveform(track,"same-key",duration,emptyList(),suggestedBpm=suggestion)}
            repo.observe(scope,inputs)
            val wave=repo.waveform(scope,TrackId(1),12347,valid={true})!!
            val d=repo.state.value.document;val clip=d.clips.single()
            assertNull(repo.tempoSource(clip))
            val fake=TempoSourceIdentity("a",1,"same-key",12347,"unconfirmed","local_bpm",138.5,0.0,1,false)
            assertNull(repo.qualifyTempo(scope,fake))
            assertFalse(repo.commit(TimelineTempoEdit(d,d.withPlaybackTempo(TempoPlaybackIntent(fake,140.0)))){true})
            assertNull(repo.authorTempoBpm(scope,d,clip,wave,Double.NaN){true})
            assertNull(repo.authorTempoBpm(scope,d,clip,wave,138.5){false})
            val measured=repo.captureWaveformSource(scope,clip,wave)
            val id=repo.authorTempoBpm(scope,d,clip,wave,138.5,measured)!!
            assertEquals("local_bpm",id.gridProvenance);assertFalse(id.beatAnchorKnown)
            val lease=repo.captureTempoSources(listOf(id));assertTrue(lease())
            assertTrue(repo.commit(TimelineTempoEdit(d,d.withPlaybackTempo(TempoPlaybackIntent(id,140.0))),lease))
            val bytes=directory.listFiles()!!.single().readText()
            val restored=TimelineRepository(session,directory){_,_,_,_->wave}
            restored.observe(scope,inputs);restored.waveform(scope,TrackId(1),12347,valid={true})
            assertTrue(restored.accepts(scope,restored.state.value.document))
            assertEquals(id,restored.tempoSource(restored.state.value.document.clips.single()))
            suggestion=150.0;repo.waveform(scope,TrackId(1),12347,refresh=true,valid={true})
            assertFalse(lease());assertFalse(measured())
            suggestion=null;repo.waveform(scope,TrackId(1),12347,refresh=true,valid={true})
            assertFalse("Analysis ABA cannot revive the local editor lease",lease())
            assertEquals(bytes,directory.listFiles()!!.single().readText())
        }finally {directory.deleteRecursively()}
    }
    @Test fun analysisBpmRequiresCurrentCompletedNumericProducerAndFencesRevisionAba() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-bpm-revision").toFile()
        try {
            fun parsed(value:String="138.0",status:String="analyzed",revision:String="1")=AnalysisWaveformJson.parse(kotlinx.serialization.json.Json.parseToJsonElement("""{"track_id":1,"schema_version":2,"status":"$status","updated_at":"$revision","summary":{"bpm":{"value":$value}}}""") as kotlinx.serialization.json.JsonObject,TrackId(1),12347)
            for(status in listOf("failed","stale","analyzing","pending","unsupported"))assertNull(parsed(status=status).analysisTempo())
            for(value in listOf("\"138\"","null","0","601"))assertNull(parsed(value).analysisTempo())
            var wave=parsed()
            val repo=TimelineRepository(session,directory){_,_,_,_->wave}
            val inputs=listOf(TimelineSource("a",1,"A",12347,QueueSegment.Manual))
            repo.observe(scope,inputs);repo.waveform(scope,TrackId(1),12347,valid={true})
            val id=repo.tempoSource(repo.state.value.document.clips.single())!!
            val lease=repo.captureTempoSources(listOf(id));assertTrue(lease())
            repo.waveform(scope,TrackId(1),12347,refresh=true,valid={true});assertTrue(lease())
            wave=parsed(revision="2");repo.waveform(scope,TrackId(1),12347,refresh=true,valid={true});assertFalse(lease())
            wave=parsed();repo.waveform(scope,TrackId(1),12347,refresh=true,valid={true});assertFalse(lease())
            val fresh=repo.captureTempoSources(listOf(id));assertTrue(fresh())
            repo.observe(scope,emptyList());repo.observe(scope,inputs)
            repo.waveform(scope,TrackId(1),12347,valid={true});assertFalse(fresh())
        }finally {directory.deleteRecursively()}
    }
    @Test fun localBpmCorrectionUsesExplicitConfirmationWithoutChangingGeneratedMetadata() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-bpm-correction").toFile()
        try {
            val wave=TrackWaveform(TrackId(1),"source",12347,emptyList(),suggestedBpm=150.0)
            val repo=TimelineRepository(session,directory){_,_,_,_->wave}
            repo.observe(scope,listOf(TimelineSource("a",1,"A",12347,QueueSegment.Manual)))
            repo.waveform(scope,TrackId(1),12347,valid={true})
            val d=repo.state.value.document;val clip=d.clips.single()
            assertEquals("analysis_bpm",repo.tempoSource(clip)!!.gridProvenance)
            val corrected=repo.authorTempoBpm(scope,d,clip,wave,138.5,repo.captureWaveformSource(scope,clip,wave))!!
            assertFalse(corrected.beatAnchorKnown);assertEquals("local_bpm",corrected.gridProvenance)
            assertTrue(repo.commit(TimelineTempoEdit(d,d.withPlaybackTempo(TempoPlaybackIntent(corrected,140.25))),repo.captureTempoSources(listOf(corrected))))
            assertEquals(corrected,repo.tempoSource(repo.state.value.document.clips.single()))
            assertEquals(150.0,repo.waveform(scope,TrackId(1),12347,valid={true})!!.suggestedBpm!!,0.0)
        }finally {directory.deleteRecursively()}
    }
    @Test fun preciseAuthoredTempoDoesNotRequireLegacyIntegerPeriodGrid() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-precise").toFile()
        try {
            val timing=TempoSourceTiming("source","server:1","manual_timing_v2",138.0,31.0)
            val repo=TimelineRepository(session,directory){_,track,duration,_->TrackWaveform(track,"source",duration,emptyList(),tempoTiming=timing)}
            repo.observe(scope,listOf(TimelineSource("a",1,"A",12347,QueueSegment.Manual)))
            repo.waveform(scope,TrackId(1),12347,valid={true})
            assertNotNull("Precise authored timing must qualify without a phase grid",repo.qualifyTempo(scope,timing.identity(repo.state.value.document.clips.single())))
        } finally {directory.deleteRecursively()}
    }
    @Test fun localSourceConfirmationPersistsPlaybackReloadAndRejectsSourceAba() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-local").toFile()
        try {
            var key="analysis-1"
            val sources=listOf(TimelineSource("a",1,"A",12347,QueueSegment.Manual),TimelineSource("b",2,"B",17777,QueueSegment.Manual))
            fun repo()=TimelineRepository(session,directory){_,track,duration,_->TrackWaveform(track,key,duration,emptyList())}.also {it.observe(scope,sources)}
            val repo=repo();var d=repo.state.value.document
            val wave=repo.waveform(scope,TrackId(1),12347,valid={true})!!
            assertNull(repo.tempoSource(d.clips[0]))
            assertNull(repo.authorTempoSource(scope,d,d.clips[0],wave,138.0,Double.NaN){true})
            val id=repo.authorTempoSource(scope,d,d.clips[0],wave,138.0,31.25){true}!!
            val lease=repo.captureTempoSources(listOf(id));assertTrue(lease())
            val measuredLease=repo.captureWaveformSource(scope,d.clips[0],wave);assertTrue(measuredLease())
            val held=d.withPlaybackTempo(TempoPlaybackIntent(id,140.25))
            assertTrue(repo.commit(TimelineTempoEdit(d,held),lease))
            d=repo.state.value.document
            val bytes=directory.listFiles()!!.single().readText()
            assertTrue(bytes.contains("\"version\":5"))
            val restored=repo()
            assertFalse("Reload waits for the exact current source",restored.accepts(scope,restored.state.value.document))
            restored.waveform(scope,TrackId(1),12347,valid={true})
            assertTrue(restored.accepts(scope,restored.state.value.document))
            assertEquals(d.playbackTempos,restored.state.value.document.playbackTempos)
            key="analysis-2";repo.waveform(scope,TrackId(1),12347,refresh=true,valid={true})
            assertFalse(lease())
            key="analysis-1";repo.waveform(scope,TrackId(1),12347,refresh=true,valid={true})
            assertFalse("Source ABA cannot revive the old editor",lease())
            assertFalse("Source ABA cannot re-author using a held measured source",measuredLease())
            assertEquals(bytes,directory.listFiles()!!.single().readText())
            assertFalse(repo.commit(TimelineTempoEdit(d,d.withPlaybackTempo(TempoPlaybackIntent(id,141.0))),lease))
        }finally{directory.deleteRecursively()}
    }
    @Test fun fittedCandidatePersistsReloadsAndStaleQualificationCannotWrite() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-save").toFile()
        try {
            val sources=listOf(TimelineSource("a",1,"A",20000,QueueSegment.Manual),TimelineSource("b",2,"B",20000,QueueSegment.Manual))
            var revision="r1"
            fun repo()=TimelineRepository(session,directory){_,track,duration,_->TrackWaveform(track,"s-${track.value}",duration,emptyList(),phaseTiming=PhaseGrid("s-${track.value}",revision,if(track.value==1L)500 else 400,0,provenance="manual_timing_v2"))}.also {r->r.observe(scope,sources);sources.forEach {r.waveform(scope,TrackId(it.track),it.durationMs,valid={true})}}
            val repo=repo();var d=repo.state.value.document
            assertTrue(repo.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,16000)){true})
            d=repo.state.value.document
            val a=TempoSourceIdentity("a",1,"s-1",20000,"r1","manual_timing_v2",120.0,0.0,1)
            val b=a.copy(occurrence="b",track=2,sourceKey="s-2",sourceBpm=150.0)
            val draft=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,a,b,120.0,TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,16000.0,20000.0,32,8,TempoGainLaw.EqualPower)
            val fit=com.soundq.android.product.timeline.fitTempoEditorRamp(d,com.soundq.android.product.timeline.TempoEditorOverlap(d.clips[0],d.clips[1]),draft)
            val edit=TimelineTempoEdit(d,fit.document)
            val admission=repo.captureTempoSources(listOf(a,b))
            assertTrue(repo.preview(edit).accepted)
            assertTrue(repo.commit(edit,admission))
            val accepted=repo.state.value.document
            assertTrue(directory.listFiles()!!.single().readText().contains("\"version\":4"))
            assertEquals(accepted.tempoRamps,repo().state.value.document.tempoRamps)
            assertNull(validateNativeTempoPlan(accepted))
            val oldBytes=directory.listFiles()!!.single().readText()
            revision="r2";repo.waveform(scope,TrackId(1),20000,refresh=true,valid={true})
            assertFalse(admission())
            assertFalse(repo.commit(TimelineTempoEdit(accepted,accepted.copy(tempoRamps=accepted.tempoRamps.map {it.copy(curve=TempoCurve.SmoothTime)})),admission))
            assertEquals(oldBytes,directory.listFiles()!!.single().readText())
        } finally {directory.deleteRecursively()}
    }
    @Test fun sourceGridRevisionAndAccountAbaPermanentlyFenceCapturedEdit() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"))
        val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-repository").toFile()
        try {
            var revision="r1"
            val repo=TimelineRepository(session,directory){_,track,duration,_->TrackWaveform(track,"s-${track.value}",duration,emptyList(),phaseTiming=PhaseGrid("s-${track.value}",revision,500,0,provenance="manual_timing_v2"))}
            val sources=listOf(TimelineSource("a",1,"A",20000,QueueSegment.Manual),TimelineSource("b",2,"B",20000,QueueSegment.Manual))
            repo.observe(scope,sources)
            repo.waveform(scope,TrackId(1),20000,valid={true})
            repo.waveform(scope,TrackId(2),20000,valid={true})
            val a=TempoSourceIdentity("a",1,"s-1",20000,"r1","manual_timing_v2",120.0,0.0,1)
            val b=a.copy(occurrence="b",track=2,sourceKey="s-2")
            val capture=repo.captureTempoSources(listOf(a,b));assertTrue(capture())
            revision="r2";repo.waveform(scope,TrackId(1),20000,refresh=true,valid={true})
            assertFalse(capture())
            revision="r1";repo.waveform(scope,TrackId(1),20000,refresh=true,valid={true})
            assertFalse("Same revision text cannot revive an old qualification",capture())
            val fresh=repo.captureTempoSources(listOf(a,b));assertTrue(fresh())
            session.retire();session.accept(session.beginIntent(),SecretTokens("a2","r2","account"))
            repo.observe(session.capture()!!,sources)
            assertFalse(fresh())
        } finally {directory.deleteRecursively()}
    }
}
