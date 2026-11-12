package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import com.soundq.android.data.AuthState
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import java.util.concurrent.CopyOnWriteArrayList

/** Ordinary startup fixture, not a post-boot replacement graph. Compile is not device execution. */
class HistoryRefinementJourneyTest {
    private val compose=createAndroidComposeRule<MainActivity>()
    private var original:Dispatcher?=null
    private val offsets=CopyOnWriteArrayList<Int>()
    private val transport=object:ExternalResource() {
        override fun before() {
            val delegate=ProductTransportFixture.server.dispatcher;original=delegate
            ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(path !in setOf("/api/v1/me/plays/recent","/api/v1/me/plays/top","/api/v1/me/plays/history"))return delegate.dispatch(request)
                if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return MockResponse.Builder().code(401).body("{}").build()
                if(!path.endsWith("history"))return MockResponse.Builder().body("""{"tracks":[]}""").build()
                val offset=request.url.queryParameter("offset")!!.toInt();offsets+=offset
                val events=(offset+1..minOf(offset+50,78)).map {id->
                    val match=id>=76
                    """{"id":$id,"track":{"id":1,"title":"${if(match)"Needle repeated song" else "Other history song"}","artist":"Synthetic ensemble","durationMs":12000,"inLibrary":${id!=77}},"playedAt":"2026-11-06T00:00:${(id%60).toString().padStart(2,'0')}Z","contextType":"queue","skipped":${id!=76}}"""
                }
                return MockResponse.Builder().body("""{"plays":[${events.joinToString(",")}],"limit":50,"offset":$offset}""").build()
            }}
        }
        override fun after(){original?.let {ProductTransportFixture.server.dispatcher=it}}
    }
    @get:Rule val rules:RuleChain=RuleChain.outerRule(transport).around(compose)
    @Test fun ordinaryHistorySearchAndSkippedTabReachEventsAfterFirstPageWithoutAutoplay() {
        val graph=(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        compose.signInThroughSettings("history-parity@example.test","fixture-password"){graph.session.state.value is AuthState.SignedIn}
        compose.waitUntil(10000){compose.onAllNodes(hasText("Search library") and hasSetTextAction()).fetchSemanticsNodes().isNotEmpty()}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.onAllNodesWithText("Home").filterToOne(hasClickAction()).performClick()
        compose.onNodeWithContentDescription("Settings").assertExists()
        compose.onNodeWithContentDescription("Refresh recent").assertExists()
        compose.onNodeWithContentDescription("Listening history").performClick()
        compose.waitUntil(10000){model.home.history.value.rows.size==50&&!model.home.history.value.loading}
        compose.onNodeWithContentDescription("History title or artist").performTextInput("Needle")
        compose.onNodeWithContentDescription("Search history").performClick()
        compose.waitUntil(10000){model.home.history.value.query.text=="Needle"&&!model.home.history.value.loading}
        assertEquals(listOf(76L,77L,78L),model.home.history.value.rows.map {it.id})
        compose.onNodeWithText("Skipped").performClick()
        compose.waitUntil(10000){!model.home.history.value.loading&&model.home.history.value.rows.map {it.id}==listOf(77L,78L)}
        assertEquals(listOf(0,0,50,0,50),offsets.toList())
        assertFalse(model.playback.value.isPlaying)
        val unavailable=hasText("Needle repeated song") and hasText("Not in your library",substring=true)
        compose.onNode(unavailable).assertIsNotEnabled()
        val available=hasText("Needle repeated song") and hasText("Skipped",substring=true) and isEnabled()
        compose.onNode(available).performClick()
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.map {it.trackId}==listOf(1L)}
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.onAllNodesWithText("Library").filterToOne(hasClickAction()).performClick()
        compose.onNode(hasText("Search library") and hasSetTextAction()).assertExists()
        assertFalse(model.playback.value.isPlaying)
    }
}
