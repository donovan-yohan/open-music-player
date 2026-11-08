package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.playback.PlaybackProjection
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain

/** Run separately with ProductFixtureRunner: ordinary Application/MainActivity/login/service, no graph swap. */
class OrdinaryHomeJourneyTest {
    private val compose=createAndroidComposeRule<MainActivity>()
    private var original:Dispatcher?=null
    private val homeTransport=object:ExternalResource(){
        override fun before() {
            val server=ProductTransportFixture.server
            val delegate=server.dispatcher;original=delegate
            server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(path !in setOf("/api/v1/me/plays/recent","/api/v1/me/plays/top","/api/v1/me/plays/history"))return delegate.dispatch(request)
                ProductTransportFixture.requests.add(request.method+" "+path)
                if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return MockResponse.Builder().code(401).body("{}").build()
                val row="""{"id":1,"title":"Home fixture song","artist":"Synthetic ensemble","durationMs":12000,"inLibrary":true}"""
                val body=when(path){
                    "/api/v1/me/plays/recent"->"""{"tracks":[{"id":2,"title":"Removed Home song","inLibrary":false},$row],"limit":20,"offset":0}"""
                    "/api/v1/me/plays/top"->"""{"tracks":[],"days":30,"limit":20}"""
                    else->"""{"plays":[{"id":22,"track":$row,"playedAt":"2026-10-28T00:00:00Z","contextType":"queue","skipped":false},{"id":21,"track":$row,"playedAt":"2026-10-27T00:00:00Z","skipped":true}],"limit":50,"offset":0}"""
                }
                return MockResponse.Builder().addHeader("Content-Type","application/json").body(body).build()
            }}
        }
        override fun after(){original?.let {ProductTransportFixture.server.dispatcher=it}}
    }
    @get:Rule val rules:RuleChain=RuleChain.outerRule(homeTransport).around(compose)
    @Test fun loginHomeEligiblePlaybackRepeatedHistorySingletonAndLibraryReturn() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        assertTrue(app.graphCreatedOnMain);assertTrue(ProductTransportFixture.networkingStayedOffMain);assertFalse(app.bootstrapThread.isAlive)
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("synthetic-home@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        val before=ProductTransportFixture.requests.size
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){ProductTransportFixture.requests.drop(before).contains("POST /api/v1/auth/login")&&graph.session.capture()!=null&&compose.onAllNodes(hasText("Search library") and hasSetTextAction()).fetchSemanticsNodes().isNotEmpty()}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.onAllNodesWithText("Home").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){model.home.recent.value.rows.size==2&&ProductTransportFixture.requests.drop(before).contains("GET /api/v1/me/plays/top")}
        compose.onNodeWithText("Removed Home song").assertIsNotEnabled()
        compose.waitUntil(10000){model.playback.value.connection==PlaybackProjection.Connection.Connected}
        val mediaBefore=ProductTransportFixture.requests.size
        compose.onNodeWithText("Home fixture song").performClick()
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0&&model.playback.value.queue.map {it.trackId}==listOf(1L)&&ProductTransportFixture.requests.drop(mediaBefore).contains("GET /media/1.wav")}
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.onNodeWithContentDescription("Listening history").performClick()
        compose.waitUntil(10000){model.home.history.value.rows.size==2}
        assertEquals(listOf(22L,21L),model.home.history.value.rows.map {it.id})
        assertEquals(listOf(1L,1L),model.home.history.value.rows.map {it.entry.track.id.value})
        val historyRow=hasText("Home fixture song") and hasText("Skipped",substring=true) and hasClickAction()
        val priorOccurrence=model.playback.value.selectedOccurrence
        compose.onNode(historyRow).performScrollTo().assertIsEnabled().performClick()
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.map {it.trackId}==listOf(1L)&&model.playback.value.selectedOccurrence!=priorOccurrence}
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.onAllNodesWithText("Library").filterToOne(hasClickAction()).performClick()
        compose.onNode(hasText("Search library") and hasSetTextAction()).assertExists()
        assertSame("ordinary graph remains the startup graph",graph,app.graph)
        assertTrue(ProductTransportFixture.requests.drop(before).none {it=="POST /api/v1/me/plays"||it=="POST /api/v1/plays/skip"})
    }
}
