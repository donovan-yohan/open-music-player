package com.soundq.android

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.data.imports.ImportPlaylistPhase
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
        for(count in listOf(10,15,20)) {
            list.performScrollToNode(hasText("Load more"));compose.onNodeWithText("Load more").performClick()
            compose.waitUntil(10000){repository.radar.value.visibleCount==count}
            assertSame(page,repository.radar.value.page)
            list.performScrollToNode(hasText("Radar fixture %02d".format(count)))
            assertEquals(reads,ProductTransportFixture.requests.count {it=="GET /api/v1/me/discovery/releases"})
        }
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
        compose.onNodeWithText("Radar fixture 01").assertIsDisplayed().performClick()
        compose.onNodeWithText("Song evidence").assertIsDisplayed()
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
        val selection="123e4567-e89b-12d3-a456-426614174010"
        val decision="123e4567-e89b-12d3-a456-426614174011"
        val job="123e4567-e89b-12d3-a456-426614174012"
        val candidate="""{"candidateId":"ordinary-radar-source","provider":"youtube","sourceUrl":"https://youtu.be/synthetic","title":"Synthetic source","artist":"Synthetic listened artist","downloadable":true,"playable":false}"""
        fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).addHeader("Content-Type","application/json").body(body).build()
        val monitor=instrumentation.addMonitor(IntentFilter(Intent.ACTION_VIEW).apply {addDataScheme("https")},Instrumentation.ActivityResult(Activity.RESULT_CANCELED,null),true)
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath;calls.add(request.method+" "+path)
            if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return old.dispatch(request)
            return when {
                path=="/api/v1/me/discovery/releases"&&imported.get()->reply(after)
                path.endsWith("/membership")->reply("""{"recordingMbid":"$recording","inLibrary":false}""")
                path=="/api/v1/discovery/search"&&request.url.queryParameter("providers")=="soundcloud"->reply(emptyDiscoveryProvider(request.url.queryParameter("q")!!,"soundcloud"))
                path=="/api/v1/discovery/search"->reply(JSONObject().put("query",request.url.queryParameter("q")).put("results",org.json.JSONArray("[$candidate]")).put("providers",org.json.JSONArray("""[{"provider":"youtube","status":"ok"}]""")).put("selectionSessionId",selection).put("selectionExpiresAt","2030-01-01T00:00:00Z").toString())
                path=="/api/v1/playlists"->reply("""{"data":[{"id":7,"name":"Synthetic radar playlist","isPublic":false,"trackCount":0,"durationMs":0}],"total":1,"limit":20,"offset":0}""")
                path=="/api/v1/source-selections"->{check(request.method=="POST");reply("""{"id":"$decision","sessionId":"$selection","selectedCandidateId":"ordinary-radar-source","action":"selected","selectedCandidate":$candidate}""",201)}
                path=="/api/v1/queue/items"->{check(request.method=="POST");check(JSONObject(request.body!!.utf8()).getLong("playlistId")==7L);reply("""{"queue":{},"idempotent":true,"downloadJobId":"$job"}""",202)}
                path=="/api/v1/downloads/$job"->{imported.set(true);reply("""{"job_id":"$job","status":"complete","progress":100,"track_id":7,"source_type":"youtube","created_at":"2026-11-14T12:00:00Z"}""")}
                path=="/api/v1/library"&&imported.get()->reply("""{"tracks":[{"id":7,"title":"Imported synthetic source","artist":"Synthetic listened artist","has_metadata_override":false,"mb_verified":true,"mb_recording_id":"$recording"}],"total":1,"limit":100,"offset":0}""")
                path=="/api/v1/playlists/7"->reply("""{"id":7,"name":"Synthetic radar playlist","isPublic":false,"trackCount":1,"durationMs":0,"tracks":[{"id":7,"title":"Imported synthetic source"}]}""")
                path=="/api/v1/downloads"->reply("""{"jobs":[]}""")
                else->old.dispatch(request)
            }
        }}
        try {
            val model=open(app);val queue=model.playback.value.queue
            val libraryRevision=app.graph.library.state.value.pageRevision
            compose.onNodeWithText("Radar fixture 01").performScrollTo().performClick()
            compose.onNodeWithText("Find sources").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.discovery.state.value.results!=null}
            compose.onNodeWithText("Synthetic source").performScrollTo().performClick()
            compose.onNodeWithText("Preview source").performScrollTo().performClick()
            compose.waitUntil(5000){monitor.hits>0}
            compose.onNodeWithText("Import source").performScrollTo().performClick()
            compose.onNodeWithText("Choose playlist").performScrollTo().performClick()
            compose.onNodeWithText("Synthetic radar playlist").performScrollTo().performClick()
            compose.onNodeWithText("Import to selected playlist").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.acknowledgement!=null}
            assertFalse(imported.get());assertFalse(app.graph.discovery.radar.value.stale)
            instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            compose.onNodeWithContentDescription("Back to previous search").performClick()
            compose.onNodeWithContentDescription("Imports").performClick()
            compose.onAllNodes(hasText("Check import") and hasClickAction()).onFirst().performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.playlistConfirmation?.phase==ImportPlaylistPhase.Confirmed}
            assertTrue(app.graph.discovery.radar.value.stale)
            assertEquals(libraryRevision,app.graph.library.state.value.pageRevision)
            compose.onNodeWithContentDescription("Close Imports").performClick()
            compose.waitUntil(10000){app.graph.discovery.radar.value.page?.songs?.size==19&&!app.graph.discovery.radar.value.stale}
            assertEquals(5,app.graph.discovery.radar.value.visibleCount)
            compose.onNodeWithText("Radar fixture 01").assertDoesNotExist()
            compose.onNodeWithText("Radar fixture 02").performScrollTo().assertIsDisplayed()
            assertEquals(1,calls.count {it=="POST /api/v1/source-selections"})
            assertEquals(1,calls.count {it=="POST /api/v1/queue/items"})
            assertEquals(queue,model.playback.value.queue);assertFalse(model.playback.value.isPlaying)
            captureListeningStage("combined-radar-confirmed-readback")
        } finally {instrumentation.removeMonitor(monitor);server.dispatcher=old;app.graph.session.retire()}
    }
}
