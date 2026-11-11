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

/** Production MainActivity/shell, mounted controls and authenticated TLS owners.
 * Compiled in this lane. Execute only under the integration owner's runtime grant. */
class PlaylistOrdinaryManagementJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun capture(name:String){compose.waitForIdle();captureListeningStage(name)}
    @Test fun mountedCompleteMetadataVisibilityAndConfirmedMultiSelection()=journey(false,false)
    @Test fun mountedChooserCreatesAndAddsToExactReturnedId()=journey(true,false)
    @Test fun mountedUnknownCreateBrowsesAndSelectsExactPlaylistWithoutRecreating()=journey(true,true)
    private fun journey(chooser:Boolean,lostAck:Boolean) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val model=ViewModelProvider(compose.activity)[ProductViewModel::class.java]
        app.graph.session.retire()
        val fallback=ProductTransportFixture.server.dispatcher
        val calls=CopyOnWriteArrayList<String>()
        var name="Ordinary playlist";var description="Before";var cover="";var public=true
        var created=false
        val members=mutableListOf(1L,2L,3L)
        fun summary(id:Long)=buildJsonObject {
            put("id",id);put("name",name);put("description",description);put("coverUrl",cover);put("isPublic",public)
            put("trackCount",members.size);put("durationMs",members.size*12000)
        }
        fun detail(id:Long)=JsonObject(summary(id)+mapOf("canManage" to JsonPrimitive(true),"tracks" to buildJsonArray {
            members.forEach {id->add(buildJsonObject {put("id",id);put("title","Fixture $id");put("artist","Synthetic ensemble");put("durationMs",12000)})}
        }))
        ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse=synchronized(members) {
            val path=request.url.encodedPath
            if(!path.startsWith("/api/v1/playlists"))return@synchronized fallback.dispatch(request)
            calls.add("${request.method} $path")
            fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
            val id=if(chooser)73L else 41L
            when {
                path=="/api/v1/playlists"&&request.method=="POST"->{
                    val draft=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                    name=draft.getValue("name").jsonPrimitive.content;description=draft.getValue("description").jsonPrimitive.content
                    cover=draft.getValue("coverUrl").jsonPrimitive.content;public=draft.getValue("isPublic").jsonPrimitive.boolean
                    created=true;members.clear();reply(if(lostAck)"{}" else summary(id).toString(),if(lostAck)503 else 201)
                }
                path=="/api/v1/playlists"->reply(buildJsonObject {put("data",buildJsonArray {if(!chooser||created)add(summary(id))});put("total",if(!chooser||created)1 else 0);put("limit",20);put("offset",0)}.toString())
                request.method=="GET"&&path=="/api/v1/playlists/$id"->reply(detail(id).toString())
                request.method=="PUT"&&path=="/api/v1/playlists/$id"->{
                    val draft=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                    name=draft.getValue("name").jsonPrimitive.content;description=draft.getValue("description").jsonPrimitive.content
                    cover=draft.getValue("coverUrl").jsonPrimitive.content;public=draft.getValue("isPublic").jsonPrimitive.boolean
                    reply(summary(id).toString())
                }
                path.endsWith("/batch-remove")->{
                    val ids=Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("trackIds").jsonArray.map {it.jsonPrimitive.long}
                    assertEquals(listOf(1L,2L),ids);members.removeAll(ids.toSet());reply(detail(id).toString())
                }
                request.method=="POST"&&path=="/api/v1/playlists/$id/tracks"->{
                    assertEquals("{\"trackIds\":[1]}",request.body!!.utf8());members.add(1L)
                    reply("""{"added":[1],"skipped":[],"playlist":${summary(id)}}""")
                }
                else->reply("{}",400)
            }
        }}
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("ordinary@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.size==3}
            val before=model.playback.value
            val library=app.graph.library.state.value
            fun click(text:String)=compose.onNode(hasText(text) and hasClickAction()).performScrollTo().performClick()
            fun sheetClick(text:String)=compose.onNode(hasText(text) and hasClickAction() and hasAnyAncestor(isDialog())).performScrollTo().performClick()
            if(chooser) {
                compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().performClick();click("Add to playlist")
                compose.waitUntil(5000){app.graph.playlistMembership.state.value.total==0}
                click("Create new playlist")
                compose.onNodeWithContentDescription("New playlist name").performScrollTo().performTextInput("Created from chooser")
                compose.onNodeWithContentDescription("New playlist description").performScrollTo().performTextInput("Chooser notes")
                capture("playlist-create-from-chooser")
                click("Create and add track")
                if(lostAck) {
                    compose.waitUntil(10000){app.graph.playlistMembership.state.value.outcome==MutationOutcome.Uncertain}
                    click("Check playlist")
                    compose.waitUntil(10000){app.graph.playlistMembership.state.value.reconciled}
                    capture("playlist-create-unknown-readback")
                    click("Choose a different playlist");click("Created from chooser");click("Add track to “Created from chooser”")
                }
                compose.waitUntil(10000){app.graph.playlistMembership.state.value.detail?.tracks?.size==1}
                assertEquals(73L,app.graph.playlistMembership.state.value.target!!.value)
                assertEquals(1,calls.count {it=="POST /api/v1/playlists"})
                assertEquals(1,calls.count {it=="POST /api/v1/playlists/73/tracks"})
                assertSame(library,app.graph.library.state.value)
                capture("playlist-exact-created-id-membership")
            } else {
                // Root navigation is outside the scrollable playlist content.
                compose.onNode(hasText("Playlists") and hasClickAction()).performClick()
                compose.waitUntil(10000){app.graph.playlists.state.value.rows.size==1};click(name)
                compose.waitUntil(10000){app.graph.playlistDetail.state.value.detail!=null}
                compose.onNodeWithContentDescription("Playlist actions").performScrollTo().performClick();click("Rename playlist")
                compose.onNodeWithContentDescription("Playlist name").performTextReplacement("Edited playlist")
                compose.onNodeWithContentDescription("Description").performScrollTo().performTextReplacement("After")
                compose.onNodeWithContentDescription("Cover URL").performScrollTo().performTextReplacement("https://art.invalid/new")
                capture("playlist-complete-metadata-form")
                click("Public playlist");click("Save changes")
                compose.waitUntil(10000){app.graph.playlistManagement.state.value.outcome==MutationOutcome.Confirmed}
                assertEquals("After",app.graph.playlistDetail.state.value.detail!!.playlist.draft.description)
                assertEquals("https://art.invalid/new",app.graph.playlistDetail.state.value.detail!!.playlist.draft.coverUrl)
                assertFalse(app.graph.playlistDetail.state.value.detail!!.playlist.draft.isPublic)
                compose.onNodeWithContentDescription("Playlist actions").performScrollTo().performClick();click("Select tracks")
                sheetClick("Fixture 1");sheetClick("Fixture 2");sheetClick("Remove selected tracks");sheetClick("Cancel")
                assertEquals(0,calls.count {it.endsWith("/batch-remove")})
                sheetClick("Remove selected tracks");capture("playlist-batch-remove-confirmation");sheetClick("Remove selected tracks")
                compose.waitUntil(10000){app.graph.playlistDetail.state.value.detail?.tracks?.size==1}
                assertEquals(listOf(3L),app.graph.playlistDetail.state.value.detail!!.tracks.map {it.id.value})
                assertEquals(1,calls.count {it.endsWith("/batch-remove")})
                capture("playlist-batch-remove-confirmed")
            }
            val after=model.playback.value
            assertEquals(before.queue,after.queue);assertEquals(before.selectedOccurrence,after.selectedOccurrence)
            assertEquals(before.positionMs,after.positionMs);assertEquals(before.isPlaying,after.isPlaying)
        } finally {ProductTransportFixture.server.dispatcher=fallback}
    }
}
