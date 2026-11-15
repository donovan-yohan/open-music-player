package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import com.soundq.android.data.AuthState
import com.soundq.android.data.LibraryQuery
import com.soundq.android.data.discovery.RadarPhase
import com.soundq.android.product.ProductViewModel
import androidx.test.platform.app.InstrumentationRegistry
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.Executors
import com.soundq.android.data.TrackId

/** Ordinary production route/effects and real Activity lifecycle against held synthetic HTTPS. */
class ReleaseRadarRecoveryJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val app get()=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
    private fun signIn():ProductViewModel {
        compose.signInThroughSettings("radar-recovery@example.test","fixture-only-password"){app.graph.session.state.value is AuthState.SignedIn}
        return compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
    }
    private fun discover(){compose.onNode(hasText("Discover") and hasClickAction() and !isHeading()).performClick()}
    private fun awaitEntry(latch:CountDownLatch) {
        // Pump the rule's scheduler so production Main/effect continuations can dispatch.
        compose.waitUntil(5000){latch.count==0L}
        assertEquals(0L,latch.count)
    }
    private fun ownershipReadback() {
        // Same parsed Library-row producer used by import confirmation, not a direct invalidation.
        val scope=app.graph.session.capture()!!
        val pool=Executors.newSingleThreadExecutor()
        try {
            val result=pool.submit<com.soundq.android.data.trackdetails.TrackDetails?> {
                app.graph.api.trackDetailsSnapshot(scope,TrackId(1)){app.graph.session.current(scope)}
            }
            compose.waitUntil(10000){result.isDone}
            assertEquals(1L,result.get(1,TimeUnit.SECONDS)!!.track.id.value)
        } finally {pool.shutdownNow()}
    }
    private fun reads()=ProductTransportFixture.requests.count {it=="GET /api/v1/me/discovery/releases"}
    private fun noMutation(model:ProductViewModel,queue:List<com.soundq.android.playback.QueueOccurrence>) {
        assertEquals(queue,model.playback.value.queue);assertFalse(model.playback.value.isPlaying)
        assertNull(app.graph.imports.state.value.acknowledgement)
        assertTrue(ProductTransportFixture.requests.none {it=="POST /api/v1/source-selections"||it=="POST /api/v1/queue/items"})
    }
    @Test fun interruptedInitialGetStopResumeRecoversSameViewWithoutRevivingOldPage() {
        val server=ProductTransportFixture.server;val prior=server.dispatcher
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val oldReturned=CountDownLatch(1);val calls=AtomicInteger()
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            if(request.url.encodedPath!="/api/v1/me/discovery/releases")return prior.dispatch(request)
            val response=prior.dispatch(request)
            if(calls.incrementAndGet()==1) {
                entered.countDown();check(release.await(30,TimeUnit.SECONDS));oldReturned.countDown()
                // The same valid wire yields a different canonical page if wrongly republished.
                return response
            }
            return response
        }}
        try {
            val model=signIn();val queue=model.playback.value.queue
            val jobsBefore=compose.runOnIdle {model.viewModelScope.coroutineContext[Job]!!.children.toSet()}
            discover()
            awaitEntry(entered);assertNull(app.graph.discovery.radar.value.page)
            val heldJobs=compose.runOnIdle {model.viewModelScope.coroutineContext[Job]!!.children.toSet()-jobsBefore}
            assertTrue(heldJobs.isNotEmpty())
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            assertEquals(RadarPhase.Idle,app.graph.discovery.radar.value.phase)
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            compose.waitUntil(10000){app.graph.discovery.radar.value.page!=null&&calls.get()==2}
            val fresh=app.graph.discovery.radar.value.page!!
            compose.onNodeWithText("Radar fixture 01").assertIsDisplayed()
            release.countDown();assertTrue(oldReturned.await(5,TimeUnit.SECONDS))
            compose.waitUntil(10000){heldJobs.all {it.isCompleted}}
            assertSame(fresh,app.graph.discovery.radar.value.page)
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED);compose.waitForIdle()
            assertEquals(2,calls.get());noMutation(model,queue)
            captureListeningStage("radar-interrupted-same-view-recovered")
        } finally {release.countDown();server.dispatcher=prior}
    }
    @Test fun heldSearchAndLibraryReadbackReloadOnSameViewBlankReturn() {
        val server=ProductTransportFixture.server;val prior=server.dispatcher
        val searchEntered=CountDownLatch(1);val searchRelease=CountDownLatch(1)
        val libraryEntered=CountDownLatch(1);val libraryRelease=CountDownLatch(1)
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            if(request.url.encodedPath=="/api/v1/discovery/search") {searchEntered.countDown();check(searchRelease.await(30,TimeUnit.SECONDS))}
            if(request.url.encodedPath=="/api/v1/library"&&searchEntered.count==0L) {libraryEntered.countDown();check(libraryRelease.await(30,TimeUnit.SECONDS))}
            return prior.dispatch(request)
        }}
        try {
            val model=signIn();val queue=model.playback.value.queue;discover()
            compose.waitUntil(10000){app.graph.discovery.radar.value.page!=null}
            val page=app.graph.discovery.radar.value.page!!;val count=reads()
            compose.onNodeWithContentDescription("Music search query").performTextReplacement("held source search")
            awaitEntry(searchEntered)
            val revision=app.graph.discovery.radarInvalidation.value
            compose.runOnIdle {model.refine(LibraryQuery())}
            awaitEntry(libraryEntered);libraryRelease.countDown()
            compose.waitUntil(10000){app.graph.discovery.radarInvalidation.value>revision}
            assertTrue(app.graph.discovery.radar.value.stale);assertEquals(count,reads())
            compose.onNodeWithContentDescription("Clear search").performClick()
            compose.waitUntil(10000){app.graph.discovery.radar.value.page!==page&&!app.graph.discovery.radar.value.stale}
            assertEquals(count+1,reads());searchRelease.countDown();compose.waitForIdle()
            assertTrue(app.graph.discovery.state.value.draft.text.isBlank())
            compose.onNodeWithText("Radar fixture 01").performScrollTo().assertIsDisplayed()
            noMutation(model,queue);captureListeningStage("radar-blank-return-after-readback")
        } finally {searchRelease.countDown();libraryRelease.countDown();server.dispatcher=prior}
    }
    @Test fun hiddenImportsDefersReadbackReloadUntilVisibilityAcknowledgement() {
        val model=signIn();val queue=model.playback.value.queue;discover()
        compose.waitUntil(10000){app.graph.discovery.radar.value.page!=null}
        val page=app.graph.discovery.radar.value.page!!;val count=reads()
        compose.onNodeWithContentDescription("Imports").performClick()
        val revision=app.graph.discovery.radarInvalidation.value
        compose.runOnIdle {model.refine(LibraryQuery())}
        compose.waitUntil(10000){app.graph.discovery.radarInvalidation.value>revision}
        assertTrue(app.graph.discovery.radar.value.stale);assertEquals(count,reads())
        compose.onNodeWithContentDescription("Close Imports").performClick()
        compose.waitUntil(10000){app.graph.discovery.radar.value.page!==page&&!app.graph.discovery.radar.value.stale}
        assertEquals(count+1,reads());noMutation(model,queue)
        captureListeningStage("radar-visible-after-readback")
    }
    @Test fun secondReadbackDuringHeldRefreshRestartsOnceAndFailureRequiresExplicitRecovery() {
        val server=ProductTransportFixture.server;val prior=server.dispatcher
        val held=CountDownLatch(1);val release=CountDownLatch(1);val calls=AtomicInteger()
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            if(request.url.encodedPath=="/api/v1/library"&&request.url.queryParameter("limit")=="100")
                return MockResponse.Builder().body("""{"tracks":[{"id":1,"title":"Fixture 1","artist":"Synthetic ensemble","has_metadata_override":false,"mb_verified":false}],"total":1,"limit":100,"offset":0}""").build()
            if(request.url.encodedPath!="/api/v1/me/discovery/releases")return prior.dispatch(request)
            when(calls.incrementAndGet()) {
                2->{held.countDown();check(release.await(30,TimeUnit.SECONDS))}
                4->return MockResponse.Builder().code(503).body("{}").build()
            }
            return prior.dispatch(request)
        }}
        try {
            val model=signIn();val queue=model.playback.value.queue;discover()
            compose.waitUntil(10000){app.graph.discovery.radar.value.page!=null}
            // Import ownership readback publishes exactly once after parsing a real Library row.
            ownershipReadback()
            awaitEntry(held)
            compose.waitUntil(10000){app.graph.discovery.radar.value.phase==RadarPhase.Loading}
            val revision=app.graph.discovery.radarInvalidation.value
            ownershipReadback()
            compose.waitUntil(10000){app.graph.discovery.radarInvalidation.value>revision&&calls.get()==3&&!app.graph.discovery.radar.value.stale}
            val newest=app.graph.discovery.radar.value.page!!;release.countDown();compose.waitForIdle()
            assertSame(newest,app.graph.discovery.radar.value.page)
            ownershipReadback()
            compose.waitUntil(10000){app.graph.discovery.radar.value.phase==RadarPhase.Failed}
            assertEquals(4,calls.get());assertSame(newest,app.graph.discovery.radar.value.page)
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED);compose.waitForIdle()
            assertEquals(4,calls.get());assertEquals(RadarPhase.Failed,app.graph.discovery.radar.value.phase)
            compose.onNodeWithText("Try again").performScrollTo().performClick()
            compose.waitUntil(10000){calls.get()==5&&app.graph.discovery.radar.value.phase==RadarPhase.Ready&&!app.graph.discovery.radar.value.stale}
            noMutation(model,queue);captureListeningStage("radar-reinvalidated-and-explicit-recovery")
        } finally {release.countDown();server.dispatcher=prior}
    }
}
