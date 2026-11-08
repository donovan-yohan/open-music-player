package com.soundq.android

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
import java.util.concurrent.atomic.AtomicBoolean

/** Real mounted ProductApp → ViewModel actions → repositories → authenticated TLS.
 * Compiled here; native execution belongs to the parent integration runtime. */
class PlaylistManagementJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun mountedRenameRemovalUndoDeleteCancelAndDestructiveAckPreservePausedPlayback() {
        journey(uncertainRename=false)
    }
    @Test fun mountedUncertainRenameExposesGetOnlyRecoveryWithoutReplayingWrite() {
        journey(uncertainRename=true)
    }
    private fun journey(uncertainRename:Boolean) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val model=ViewModelProvider(compose.activity)[ProductViewModel::class.java]
        app.graph.session.retire()
        val fallback=ProductTransportFixture.server.dispatcher
        val calls=CopyOnWriteArrayList<String>()
        val members=mutableListOf(2L,1L)
        var name="Night route";var deleted=false
        val uncertain=AtomicBoolean(uncertainRename)
        fun summary():String="""{"id":41,"name":"$name","description":"Night listening","coverUrl":"https://art.example.invalid/cover","isPublic":false,"trackCount":${members.size},"durationMs":${members.size*12000}}"""
        fun detail():String=summary().dropLast(1)+",\"tracks\":["+members.joinToString(","){"""{"id":$it,"title":"Fixture $it","artist":"Synthetic ensemble","durationMs":12000}"""}+"]}"
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse=synchronized(members) {
                val path=request.url.encodedPath
                if(!path.startsWith("/api/v1/playlists"))return@synchronized fallback.dispatch(request)
                calls.add("${request.method} $path")
                fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
                when {
                    path=="/api/v1/playlists" -> reply("""{"data":[${if(deleted) "" else summary()}],"total":${if(deleted)0 else 1},"limit":20,"offset":0}""")
                    path=="/api/v1/playlists/41" && request.method=="GET" -> if(deleted)reply("{}",404) else reply(detail())
                    path=="/api/v1/playlists/41" && request.method=="PUT" -> {
                        val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                        assertEquals("Night listening",body.getValue("description").jsonPrimitive.content)
                        assertEquals("https://art.example.invalid/cover",body.getValue("coverUrl").jsonPrimitive.content)
                        assertFalse(body.getValue("isPublic").jsonPrimitive.boolean)
                        name=body.getValue("name").jsonPrimitive.content
                        if(uncertain.getAndSet(false))reply("{}",503) else reply(summary())
                    }
                    path.endsWith("/batch-remove") -> {
                        assertEquals(listOf(2L),Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("trackIds").jsonArray.map {it.jsonPrimitive.long})
                        members.remove(2L);reply(detail())
                    }
                    path.endsWith("/tracks") && request.method=="POST" -> {
                        assertEquals(listOf(2L),Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("trackIds").jsonArray.map {it.jsonPrimitive.long})
                        members.add(2L);reply("""{"added":[2],"skipped":[],"playlist":${summary()}}""")
                    }
                    path.endsWith("/reorder") -> {
                        val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                        assertEquals(2L,body.getValue("trackId").jsonPrimitive.long);assertEquals(0,body.getValue("newPosition").jsonPrimitive.int)
                        members.remove(2L);members.add(0,2L);reply(detail())
                    }
                    request.method=="DELETE" && path=="/api/v1/playlists/41" -> {deleted=true;reply("",204)}
                    else -> reply("{}",400)
                }
            }
        }
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("playlist@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.session.capture()!=null&&app.graph.library.state.value.rows.isNotEmpty()}
            // Establish actual Media3 queue positively before preserving its paused identity.
            compose.onNode(hasText("Fixture 1") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(5000){!model.playback.value.isPlaying}
            val settlement=compose.settledPausedPlayback(model)
            val paused=settlement.projection
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000){app.graph.playlists.state.value.rows.size==1}
            compose.onNode(hasText("Night route") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.playlistDetail.state.value.detail!=null}
            compose.onNodeWithContentDescription("Playlist actions").performScrollTo().performClick()
            compose.onNode(hasText("Rename playlist") and hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Playlist name").performTextReplacement("海辺 — renamed")
            compose.onNodeWithText("Save changes").performScrollTo().performClick()
            if(uncertainRename) {
                compose.waitUntil(10000){app.graph.playlistManagement.state.value.outcome==MutationOutcome.Uncertain}
                compose.onNode(hasText("Reload playlist state") and hasAnyAncestor(isDialog())).performScrollTo().performClick()
                compose.waitUntil(10000){app.graph.playlistManagement.state.value.reconciled}
                assertEquals(1,calls.count {it=="PUT /api/v1/playlists/41"})
            } else compose.waitUntil(10000){app.graph.playlistManagement.state.value.outcome==MutationOutcome.Confirmed}
            compose.waitUntil(5000){compose.onAllNodesWithText("Save changes").fetchSemanticsNodes().isEmpty()}
            assertEquals("海辺 — renamed",app.graph.playlistDetail.state.value.detail!!.playlist.name)
            if(!uncertainRename) {
                compose.onNodeWithContentDescription("More for Fixture 2").performScrollTo().performClick()
                compose.onNode(hasText("Remove from playlist") and hasClickAction()).performClick()
                compose.waitUntil(10000){app.graph.playlistManagement.state.value.undo!=null}
                assertEquals(listOf(1L),app.graph.playlistDetail.state.value.detail!!.tracks.map {it.id.value})
                compose.onNodeWithText("Undo removal").performScrollTo().performClick()
                compose.waitUntil(10000){app.graph.playlistManagement.state.value.undo==null&&app.graph.playlistManagement.state.value.outcome==MutationOutcome.Confirmed}
                assertEquals(listOf(2L,1L),app.graph.playlistDetail.state.value.detail!!.tracks.map {it.id.value})
                compose.onNodeWithContentDescription("Playlist actions").performScrollTo().performClick()
                compose.onNode(hasText("Delete playlist") and hasClickAction()).performClick()
                compose.onNodeWithText("Cancel").performScrollTo().performClick()
                assertEquals(0,calls.count {it.startsWith("DELETE")})
                compose.onNodeWithContentDescription("Playlist actions").performScrollTo().performClick()
                compose.onNode(hasText("Delete playlist") and hasClickAction()).performClick()
                compose.onNode(hasText("Delete playlist") and hasClickAction()).performScrollTo().performClick()
                compose.waitUntil(10000){app.graph.playlistDetail.state.value.id==null&&app.graph.playlistManagement.state.value.missing}
                compose.onNodeWithText("Playlist deleted").performScrollTo().assertIsDisplayed()
                assertEquals(1,calls.count {it=="DELETE /api/v1/playlists/41"})
            }
            val after=model.playback.value
            assertEquals(paused.queue,after.queue);assertEquals(paused.selectedOccurrence,after.selectedOccurrence)
            assertFalse(after.isPlaying);assertEquals(paused.positionMs,after.positionMs)
            compose.runOnIdle {assertActualPausedUnchanged(settlement)}
        } finally {
            ProductTransportFixture.server.dispatcher=fallback
            app.graph.playlistManagement.retire();app.graph.playlistDetail.retire();app.graph.session.retire()
        }
    }
}
