package com.soundq.android

import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.data.LibraryQuery
import androidx.lifecycle.Lifecycle
import org.json.JSONArray
import org.json.JSONObject
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Ordinary Library route, real LazyColumn and claim-before-IO API pagination. */
class LibraryPaginationJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    @Test fun scrollingLoadsPagesWithoutManualLoadControl() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        val original=ProductTransportFixture.server.dispatcher
        val offsets=CopyOnWriteArrayList<Int>()
        val requestPhases=CopyOnWriteArrayList<String>()
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath!="/api/v1/library")return original.dispatch(request)
                val offset=request.url.queryParameter("offset")?.toInt() ?: 0
                offsets.add(offset)
                if(requestPhases.size<16)requestPhases.add("entered:$offset")
                val count=minOf(20,60-offset).coerceAtLeast(0)
                val rows=(offset until offset+count).joinToString(",") {i->
                    """{"id":${i+1},"title":"Page track ${i+1}","artist":"Synthetic ensemble","duration_ms":12000,"is_liked":false}"""
                }
                return MockResponse.Builder().body("""{"tracks":[$rows],"total":60,"limit":20,"offset":$offset}""").build().also {
                    if(requestPhases.size<16)requestPhases.add("response-built:$offset")
                }
            }
        }
        var stage="sign-in"
        var expectedRows=20
        fun snapshot():String {
            val state=graph.library.state.value
            val scope=graph.session.capture()
            val json=JSONObject().put("stage",stage).put("expectedRows",expectedRows)
                .put("rowsMatch",state.rows.size==expectedRows).put("notLoading",!state.loading)
                .put("rows",state.rows.size).put("total",state.total ?: JSONObject.NULL)
                .put("nextOffset",state.nextOffset).put("pageRevision",state.pageRevision)
                .put("error",state.error?.name ?: JSONObject.NULL).put("endReached",state.endReached)
                .put("nonempty",state.rows.isNotEmpty()).put("hasTotal",state.total!=null)
                .put("beforeEnd",state.total?.let {state.nextOffset<it} ?: JSONObject.NULL)
                .put("queryIsDefault",state.query==LibraryQuery())
                .put("authClass",graph.session.state.value.javaClass.simpleName)
                .put("signedIn",graph.session.state.value is AuthState.SignedIn)
                .put("scopePresent",scope!=null).put("freshScopeRemoteCurrent",scope?.let(graph.session::remoteCurrent) ?: false)
                .put("sessionVersion",graph.session.version()).put("offsets",JSONArray(offsets.take(16)))
                .put("requestPhases",JSONArray(requestPhases.take(16)))
            // Failure-only semantics read. No extra idling boundary precedes the original waits.
            try {
                val nodes=compose.onAllNodes(SemanticsMatcher("pagination snapshot"){true}).fetchSemanticsNodes()
                val list=nodes.singleOrNull {it.config.getOrNull(SemanticsProperties.ContentDescription)?.contains("Library, 60 tracks")==true}
                json.put("libraryListMounted",list!=null)
                list?.let {node->
                    val axis=node.config.getOrNull(SemanticsProperties.VerticalScrollAxisRange)
                    json.put("listBounds",node.boundsInRoot.toString())
                        .put("scroll",axis?.value?.invoke()).put("scrollMax",axis?.maxValue?.invoke())
                    val visible=nodes.filter {it.root===node.root&&it.boundsInRoot.overlaps(node.boundsInRoot)}
                        .flatMap {it.config.getOrNull(SemanticsProperties.Text).orEmpty()}
                        .map {it.text}.filter {it.startsWith("Page track ")}.take(20)
                    json.put("visiblePageLabels",JSONArray(visible))
                    json.put("rootAttached",(node.root as? ViewRootForTest)?.view?.isAttachedToWindow)
                }
            } catch(diagnostic:Throwable) {json.put("semanticsFailure",diagnostic.javaClass.name)}
            // Retain the metadata even if optional UI diagnostics fail.
            try {
                InstrumentationRegistry.getInstrumentation().runOnMainSync {
                    json.put("lifecycle",compose.activity.lifecycle.currentState.name)
                        .put("resumed",compose.activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
                        .put("windowFocus",compose.activity.hasWindowFocus())
                }
            } catch(diagnostic:Throwable) {json.put("lifecycleFailure",diagnostic.javaClass.name)}
            // A fresh scope is not evidence of the production composition's remembered capture.
            json.put("capturedPaginationScope","unobserved").put("paginationVisitCurrent","unobserved")
                .put("observerGateCurrent","unobserved").put("observerClaim","unobserved")
            return json.toString()
        }
        try {
            paginationAttempt({
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("pagination@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.rows.size==20&&!graph.library.state.value.loading}
            stage="page-20-to-40";expectedRows=40
            compose.onNodeWithContentDescription("Library, 60 tracks").performScrollToIndex(18)
            compose.waitUntil(10000){graph.library.state.value.rows.size==40&&!graph.library.state.value.loading}
            stage="page-40-to-60";expectedRows=60
            compose.onNodeWithContentDescription("Library, 60 tracks").performScrollToIndex(38)
            compose.waitUntil(10000){graph.library.state.value.rows.size==60&&!graph.library.state.value.loading}
            stage="final-assertions"
            compose.onNodeWithContentDescription("Library, 60 tracks").performScrollToIndex(59)
            compose.waitForIdle()
            assertEquals(listOf(0,20,40),offsets.toList())
            assertTrue(graph.library.state.value.endReached)
            assertEquals(60,graph.library.state.value.rows.map {it.id}.toSet().size)
            compose.onNodeWithText("Load more tracks").assertDoesNotExist()
            assertTrue(graph.controller.state.value.queue.isEmpty())
            assertFalse(graph.controller.state.value.isPlaying)
            },::snapshot)
        } finally {
            ProductTransportFixture.server.dispatcher=original
            graph.session.retire()
        }
    }
}
