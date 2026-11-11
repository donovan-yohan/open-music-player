package com.soundq.android.playback

import com.soundq.android.data.*
import com.soundq.android.data.mix.MixJson
import com.soundq.android.data.timeline.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class ArrangementBoundaryTest {
    private fun document()=TimelineDocument(4,sequentialTimeline(listOf("a","b").map {TimelineSource(it,7,"Duplicate",2000,QueueSegment.Context)}).mapIndexed {i,c->c.copy(sourceInMs=250L*i,sourceOutMs=1500,globalStartMs=500L*i)})
    @Test fun sourcePositionsUseActualGlobalClockAndStrictReadbackPreservesOccurrenceIdentity() {
        val d=document();val p=d.arrangementPlan()
        val a=AcceptedArrangement(ArrangementIdentity("service",1,"queue",4,"install"),d,emptyList())
        assertEquals(mapOf("a" to 750L,"b" to 500L),a.sourcePositions(750))
        assertEquals(mapOf("b" to 1250L),a.sourcePositions(1500))
        assertTrue(d.matchesArrangement(p))
        val withGain=MixJson.clip(JsonObject(p.clips[0].json+("gainDb" to JsonPrimitive(-3))))
        assertFalse(d.matchesArrangement(p.copy(clips=listOf(withGain)+p.clips.drop(1))))
    }
    @Test fun serviceSnapshotOverrideCannotBecomeAnEmptyOrTrackZeroObserverDocument() {
        val d=document();val sources=d.clips.map {QueueOccurrence(it.occurrence,it.track,it.title,"",false,it.sourceDurationMs)}
        val accepted=AcceptedArrangement(ArrangementIdentity("service",1,"queue",4,"install"),d,sources)
        val p=PlaybackProjection(PlaybackProjection.Connection.Connected,queue=listOf(QueueOccurrence("mix",0,"Mix","",false)),source=PlaybackSource.Arrangement,arrangement=accepted)
        assertEquals(listOf("a","b"),p.timelineSources()!!.map {it.occurrence})
        assertNull(p.copy(source=PlaybackSource.SavedMix,arrangement=null).timelineSources())
        assertNull(PlaybackProjection().timelineSources())
    }
    @Test fun actualSaveAndGetKeepDuplicateSourceTrimsPlacementAndDoNotRepeatFailedCreate() {
        HttpsFixture().use {f ->
            val s=AccountSession(f.endpoint,MemoryStore());s.accept(s.beginIntent(),SecretTokens("a","r","fixture"));val scope=s.capture()!!
            val api=SoundQApi(s,f.client);val d=document();val p=d.arrangementPlan("Arrangement")
            val response=buildJsonObject {
                put("id",p.id);put("version",1);put("schemaVersion",1);put("name",p.name);put("clips",JsonArray(p.clips.map {it.json}))
                put("summary",buildJsonObject {put("clipCount",2);put("trackIds",JsonArray(listOf(JsonPrimitive(7))));put("durationMs",p.duration)})
                put("createdAt","2026-01-01T00:00:00Z");put("updatedAt","2026-01-01T00:00:00Z")
            }.toString()
            f.reply(response,201);f.reply(response)
            val saved=api.saveMix(scope,null,p.name,p.clips){true}
            assertTrue(d.matchesArrangement(saved));assertEquals(listOf("a","b"),saved.clips.map {it.occurrence})
            assertEquals("POST",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method);assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
            f.reply(response);assertEquals(saved,api.mixPlan(scope,p.id){true});assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
        }
    }
}
