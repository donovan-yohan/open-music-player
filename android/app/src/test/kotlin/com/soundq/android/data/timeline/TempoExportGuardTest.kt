package com.soundq.android.data.timeline

import com.soundq.android.data.*
import com.soundq.android.data.mix.SavedMix
import com.soundq.android.playback.*
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

/** Executed by the host runner with an IO-refusing API boundary, not a network server. */
class TempoExportGuardTest {
    private class Store:SessionStore {
        override fun load(endpoint:ApiEndpoint):SecretTokens?=null
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
        override fun clear(){}
    }
    @Test fun serverV1ReportsUnsupportedWithoutDroppingIntentOrDispatching() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"tempo-export").toFile()
        try {
            val sources=listOf(TimelineSource("a",1,"A",20000,QueueSegment.Manual),TimelineSource("b",2,"B",20000,QueueSegment.Manual))
            val repository=TimelineRepository(session,directory){_,track,duration,_->TrackWaveform(track,"s-${track.value}",duration,emptyList(),phaseTiming=PhaseGrid("s-${track.value}","r",500,0,provenance="manual_timing_v2"))}
            repository.observe(scope,sources);sources.forEach {repository.waveform(scope,TrackId(it.track),it.durationMs,valid={true})}
            val original=repository.state.value.document
            val a=TempoSourceIdentity("a",1,"s-1",20000,"r","manual_timing_v2",120.0,0.0,1)
            val b=a.copy(occurrence="b",track=2,sourceKey="s-2")
            val intent=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,a,b,120.0,TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,16000.0,20000.0,32,8,TempoGainLaw.EqualPower)
            val next=original.copy(clips=original.clips.map {if(it.occurrence=="a")it.copy(fadeOutMs=4000) else it.copy(globalStartMs=16000,fadeInMs=4000)},tempoRamps=listOf(intent))
            assertTrue(repository.commit(TimelineTempoEdit(original,next)){true})
            val document=repository.state.value.document
            val save=ArrangementSave(SoundQApi(session),repository)
            assertNull(save.save(scope,document,"Ramp"){true})
            assertTrue(save.state.value.message!!.contains("Server mix v1 cannot store tempo ramp intent"))
            assertFalse(save.state.value.busy)
            assertEquals(listOf(intent),repository.state.value.document.tempoRamps)
        } finally {directory.deleteRecursively()}
    }
}
