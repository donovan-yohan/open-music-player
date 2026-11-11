package com.soundq.android.playback

import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class ArrangementSaveTest {
    @Test fun uncertainCreateStaysBlockedAcrossRouteReentryAndOnlyExactGetCanRecover() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"));val scope=session.capture()!!
            val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"arrangement-save-").toFile()
            val timeline=TimelineRepository(session,dir){_,_,_,_->error("no analysis")}
            timeline.observe(scope,listOf(TimelineSource("a",7,"Duplicate",2000,QueueSegment.Context),TimelineSource("b",7,"Duplicate",2000,QueueSegment.Context)))
            val d=timeline.state.value.document;val p=d.arrangementPlan()
            val save=ArrangementSave(SoundQApi(session,f.client),timeline)
            f.reply("{}",503)
            val pending=save.save(scope,d,"Arrangement"){true}!!
            pending.invoke();pending.invoke()
            assertTrue(save.state.value.blocked);assertFalse(save.state.value.busy);assertEquals(1,f.server.requestCount)
            save.enter(scope);assertNull(save.save(scope,d,"Arrangement"){true});assertEquals(1,f.server.requestCount)
            val response=buildJsonObject {
                put("id",p.id);put("version",1);put("schemaVersion",1);put("name",p.name);put("clips",JsonArray(p.clips.map {it.json}))
                put("summary",buildJsonObject {put("clipCount",2);put("trackIds",JsonArray(listOf(JsonPrimitive(7))));put("durationMs",p.duration)})
                put("createdAt","2026-01-01T00:00:00Z");put("updatedAt","2026-01-01T00:00:00Z")
            }.toString()
            f.reply(response)
            save.readback(scope,p.id,d){true}!!.invoke()
            assertFalse(save.state.value.blocked);assertTrue(d.matchesArrangement(save.state.value.saved!!));assertEquals(2,f.server.requestCount)
            assertEquals("POST",f.server.takeRequest()!!.method);assertEquals("GET",f.server.takeRequest()!!.method)
            dir.deleteRecursively()
        }
    }
    @Test fun staleQueuedSaveDoesNotDispatchAndSameContentAccountAbaCannotAdopt() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"));val scope=session.capture()!!
            val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"arrangement-save-").toFile()
            val timeline=TimelineRepository(session,dir){_,_,_,_->error("no analysis")};timeline.observe(scope,listOf(TimelineSource("a",7,"Fixture",2000,QueueSegment.Context)))
            val save=ArrangementSave(SoundQApi(session,f.client),timeline);val d=timeline.state.value.document
            var live=true;val work=save.save(scope,d,"Arrangement"){live}!!;live=false;work()
            assertEquals(0,f.server.requestCount);assertTrue(save.state.value.blocked)
            session.accept(session.beginIntent(),SecretTokens("a","r","fixture"));save.enter(session.capture()!!)
            assertNull(save.state.value.saved);assertFalse(save.state.value.blocked)
            dir.deleteRecursively()
        }
    }
}
