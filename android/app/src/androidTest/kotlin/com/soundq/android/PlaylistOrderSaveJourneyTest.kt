package com.soundq.android

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.MutationOutcome
import com.soundq.android.product.ProductViewModel
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Ordinary mounted ProductApp, real TLS playlist contracts and actual paused Media3 queue.
 * Compiled only in this source lane; runtime execution is parent-owned. */
class PlaylistOrderSaveJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun ordinaryMemberDragCancelCommitAndCapturedQueueSaveNeverAutoplay() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        app.graph.session.retire()
        val fallback=ProductTransportFixture.server.dispatcher
        val calls=CopyOnWriteArrayList<String>()
        val members=mutableListOf(2L,1L)
        val created=mutableListOf<Long>()
        var createdName:String?=null
        fun summary(id:Long=41):String {
            val ids=if(id==41L)members else created
            val name=if(id==41L)"Night route" else createdName!!
            return buildJsonObject {put("id",id);put("name",name);put("description","");put("coverUrl","");put("isPublic",false);put("trackCount",ids.size);put("durationMs",ids.size*12000)}.toString()
        }
        fun detail():String=summary().dropLast(1)+",\"tracks\":["+members.joinToString(","){"""{"id":$it,"title":"Fixture $it","artist":"Synthetic ensemble","durationMs":12000}"""}+"]}"
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse=synchronized(members) {
                val path=request.url.encodedPath
                if(!path.startsWith("/api/v1/playlists"))return@synchronized fallback.dispatch(request)
                calls.add("${request.method} $path")
                fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
                when {
                    path=="/api/v1/playlists"&&request.method=="GET"->reply("""{"data":[${summary()}],"total":1,"limit":20,"offset":0}""")
                    path=="/api/v1/playlists"&&request.method=="POST"->{
                        val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                        assertFalse(body.getValue("isPublic").jsonPrimitive.boolean)
                        createdName=body.getValue("name").jsonPrimitive.content
                        reply(summary(42),201)
                    }
                    path=="/api/v1/playlists/41"&&request.method=="GET"->reply(detail())
                    path.endsWith("/reorder")-> {
                        val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                        assertEquals(2L,body.getValue("trackId").jsonPrimitive.long)
                        assertEquals(1,body.getValue("newPosition").jsonPrimitive.int)
                        members.remove(2L);members.add(1,2L);reply(detail())
                    }
                    path.endsWith("/tracks")&&request.method=="POST"->{
                        val ids=Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("trackIds").jsonArray.map {it.jsonPrimitive.long}
                        assertEquals(listOf(1L,1L,2L,3L),ids)
                        val target=if(path.contains("/42/"))created else members
                        val skipped=mutableListOf<Long>();val added=mutableListOf<Long>()
                        ids.forEach {id->if(id in target)skipped.add(id) else {target.add(id);added.add(id)}}
                        reply(buildJsonObject {put("added",buildJsonArray {added.forEach {add(it)}});put("skipped",buildJsonArray {skipped.forEach {add(it)}});put("playlist",Json.parseToJsonElement(summary(if(target===created)42 else 41)))}.toString())
                    }
                    else->reply("{}",400)
                }
            }
        }
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("playlist-order@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.session.capture()!=null&&app.graph.library.state.value.rows.size>=3}
            compose.onNode(hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))).performScrollTo().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(5000){!model.playback.value.isPlaying}
            compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().performClick()
            compose.onNodeWithText("Add to listening queue").performScrollTo().performClick()
            compose.waitUntil(5000){model.playback.value.queue.count {it.trackId==1L}==2}
            val settlement=compose.settledPausedPlayback(model)
            val paused=settlement.projection
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000){app.graph.playlists.state.value.rows.size==1}
            compose.onNode(hasText("Night route") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.playlistDetail.state.value.detail!=null}
            val grip=compose.onNodeWithContentDescription("Reorder Fixture 2")
            grip.performScrollTo()
            val from=grip.fetchSemanticsNode().boundsInRoot
            val to=compose.onNodeWithContentDescription("Reorder Fixture 1").fetchSemanticsNode().boundsInRoot
            compose.mainClock.autoAdvance=false
            grip.performTouchInput {down(center);moveBy(Offset(0f,to.center.y-from.center.y+to.height/2))}
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            grip.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Moving to position 2"))
            assertEquals(0,calls.count {it.startsWith("PUT")})
            grip.performTouchInput {cancel(delayMillis=0)}
            compose.mainClock.advanceTimeBy(1000);compose.mainClock.autoAdvance=true
            assertEquals(listOf(2L,1L),app.graph.playlistDetail.state.value.detail!!.tracks.map {it.id.value})
            assertEquals(0,calls.count {it.startsWith("PUT")})
            grip.performTouchInput {down(center);moveBy(Offset(0f,to.center.y-from.center.y+to.height/2));up()}
            compose.waitUntil(10000){app.graph.playlistOrder.state.value.outcome==MutationOutcome.Confirmed}
            assertEquals(listOf(1L,2L),app.graph.playlistDetail.state.value.detail!!.tracks.map {it.id.value})
            assertEquals(1,calls.count {it.startsWith("PUT")})
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithContentDescription("Queue actions").assertIsDisplayed().assertIsEnabled().performClick()
            compose.onNodeWithText("Save queue as playlist").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.queuePlaylist.state.value.total==1&&!app.graph.queuePlaylist.state.value.loading}
            compose.onNode(hasText("Night route") and hasClickAction()).performScrollTo().performClick()
            compose.onNodeWithText("Save to “Night route”").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.queuePlaylist.state.value.outcome==MutationOutcome.Confirmed}
            assertEquals(listOf(3L),app.graph.queuePlaylist.state.value.ack!!.added.map {it.value})
            assertEquals(listOf(1L,1L,2L),app.graph.queuePlaylist.state.value.ack!!.skipped.map {it.value})
            assertEquals(1,app.graph.queuePlaylist.state.value.snapshot!!.duplicateOccurrences)
            compose.onNodeWithText("Start a new queue save").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.queuePlaylist.state.value.outcome==null&&!app.graph.queuePlaylist.state.value.loading}
            compose.onNodeWithContentDescription("Playlist name").performScrollTo().performTextInput("Captured queue")
            compose.onNodeWithText("Create playlist and save queue").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.queuePlaylist.state.value.outcome==MutationOutcome.Confirmed}
            assertEquals(listOf(1L,2L,3L),created)
            assertEquals(1,calls.count {it=="POST /api/v1/playlists"})
            assertEquals(2,calls.count {it.endsWith("/tracks")})
            val after=compose.runOnIdle {model.playback.value}
            assertEquals(paused.queue,after.queue);assertEquals(paused.selectedOccurrence,after.selectedOccurrence)
            assertEquals(paused.positionMs,after.positionMs);assertFalse(after.isPlaying)
            compose.runOnIdle {assertActualPausedUnchanged(settlement)}
        } finally {
            compose.mainClock.autoAdvance=true
            ProductTransportFixture.server.dispatcher=fallback
            app.graph.playlistOrder.retire();app.graph.queuePlaylist.retire();app.graph.playlistDetail.retire();app.graph.session.retire()
        }
    }
}
