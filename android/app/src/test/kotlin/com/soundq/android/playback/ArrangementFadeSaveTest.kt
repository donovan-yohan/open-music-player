package com.soundq.android.playback

import com.soundq.android.data.*
import com.soundq.android.data.mix.*
import com.soundq.android.data.timeline.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class ArrangementFadeSaveTest {
    @Test fun acceptedFadePostAndGetAreExactAndDroppedFadeReadbackNeverUnblocks() {
        HttpsFixture().use {f->
            val s=AccountSession(f.endpoint,MemoryStore());s.accept(s.beginIntent(),SecretTokens("a","r","fixture"));val scope=s.capture()!!
            val dir=Files.createTempDirectory("fade-save-").toFile()
            try {
                val r=TimelineRepository(s,dir){_,_,_,_->error("No waveform")}
                r.observe(scope,listOf("out","in").map {TimelineSource(it,7,"Duplicate",10000,QueueSegment.Context)})
                var d=r.state.value.document;assertTrue(r.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,8000)){true})
                d=r.state.value.document;assertTrue(r.commit(TimelineFadeEdit(d.revision,d.clips[0],d.clips[1],2000)){true});d=r.state.value.document
                val plan=d.arrangementPlan();val save=ArrangementSave(SoundQApi(s,f.client),r)
                fun response(clips:List<MixClip>)=buildJsonObject {
                    put("id",plan.id);put("schemaVersion",1);put("name",plan.name);put("version",1);put("clips",JsonArray(clips.map {it.json}))
                    put("summary",buildJsonObject {put("clipCount",2);put("trackIds",JsonArray(listOf(JsonPrimitive(7))));put("durationMs",plan.duration)})
                    put("createdAt","2026-01-01T00:00:00Z");put("updatedAt","2026-01-01T00:00:00Z")
                }.toString()
                f.reply(response(plan.clips),201);f.reply(response(plan.clips))
                save.save(scope,d,plan.name){true}!!.invoke()
                val post=f.server.takeRequest();assertEquals("POST",post.method)
                val submitted=Json.parseToJsonElement(post.body!!.utf8()).jsonObject
                assertEquals(1L,submitted.getValue("schemaVersion").jsonPrimitive.long)
                assertEquals(JsonArray(plan.clips.map {it.json}),submitted.getValue("clips"))
                assertEquals("GET",f.server.takeRequest().method)
                assertFalse(save.state.value.blocked);assertTrue(d.matchesArrangement(save.state.value.saved!!))
                val dropped=plan.clips.map {MixJson.clip(JsonObject(it.json.filterKeys {k->k!="fadeInMs"&&k!="fadeOutMs"}))}
                assertFalse(d.matchesArrangement(plan.copy(clips=dropped)))
                f.reply(response(dropped));save.readback(scope,plan.id,d){true}!!.invoke()
                assertTrue(save.state.value.message!!.startsWith("GET did not confirm"))
                val altered=plan.clips.map {if(it.occurrence=="in")MixJson.clip(JsonObject(it.json+("fadeInMs" to JsonPrimitive(1999))))else it}
                assertFalse(d.matchesArrangement(plan.copy(clips=altered)))
            } finally {dir.deleteRecursively()}
        }
    }
}
