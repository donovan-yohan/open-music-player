package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import java.util.concurrent.CopyOnWriteArrayList

/** Ordinary startup graph and service. Only the synthetic Home corpus is overridden before launch. */
class HomeJourneyTest {
    private val compose=createAndroidComposeRule<MainActivity>()
    private val requests=CopyOnWriteArrayList<String>()
    private var original:Dispatcher?=null
    private val transport=object:ExternalResource() {
        override fun before() {
            val fallback=ProductTransportFixture.server.dispatcher;original=fallback
            ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath;requests.add(path)
                if(path !in setOf("/api/v1/me/plays/recent","/api/v1/me/plays/top","/api/v1/me/plays/history"))return fallback.dispatch(request)
                check(request.headers["Authorization"]=="Bearer synthetic-fixture-access")
                val row="""{"id":7,"title":"Repeated history song","artist":"Synthetic artist","inLibrary":true}"""
                val body=when(path) {
                    "/api/v1/me/plays/recent"->recentFixtureBody("""{"tracks":[{"id":8,"title":"Removed song","inLibrary":false},$row]}""")
                    "/api/v1/me/plays/top"->"""{"tracks":[]}"""
                    else->"""{"plays":[{"id":2,"track":$row,"playedAt":"2026-10-28T00:00:00Z","skipped":false},{"id":1,"track":$row,"playedAt":"2026-10-27T00:00:00Z","skipped":true}],"limit":50,"offset":0}"""
                }
                return MockResponse.Builder().body(body).build()
            }}
        }
        override fun after(){original?.let {ProductTransportFixture.server.dispatcher=it}}
    }
    @get:Rule val rules:RuleChain=RuleChain.outerRule(transport).around(compose)
    @Test fun ordinaryLibraryHomeHistoryAndBackPreserveEligibilityAndRepeatedEvents() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        compose.signInThroughSettings("home-swipe@example.test","test-only-password"){graph.session.capture()!=null}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        try {
            compose.onNodeWithContentDescription("Search library").assertExists()
            compose.onNodeWithText("Home").performClick()
            compose.waitUntil(10000){requests.contains("/api/v1/me/plays/recent")&&model.home.recent.value.rows.size==2}
            compose.onNodeWithText("Removed song").assertIsNotEnabled()
            compose.waitUntil(10000){model.playback.value.connection==com.soundq.android.playback.PlaybackProjection.Connection.Connected}
            compose.onNodeWithText("Repeated history song").performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.map {it.trackId}==listOf(7L)}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            val paused=model.playback.value
            compose.onNode(hasText("Repeated history song") and isSelected()).performTouchInput {
                down(androidx.compose.ui.geometry.Offset(width*0.9f,center.y));moveBy(androidx.compose.ui.geometry.Offset(-190*app.resources.displayMetrics.density,0f),delayMillis=300);up()
            }
            compose.waitUntil(10000){model.playback.value.queue.size==paused.queue.size+1}
            assertEquals(paused.selectedOccurrence,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            compose.onNodeWithText("Your top tracks").performScrollTo()
            compose.onNodeWithText("No top tracks yet").assertExists()
            compose.onNodeWithContentDescription("Listening history").performClick()
            compose.waitUntil(10000){model.home.history.value.rows.size==2}
            compose.onNode(hasText("Repeated history song") and hasText("Skipped",substring=true)).assertExists().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.count {it.manual}==1&&model.playback.value.queue.size==2}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            val historyPaused=model.playback.value
            compose.onNode(hasText("Repeated history song") and hasText("Skipped",substring=true)).performTouchInput {
                down(androidx.compose.ui.geometry.Offset(width*0.9f,center.y));moveBy(androidx.compose.ui.geometry.Offset(-190*app.resources.displayMetrics.density,0f),delayMillis=300);up()
            }
            compose.waitUntil(10000){model.playback.value.queue.size==historyPaused.queue.size+1}
            assertEquals(historyPaused.selectedOccurrence,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            assertEquals(listOf(2L,1L),model.home.history.value.rows.map {it.id})
            captureListeningStage("home-history-paused-manual-queue")
            compose.onNode(hasText("Library") and hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Search library").assertExists()
            assertTrue(requests.none {it.contains("/plays/skip")||it=="/api/v1/me/plays"})
            assertSame(graph,app.graph)
        } finally {app.graph.session.retire()}
    }
}
