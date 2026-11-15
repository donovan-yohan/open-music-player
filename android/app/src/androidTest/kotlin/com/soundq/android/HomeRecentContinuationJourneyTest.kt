package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/** Authored ordinary startup/login consumer. Requires ProductFixtureRunner.
 * Not executed by the lightweight host gate; that gate cannot prove Compose,
 * Android semantics, Media3, geometry or native input. */
class HomeRecentContinuationJourneyTest {
    private val compose=createAndroidComposeRule<MainActivity>()
    private var original:Dispatcher?=null
    private val offsets=CopyOnWriteArrayList<Int>()
    private val failAppend=AtomicBoolean(true)
    private val transport=object:ExternalResource() {
        override fun before() {
            val delegate=ProductTransportFixture.server.dispatcher;original=delegate
            ProductTransportFixture.server.dispatcher=object:Dispatcher() {
                override fun dispatch(request:RecordedRequest):MockResponse {
                    val path=request.url.encodedPath
                    if(path !in setOf("/api/v1/me/plays/recent","/api/v1/me/plays/top"))return delegate.dispatch(request)
                    if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return MockResponse.Builder().code(401).body("{}").build()
                    if(path.endsWith("top"))return MockResponse.Builder().body("""{"tracks":[]}""").build()
                    assertEquals("true",request.url.queryParameter("continuation"))
                    val offset=request.url.queryParameter("offset")!!.toInt();offsets+=offset
                    if(offset>0) {
                        assertEquals("a".repeat(64),request.url.queryParameter("revision"))
                        if(failAppend.compareAndSet(true,false))return MockResponse.Builder().code(503).body("{}").build()
                    }
                    val ids=(offset+1..minOf(offset+20,23))
                    val rows=ids.joinToString(",") {id->"""{"id":$id,"title":"Recent $id","artist":"Synthetic ensemble","durationMs":12000,"inLibrary":${id in setOf(1,9,21)}}"""}
                    return MockResponse.Builder().body(recentFixtureBody("""{"tracks":[$rows]}""",offset,offset+20<23)).build()
                }
            }
        }
        override fun after(){original?.let {ProductTransportFixture.server.dispatcher=it}}
    }
    @get:Rule val rules:RuleChain=RuleChain.outerRule(transport).around(compose)
    private fun revealText(text:String):SemanticsNodeInteraction {
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(text))
        return compose.onNodeWithText(text)
    }

    @Test fun fiveThenExplicitContinuationRetryFullContextAndFreshVisitReset() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        compose.signInThroughSettings("recent-continuation@example.test","test-only-password"){app.graph.session.capture()!=null}
        compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.onAllNodesWithText("Home").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){model.home.recent.value.rows.size==20&&!model.home.recent.value.loading}
        assertEquals(5,model.home.recent.value.visibleCount)
        compose.onNodeWithText("Recent 1").assertIsEnabled()
        compose.onNodeWithText("Recent 2").assertIsNotEnabled()
        compose.onNodeWithText("Recent 6").assertDoesNotExist()
        // Footer is directly before Top in the actual lazy list.
        revealText("Load more").assertIsDisplayed()
        compose.onNodeWithText("Your top tracks").performScrollTo().assertIsDisplayed()
        val footer=compose.onNodeWithText("Load more").fetchSemanticsNode().boundsInRoot
        val top=compose.onNodeWithText("Your top tracks").fetchSemanticsNode().boundsInRoot
        assertTrue(footer.height>0f&&footer.bottom<=top.top)
        compose.onNodeWithText("Recent 1").performScrollTo().performClick()
        compose.waitUntil(15000){model.playback.value.queue.map {it.trackId}==listOf(1L,9L)}
        // Keep the manual insertion pending instead of racing the synthetic song's natural end.
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.onNodeWithContentDescription("More for Recent 1").performScrollTo().performClick()
        compose.onNodeWithText("Add to listening queue").performClick()
        // Media3 may publish the inserted count before the resolved item's metadata.
        // Wait for the actual manual/context identity, not an optimistic placeholder row.
        try {
            compose.waitUntil(10000){model.playback.value.let {p->p.queue.size==3&&!p.isPlaying&&p.queue.count {it.manual}==1&&p.queue.filterNot {it.manual}.map {it.trackId}==listOf(1L,9L)}}
        } catch(failure:Throwable) {
            val p=model.playback.value
            throw AssertionError("Manual insertion projection tracks=${p.queue.map {it.trackId}} manual=${p.queue.map {it.manual}} selected=${p.queue.firstOrNull {it.occurrenceId==p.selectedOccurrence}?.trackId} playing=${p.isPlaying}",failure)
        }
        val retainedManual=model.playback.value.queue.single {it.manual}
        repeat(3) {index->
            revealText("Load more").performClick()
            compose.waitUntil(5000){model.home.recent.value.visibleCount==10+index*5}
        }
        assertEquals(listOf(0),offsets.toList())
        revealText("Load more").performClick()
        compose.waitUntil(10000){model.home.recent.value.error!=null}
        assertEquals(20,model.home.recent.value.visibleCount);assertEquals(20,model.home.recent.value.rows.size)
        revealText("Recent 20").assertExists()
        revealText("Retry Recently played").performClick()
        compose.waitUntil(10000){model.home.recent.value.visibleCount==23&&!model.home.recent.value.loading}
        revealText("Recent 23").assertExists()
        compose.onNodeWithText("Load more").assertDoesNotExist()
        assertEquals(listOf(0,20,20),offsets.toList())
        revealText("Recent 21").performClick()
        // The context is still exactly the three eligible rows. The canonical service also
        // carries the pending manual occurrence after the newly selected context row.
        compose.waitUntil(15000){model.playback.value.let {p->p.isPlaying&&p.queue.filterNot {it.manual}.map {it.trackId}==listOf(1L,9L,21L)&&p.queue.filter {it.manual}==listOf(retainedManual)&&p.queue.map {it.trackId}==listOf(1L,9L,21L,1L)&&p.queue.firstOrNull {it.occurrenceId==p.selectedOccurrence}?.trackId==21L}}
        val acceptedPlayback=model.playback.value
        val label=InstrumentationRegistry.getArguments().getString("captureLabel") ?: "default"
        require(label.matches(Regex("[a-zA-Z0-9-]+")))
        val evidence=java.io.File(app.getExternalFilesDir(null),"listening-20261105/$label").apply {mkdirs()}
        java.io.File(evidence,"home-continuation-queue.json").writeText(org.json.JSONObject()
            .put("trackIds",org.json.JSONArray(acceptedPlayback.queue.map {it.trackId}))
            .put("contextTrackIds",org.json.JSONArray(acceptedPlayback.queue.filterNot {it.manual}.map {it.trackId}))
            .put("manualOccurrenceRetained",acceptedPlayback.queue.single {it.manual}==retainedManual)
            .put("selectedTrackId",acceptedPlayback.queue.single {it.occurrenceId==acceptedPlayback.selectedOccurrence}.trackId)
            .put("isPlaying",acceptedPlayback.isPlaying).toString())
        compose.onAllNodesWithText("Library").filterToOne(hasClickAction()).performClick()
        compose.onAllNodesWithText("Home").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){offsets.size==4&&model.home.recent.value.visibleCount==5&&!model.home.recent.value.loading}
        compose.onNodeWithText("Recent 6").assertDoesNotExist()
    }
}
