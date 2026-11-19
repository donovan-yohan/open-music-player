package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/** Source-only journeys. No SDK compile or execution is claimed by composition. */
class OrdinaryReleaseRadarJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun open(app:SoundQApplication):ProductViewModel {
        compose.signInThroughSettings("ordinary-radar@example.test","fixture-only-password"){app.graph.session.state.value is AuthState.SignedIn}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.onNode(hasText("Discover") and hasClickAction() and !isHeading()).performClick()
        compose.waitUntil(10000){app.graph.discovery.radar.value.page!=null}
        return model
    }
    @Test fun ordinaryEntryFiveLocalBatchesTwentyAndNewVisitResetWithoutPlayback() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val model=open(app);val repository=app.graph.discovery
        val page=repository.radar.value.page!!
        val reads=ProductTransportFixture.requests.count {it=="GET /api/v1/me/discovery/releases"}
        val queue=model.playback.value.queue
        assertEquals(20,page.songs.size);assertEquals(5,repository.radar.value.visibleCount)
        compose.onNodeWithText("Radar fixture 06").assertDoesNotExist()
        captureListeningStage("combined-radar-first-five")
        val list=compose.onNode(hasScrollToIndexAction())
        list.performScrollToNode(hasContentDescription("View all New releases"))
        compose.onNodeWithContentDescription("View all New releases").performClick()
        list.performScrollToNode(hasText("Radar fixture 20"))
        compose.onNodeWithContentDescription("Add to Library: Radar fixture 20").assertIsDisplayed()
        val sourceRead="GET /api/v1/catalog/recordings/${page.songs.last().recording.value}/source"
        val sourceReads=ProductTransportFixture.requests.count {it==sourceRead}
        compose.onNodeWithText("Radar fixture 20").performClick()
        compose.waitUntil(10000){ProductTransportFixture.requests.count {it==sourceRead}==sourceReads+1}
        compose.onNodeWithText("Song evidence").assertDoesNotExist()
        assertSame(page,repository.radar.value.page)
        assertEquals(reads,ProductTransportFixture.requests.count {it=="GET /api/v1/me/discovery/releases"})
        compose.onNodeWithText("Load more").assertDoesNotExist()
        captureListeningStage("combined-radar-twenty")
        compose.onNode(hasText("Home") and hasClickAction() and !isHeading()).performClick()
        compose.waitUntil(10000){model.home.recent.value.rows.size==20}
        assertEquals(5,model.home.recent.value.visibleCount)
        compose.onNode(hasText("Discover") and hasClickAction() and !isHeading()).performClick()
        compose.waitUntil(10000){repository.radar.value.visibleCount==5&&repository.radar.value.page!==page}
        assertEquals(reads+1,ProductTransportFixture.requests.count {it=="GET /api/v1/me/discovery/releases"})
        assertEquals(queue,model.playback.value.queue);assertFalse(model.playback.value.isPlaying)
    }
    @Test fun ordinaryRadarRenderedActionsRetireOnAccountReplacementAndNavigation() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val model=open(app);val repository=app.graph.discovery
        val page=repository.radar.value.page!!
        val queue=model.playback.value.queue
        val scope=app.graph.session.capture()!!
        val sourcePath="GET /api/v1/catalog/recordings/${page.songs.first().recording.value}/source"
        val before=ProductTransportFixture.requests.count {it==sourcePath}
        val staleAccountAction=compose.onNodeWithText("Radar fixture 01").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsActions.OnClick].action!!
        compose.runOnIdle {
            app.graph.session.accept(app.graph.session.beginIntent(),com.soundq.android.data.SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh","fixture-account"))
            assertFalse(app.graph.session.current(scope))
            staleAccountAction()
        }
        compose.onNodeWithText("Song evidence").assertDoesNotExist()
        compose.waitUntil(10000){repository.radar.value.page!=null&&repository.radar.value.page!==page}
        val replacement=repository.radar.value.page!!
        val staleRouteAction=compose.onNodeWithText("Radar fixture 01").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsActions.OnClick].action!!
        val homeAction=compose.onNode(hasText("Home") and hasClickAction() and !isHeading()).fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsActions.OnClick].action!!
        // Hold main through root retirement and row reinvocation. Disposal cannot reject
        // this for us, and the framework's clickable node is still attached.
        compose.runOnIdle {assertTrue(homeAction());staleRouteAction()}
        compose.waitUntil(10000){model.home.recent.value.rows.size==20}
        compose.onNodeWithText("Song evidence").assertDoesNotExist()
        compose.onNode(hasText("Discover") and hasClickAction() and !isHeading()).performClick()
        compose.waitUntil(10000){repository.radar.value.page!=null&&repository.radar.value.page!==replacement}
        assertEquals(before,ProductTransportFixture.requests.count {it==sourcePath})
        compose.onNodeWithText("Radar fixture 01").assertIsDisplayed().performClick()
        compose.waitUntil(10000){ProductTransportFixture.requests.count {it==sourcePath}==before+1}
        compose.onNodeWithText("Song evidence").assertDoesNotExist()
        assertEquals(queue,model.playback.value.queue);assertFalse(model.playback.value.isPlaying)
        assertNull(app.graph.imports.state.value.acknowledgement)
        assertTrue(ProductTransportFixture.requests.none {it=="POST /api/v1/source-selections"||it=="POST /api/v1/queue/items"})
        captureListeningStage("radar-current-owner-after-retirement")
    }
    @Test fun ordinarySourcePreviewCapturedPlaylistImportReadbackRefiltersWithoutLibraryVisit() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server;val old=server.dispatcher
        val imported=AtomicBoolean(false);val calls=CopyOnWriteArrayList<String>()
        val after=instrumentation.context.assets.open("ordinary-radar-after-import-wire.json").bufferedReader().use {it.readText()}
        val recording="33333333-3333-4333-8333-000000000001"
        val job="123e4567-e89b-12d3-a456-426614174012"
        val source="https://www.youtube.com/watch?v=SQPreview01"
        val exactPath="/api/v1/catalog/recordings/$recording/source"
        fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).addHeader("Content-Type","application/json").body(body).build()
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath;calls.add(request.method+" "+path)
            if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return old.dispatch(request)
            return when {
                path=="/api/v1/me/discovery/releases"&&imported.get()->reply(after)
                path==exactPath->{check(request.method=="GET");reply("""{"recordingMbid":"$recording","sourceUrl":"$source"}""")}
                path=="/api/v1/downloads"&&request.method=="POST"->{
                    val body=JSONObject(request.body!!.utf8())
                    check(body.getString("url")==source&&body.getString("source_type")=="youtube"&&body.length()==2)
                    reply("""{"job_id":"$job","status":"queued"}""",201)
                }
                path=="/api/v1/downloads/$job"->{imported.set(true);reply("""{"job_id":"$job","status":"complete","progress":100,"track_id":7,"source_type":"youtube","created_at":"2026-11-14T12:00:00Z"}""")}
                path=="/api/v1/library"&&imported.get()->reply("""{"tracks":[{"id":7,"title":"Imported synthetic source","artist":"Synthetic listened artist","is_liked":false,"has_metadata_override":false,"mb_verified":true,"mb_recording_id":"$recording"}],"total":1,"limit":100,"offset":0}""")
                path=="/api/v1/downloads"->reply("""{"jobs":[]}""")
                else->old.dispatch(request)
            }
        }}
        try {
            val model=open(app);val queue=model.playback.value.queue
            compose.onNodeWithContentDescription("Add to Library: Radar fixture 01").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.acknowledgement?.id?.value==job}
            compose.onNodeWithText("Song evidence").assertDoesNotExist()
            compose.onNodeWithContentDescription("Imports").performClick()
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Check import"))
            compose.onNodeWithText("Check import").performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.selected?.track?.value==7L}
            // Check import only certifies the job. Use the canonical exact Library
            // readback to witness membership without navigating to Library.
            val scope=checkNotNull(app.graph.session.capture())
            assertNotNull(app.graph.api.trackDetailsSnapshot(scope,com.soundq.android.data.TrackId(7)){app.graph.session.current(scope)})
            compose.waitUntil(10000){app.graph.discovery.radar.value.stale}
            compose.onNodeWithContentDescription("Close Imports").performClick()
            compose.waitUntil(10000){app.graph.discovery.radar.value.page?.songs?.size==19&&!app.graph.discovery.radar.value.stale}
            assertEquals(5,app.graph.discovery.radar.value.visibleCount)
            compose.onNodeWithText("Radar fixture 01").assertDoesNotExist()
            compose.onNodeWithText("Radar fixture 02").performScrollTo().assertIsDisplayed()
            assertEquals(1,calls.count {it=="GET $exactPath"})
            assertEquals(1,calls.count {it=="POST /api/v1/downloads"})
            assertTrue(calls.none {it=="POST /api/v1/source-selections"||it=="POST /api/v1/queue/items"||it.startsWith("POST /api/v1/playlists")})
            assertEquals(queue,model.playback.value.queue);assertFalse(model.playback.value.isPlaying)
        } finally {server.dispatcher=old;app.graph.session.retire()}
    }
}
