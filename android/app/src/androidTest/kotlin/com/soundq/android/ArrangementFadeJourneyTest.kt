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
class ArrangementFadeJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun mountedExplicitOccurrenceFadePreviewCancelAcceptUndoApplyAndSaveKeepsExactReadback() {
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
            edit(0,EditKind.TrimIn,1000);edit(0,EditKind.TrimOut,6000);edit(1,EditKind.Placement,2000);edit(1,EditKind.TrimOut,5000)
            val beforeFade=model.timeline.value.document
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Edit stacked waveforms").performScrollTo().performClick()
            compose.onNodeWithText("Outgoing occurrence").performScrollTo().performClick()
            compose.onNodeWithText("1 · ${occurrences[0]} · ${track.title}").performClick()
            compose.onNodeWithText("Incoming occurrence").performScrollTo().performClick()
            compose.onNodeWithText("2 · ${occurrences[1]} · ${track.title}").performClick()
            compose.onNodeWithText("Use full overlap").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Preview crossfade").performScrollTo().performClick()
            compose.onNodeWithText("Preview · 2000–5000 ms · 3000 ms").assertExists()
            assertEquals(beforeFade,model.timeline.value.document)
            compose.onNodeWithContentDescription("Cancel crossfade preview").performClick()
            assertEquals(beforeFade,model.timeline.value.document)
            compose.onNodeWithContentDescription("Preview crossfade").performClick()
            compose.onNodeWithContentDescription("Accept crossfade").performClick()
            compose.waitUntil(10000){model.timeline.value.document.clips[0].fadeOutMs==3000L}
            compose.onNodeWithContentDescription("Undo crossfade edit").performScrollTo().performClick()
            compose.waitUntil(10000){model.timeline.value.document.clips[0].fadeOutMs==0L}
            compose.onNodeWithContentDescription("Preview crossfade").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Accept crossfade").performClick()
            compose.waitUntil(10000){model.timeline.value.document.clips[0].fadeOutMs==3000L}
            val accepted=model.timeline.value.document
            assertEquals(3000L,accepted.clips[1].fadeInMs)
            assertEquals(beforeFade.clips.map {it.sourceInMs to it.sourceOutMs},accepted.clips.map {it.sourceInMs to it.sourceOutMs})
            compose.onNodeWithText("Apply and audition mixed arrangement").performScrollTo().performClick()
            compose.waitUntil(15000){model.playback.value.arrangement?.document==accepted&&model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            assertEquals(occurrences,model.playback.value.queue.map {it.occurrenceId});assertEquals(accepted,model.timeline.value.document)
            val identity=model.playback.value.arrangement!!.identity
            compose.runOnIdle {model.controller.seekArrangement(identity,3000)}
            compose.waitUntil(10000){!model.playback.value.isPlaying&&model.playback.value.positionMs in 2950..3050}
            assertEquals(mapOf(occurrences[0] to 4000L,occurrences[1] to 1000L),model.playback.value.arrangement!!.sourcePositions(model.playback.value.positionMs))
            compose.onNodeWithText("Save arrangement").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.arrangementSave.state.value.saved?.id==id&&!app.graph.arrangementSave.state.value.busy}
            assertEquals(listOf("POST /api/v1/mix-plans","GET /api/v1/mix-plans/$id"),writes.toList())
            assertTrue(accepted.matchesArrangement(app.graph.arrangementSave.state.value.saved!!))
            compose.onNodeWithText("Return to source queue (paused)").performScrollTo().performClick()
            compose.waitUntil(10000){model.playback.value.source==PlaybackSource.Queue&&model.playback.value.queue.map {it.occurrenceId}==occurrences}
            assertFalse(model.playback.value.isPlaying);assertEquals(accepted,model.timeline.value.document)
        } finally {ProductTransportFixture.server.dispatcher=original;app.graph.session.retire()}
    }
}
