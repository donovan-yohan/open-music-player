package com.soundq.android

import android.view.KeyEvent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/** Parent gate: actual ProductApp, retained qualified MP3 transport, meaningful paused queue. */
class CatalogMembershipJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun storedAddReadbackBackPreservesPausedQueue() = journey(false)
    @Test fun lostAckFreshOwnerAndJournalRecoveryNeverRepostsOrAutoplays() = journey(true)
    private fun journey(lost:Boolean) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val model=ViewModelProvider(compose.activity)[ProductViewModel::class.java]
        app.graph.session.retire()
        val audio=InstrumentationRegistry.getInstrumentation().context.assets.open("performance/track-1.mp3").use {it.readBytes()}
        val fallback=ProductTransportFixture.server.dispatcher
        val calls=CopyOnWriteArrayList<String>();val lookups=AtomicInteger();val posts=AtomicInteger()
        val member=java.util.concurrent.atomic.AtomicBoolean(false)
        val journal=java.io.File(app.graph.directory,"catalog-membership.v1.json")
        // This selector owns its synthetic target journal and clears it only before/after the test.
        journal.delete()
        val account="123e4567-e89b-12d3-a456-426614174001"
        val edition="123e4567-e89b-12d3-a456-426614174003"
        val recording="123e4567-e89b-12d3-a456-426614174004"
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(path.startsWith("/api/v1/"))calls.add("${request.method} $path")
                fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
                return when(path) {
                    "/api/v1/playback/urls"->{
                        val ids=org.json.JSONObject(request.body!!.utf8()).getJSONArray("trackIds")
                        val urls=(0 until ids.length()).joinToString(",") {index->val id=ids.getLong(index);"""{"trackId":$id,"url":"${ProductTransportFixture.origin.resolve("/media/catalog-qualified.mp3")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/mpeg","sizeBytes":${audio.size}}"""}
                        reply("""{"urls":[$urls]}""")
                    }
                    "/media/catalog-qualified.mp3"->{
                        check(request.headers["Authorization"]==null)
                        val start=request.headers["Range"]?.substringAfter("bytes=")?.substringBefore('-')?.toIntOrNull() ?: 0
                        val response=MockResponse.Builder().code(if(start>0)206 else 200).addHeader("Content-Type","audio/mpeg").addHeader("Accept-Ranges","bytes")
                        if(start>0)response.addHeader("Content-Range","bytes $start-${audio.size-1}/${audio.size}")
                        response.body(okio.Buffer().write(audio.copyOfRange(start.coerceIn(0,audio.size),audio.size))).build()
                    }
                    "/api/v1/auth/login"->reply("""{"accessToken":"synthetic-fixture-access","refreshToken":"synthetic-fixture-refresh","user":{"id":"$account"}}""")
                    "/api/v1/search/releases"->reply("""{"data":[{"id":8,"name":"Concrete album","mbReleaseId":"$edition","trackCount":24}],"total":1,"offset":0,"limit":20}""")
                    "/api/v1/albums/$edition"->{val tracks=(1..24).joinToString(","){"""{"id":"$recording","title":"Recording position $it","artist":"Catalog artist","position":$it,"inLibrary":false,"downloadable":false}"""};reply("""{"id":"$edition","title":"Concrete album","trackCount":24,"tracks":[$tracks]}""")}
                    "/api/v1/catalog/recordings/$recording/resolution"->{
                        assertEquals("GET",request.method);assertEquals("Bearer synthetic-fixture-access",request.headers["Authorization"])
                        lookups.incrementAndGet()
                        reply("""{"recordingMbid":"$recording","userId":"$account","status":"${if(member.get())"owned" else "stored_unowned"}","candidates":[{"trackId":7,"mbVerified":true,"inLibrary":${member.get()}}],"limit":20,"truncated":false}""")
                    }
                    "/api/v1/catalog/recordings/$recording/membership"->{
                        assertEquals("POST",request.method);assertEquals("{\"trackId\":7}",request.body!!.utf8());assertEquals("Bearer synthetic-fixture-access",request.headers["Authorization"])
                        posts.incrementAndGet();member.set(true)
                        if(lost)MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()
                        else reply("""{"recordingMbid":"$recording","userId":"$account","trackId":7,"status":"member","addedAt":"2026-11-06T02:56:02Z"}""")
                    }
                    "/api/v1/library"->if(member.get()&&request.url.queryParameter("fields")?.contains("mb_recording_id")==true)
                        reply("""{"tracks":[{"id":7,"title":"Stored recording","artist":"Catalog artist","album":"Concrete album","duration_ms":0,"is_liked":false,"has_metadata_override":false,"mb_verified":true,"mb_recording_id":"$recording"}],"total":1,"limit":100,"offset":0}""")
                        else fallback.dispatch(request)
                    else->fallback.dispatch(request)
                }
            }
        }
        fun back() {InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);compose.waitForIdle()}
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("catalog@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            val tracks=app.graph.library.state.value.rows
            compose.runOnIdle {app.graph.rememberTracks(tracks);model.controller.playContext(tracks,0)}
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(5000){!model.playback.value.isPlaying}
            val settled=compose.settledPausedPlayback(model);val paused=settled.projection
            kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO){app.graph.presence.disconnect()}
            val writes=calls.count {it.startsWith("POST")||it.startsWith("PUT")||it.startsWith("DELETE")||it.startsWith("PATCH")}
            compose.onNodeWithContentDescription("Library options").performClick()
            compose.onNodeWithText("Catalog").performClick()
            compose.onNodeWithText("Albums on server").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Search catalog").performTextInput("Concrete")
            println("CATALOG_QUERY_BEFORE ${app.graph.catalog.state.value} calls=$calls")
            compose.onNodeWithContentDescription("Submit catalog search").performScrollTo().performClick()
            try {compose.waitUntil(10000){app.graph.catalog.state.value.albums!=null}} catch(error:Throwable) {
                println("CATALOG_QUERY_FAILURE ${app.graph.catalog.state.value} calls=$calls")
                captureListeningStage("catalog-search-failure")
                throw error
            }
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Concrete album"))
            compose.onNodeWithText("Concrete album").performClick()
            compose.waitUntil(10000){app.graph.catalog.state.value.album!=null}
            val album=app.graph.catalog.state.value.album
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Recording position 24"))
            compose.onNodeWithText("Recording position 24").performClick()
            captureListeningStage("catalog-recording-opened")
            try {compose.waitUntil(10000){compose.onAllNodesWithText("Add to Library").fetchSemanticsNodes().isNotEmpty()}}
            catch(error:Throwable){captureListeningStage("catalog-membership-add-unavailable");throw error}
            compose.onNodeWithText("Add to Library").performScrollTo().assertHeightIsAtLeast(48.dp).performClick()
            if(lost) {
                compose.waitUntil(10000){app.graph.catalog.state.value.inspection?.membership=="Unconfirmed"}
                compose.onNodeWithText("Unconfirmed").assertIsDisplayed()
                captureListeningStage("catalog-membership-unconfirmed")
                assertTrue(member.get());assertEquals(1,posts.get())
                // Fresh disk store and accepted account owner. Does not use process-local epochs.
                val recoveredSession=com.soundq.android.data.AccountSession(app.graph.endpoint,MembershipSessionStore())
                recoveredSession.accept(recoveredSession.beginIntent(),com.soundq.android.data.SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh",account))
                val fresh=com.soundq.android.data.catalog.CatalogRepository(com.soundq.android.data.SoundQApi(recoveredSession),com.soundq.android.data.catalog.CatalogMembershipJournal(journal))
                val recovered=com.soundq.android.data.catalog.CatalogActions(fresh){it()}
                assertEquals(1,fresh.state.value.recoveries.size);recovered.close()
                back();back();back() // dismiss, edition history, leave Catalog
                compose.onNodeWithContentDescription("Library options").performClick();compose.onNodeWithText("Catalog").performClick()
                compose.waitUntil(5000){app.graph.catalog.state.value.recoveries.size==1}
                compose.onNodeWithText("Check Library").performScrollTo().assertHeightIsAtLeast(48.dp)
                captureListeningStage("catalog-membership-recovery-pending")
                compose.onNodeWithText("Check Library").performClick()
                compose.waitUntil(10000){app.graph.catalog.state.value.recoveries.isEmpty()}
                compose.onNodeWithText("In your Library").assertIsDisplayed()
                captureListeningStage("catalog-membership-recovered")
                assertEquals(1,posts.get())
            } else {
                compose.waitUntil(10000){app.graph.catalog.state.value.inspection?.membership=="Added"}
                compose.onNodeWithText("Added").assertIsDisplayed()
                captureListeningStage("catalog-membership-added")
                compose.onNodeWithText("Track 24").assertExists();compose.onNodeWithText("Duration unavailable").assertExists()
                back();assertSame(album,app.graph.catalog.state.value.album)
                compose.onNodeWithText("Recording position 24").assertIsDisplayed()
                captureListeningStage("catalog-membership-edition-return")
                back();compose.waitUntil(5000){app.graph.catalog.state.value.album==null};assertNotNull(app.graph.catalog.state.value.albums)
            }
            assertEquals(2,lookups.get());assertEquals(1,posts.get())
            assertEquals("Unexpected mutation routes: $calls",writes+1,calls.count {it.startsWith("POST")||it.startsWith("PUT")||it.startsWith("DELETE")||it.startsWith("PATCH")})
            assertEquals(paused.queue,model.playback.value.queue);assertEquals(paused.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertEquals(paused.positionMs,model.playback.value.positionMs);assertFalse(model.playback.value.isPlaying)
            compose.runOnIdle {assertActualPausedUnchanged(settled)}
        } finally {ProductTransportFixture.server.dispatcher=fallback;app.graph.catalog.retire();app.graph.session.retire();journal.delete()}
    }
}

/** Private synthetic accepted-account store. No production credential path. */
private class MembershipSessionStore:com.soundq.android.data.SessionStore {
    private var saved:com.soundq.android.data.SecretTokens?=null
    override fun load(endpoint:com.soundq.android.data.ApiEndpoint)=saved
    override fun save(endpoint:com.soundq.android.data.ApiEndpoint,tokens:com.soundq.android.data.SecretTokens){saved=tokens}
    override fun clear(){saved=null}
}
