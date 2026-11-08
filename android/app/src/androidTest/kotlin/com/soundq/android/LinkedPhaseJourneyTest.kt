package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import com.soundq.android.product.ProductViewModel
import kotlinx.serialization.json.*
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Normal mounted editor/service/native journey. Compiled only in this lane. */
class LinkedPhaseJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun mountedReferenceChoicesPreviewCancelAcceptPairMoveUnlockUndoAndApplyReadback() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as SoundQApplication
        val original=ProductTransportFixture.server.dispatcher
        val opus=instrumentation.context.assets.open("arrangement.opus").use {it.readBytes()}
        val writes=CopyOnWriteArrayList<String>();var saved:JsonObject?=null
        val id="00000000-0000-4000-8000-000000000002"
        ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
            val path=r.url.encodedPath
            if(path=="/api/v1/playback/urls")return MockResponse.Builder().code(200).body("""{"urls":[{"trackId":1,"url":"${ProductTransportFixture.origin.resolve("/arrangement.opus")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/opus","sizeBytes":${opus.size}}]}""").build()
            if(path=="/arrangement.opus")return MockResponse.Builder().code(200).setHeader("Content-Type","audio/opus").body(Buffer().write(opus)).build()
            if(path.startsWith("/api/v1/mix-plans")) {
                writes+=r.method+" "+path
                if(r.method=="POST") {
                    val draft=Json.parseToJsonElement(r.body!!.utf8()).jsonObject
                    val clips=draft.getValue("clips").jsonArray
                    saved=buildJsonObject {
                        put("id",id);put("schemaVersion",1);put("name",draft.getValue("name"));put("version",1);put("clips",clips)
                        put("summary",buildJsonObject {put("clipCount",clips.size);put("trackIds",JsonArray(listOf(JsonPrimitive(1))));put("durationMs",clips.maxOf {val c=it.jsonObject;c.getValue("timelineStartMs").jsonPrimitive.long+c.getValue("sourceEndMs").jsonPrimitive.long-c.getValue("sourceStartMs").jsonPrimitive.long})})
                        put("createdAt","2026-01-01T00:00:00Z");put("updatedAt","2026-01-01T00:00:00Z")
                    }
                }
                return MockResponse.Builder().code(if(r.method=="POST")201 else 200).body(checkNotNull(saved).toString()).build()
            }
            return original.dispatch(r)
        }}
        try {
            app.graph.session.retire()
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("arrangement@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val track=app.graph.library.state.value.rows.first {it.id.value==1L}
            val scope=app.graph.session.capture()!!
            app.graph.downloads.load(scope);val ticket=app.graph.downloads.claim(scope,track){true}!!;app.graph.downloads.transfer(ticket)
            compose.runOnIdle {app.graph.rememberTracks(listOf(track));model.controller.playContext(listOf(track,track),0,true);model.controller.pause()}
            compose.waitUntil(10000){model.playback.value.queue.size==2&&model.timeline.value.document.clips.size==2}
            val occurrences=model.playback.value.queue.map {it.occurrenceId}
            fun edit(index:Int,kind:EditKind,value:Long){val d=model.timeline.value.document;assertTrue(app.graph.timeline.commit(TimelineEdit(d.revision,d.clips[index],kind,value)){true})}
            edit(0,EditKind.TrimIn,250);edit(0,EditKind.TrimOut,1500);edit(1,EditKind.TrimOut,1250)
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Edit stacked waveforms").performScrollTo().performClick()
            compose.onNodeWithText("Reference / master · choose").performScrollTo().performClick()
            compose.onNodeWithText("1 · ${track.title}").performClick()
            compose.onNodeWithText("Incoming · choose").performScrollTo().performClick()
            compose.onNodeWithText("2 · ${track.title}").performClick()
            fun input(label:String,text:String){compose.onNodeWithContentDescription(label).performScrollTo().performTextReplacement(text)}
            compose.onNodeWithText("Set manual source timing").performScrollTo().performClick()
            input("Reference BPM","120");input("Incoming BPM","120")
            input("Reference source beat anchor ms","500");input("Incoming source beat anchor ms","250")
            input("Reference absolute group origin ms (blank unknown)","0");input("Incoming absolute group origin ms (blank unknown)","250")
            input("Incoming proposed global start ms","430")
            val before=model.timeline.value.document
            compose.onNodeWithContentDescription("Preview linked placement").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Cancel linked preview").performScrollTo().performClick()
            assertEquals(before,model.timeline.value.document)
            compose.onNodeWithContentDescription("Preview linked placement").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Accept linked preview").performScrollTo().performClick()
            compose.waitUntil(10000){model.timeline.value.document.phaseLink!=null}
            assertEquals(500L,model.timeline.value.document.clips[1].globalStartMs)
            for(label in listOf("Increment 1 beats","Increment 4 beats","Increment 16 beats","Increment 32 beats"))compose.onNodeWithText(label).performScrollTo().performClick()
            input("Reference pair global start ms","1000")
            compose.onNodeWithText("Preview pair move").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Accept linked preview").performScrollTo().performClick()
            compose.waitUntil(10000){model.timeline.value.document.clips[0].globalStartMs==1000L}
            assertEquals(1500L,model.timeline.value.document.clips[1].globalStartMs)
            compose.onNodeWithText("Unlock relation").performScrollTo().performClick()
            compose.waitUntil(10000){model.timeline.value.document.phaseLink==null}
            compose.onNodeWithContentDescription("Undo linked edit").performScrollTo().performClick()
            compose.waitUntil(10000){model.timeline.value.document.phaseLink!=null}
            val accepted=model.timeline.value.document
            compose.onNodeWithText("Save arrangement").performScrollTo().performClick()
            assertTrue(writes.isEmpty())
            compose.onNodeWithText("Apply and audition mixed arrangement").performScrollTo().performClick()
            compose.waitUntil(15000){model.playback.value.arrangement?.document==accepted&&model.playback.value.isPlaying}
            assertEquals(accepted.phaseLink,model.playback.value.arrangement!!.document.phaseLink)
            assertEquals(occurrences,model.playback.value.queue.map {it.occurrenceId})
            compose.runOnIdle {model.controller.seekArrangement(model.playback.value.arrangement!!.identity,1750)}
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            compose.onNodeWithText("Return to source queue (paused)").performScrollTo().performClick()
            compose.waitUntil(10000){model.playback.value.source==PlaybackSource.Queue&&model.playback.value.queue.map {it.occurrenceId}==occurrences}
            assertFalse(model.playback.value.isPlaying);assertEquals(accepted,model.timeline.value.document)
        } finally {ProductTransportFixture.server.dispatcher=original;app.graph.session.retire()}
    }
}
