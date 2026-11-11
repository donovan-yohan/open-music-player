package com.soundq.android

import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inspector.WindowInspector
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Real ordinary ProductApp -> ViewModel -> repository -> trusted TLS. Compiled, not executed here. */
class TrackDetailsJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun settleNativeWindow() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        instrumentation.waitForIdleSync()
        instrumentation.uiAutomation.waitForIdle(500,3000)
        compose.waitForIdle()
    }
    private fun finishNativeComposition() {
        if(android.os.Build.VERSION.SDK_INT<29)error("Native modal window observation requires API29 or newer")
        // Keep-editing can restore the native IME's composing span. Commit
        // through the focused modal's real input connection, not editor state
        // mutation or a weakened production composition guard.
        compose.runOnIdle {
            fun editor(view:View):View? {
                if(view.javaClass.name=="androidx.compose.ui.platform.AndroidComposeView")return view
                if(view is ViewGroup)for(i in 0 until view.childCount)editor(view.getChildAt(i))?.let {return it}
                return null
            }
            val window=WindowInspector.getGlobalWindowViews().single {it.hasWindowFocus()}
            val view=checkNotNull(editor(window))
            assertTrue(checkNotNull(view.onCreateInputConnection(EditorInfo())).finishComposingText())
        }
        settleNativeWindow()
    }
    @Test fun libraryDetailsEditSaveResetAndRemovalCancelReachRealProductionOwners() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val graph=app.graph;val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val writes=CopyOnWriteArrayList<String>();var title="Fixture 1";var edited=false
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath
            fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).apply {if(code!=204)body(body)}.build()
            if(path.endsWith("/metadata-override")) {
                val wire=request.body!!.utf8();writes.add(wire)
                val data=Json.parseToJsonElement(wire).jsonObject
                val value=data.getValue("title").let {if(it is JsonNull)null else it.jsonPrimitive.content}
                edited=value!=null;title=value?:"Fixture 1"
                return reply(buildJsonObject {put("track_id",1);put("has_metadata_override",edited);data.forEach {(k,v)->put(k,v)}}.toString())
            }
            if(path=="/api/v1/library"&&request.url.queryParameter("limit")=="100")return reply("""{"tracks":[{"id":1,"title":"$title","artist":"Synthetic ensemble","duration_ms":12000,"mb_verified":false,"has_metadata_override":$edited,"codec":"flac"}],"total":1,"limit":100,"offset":0}""")
            if(path=="/api/v1/tracks/1/analysis")return reply("{}",404)
            return fallback.dispatch(request)
        }}
        try {
            graph.session.retire()
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("details@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.rows.isNotEmpty()}
            val query=graph.library.state.value.query
            compose.onNodeWithContentDescription("More for Fixture 1").performClick()
            compose.onNodeWithText("Song details").performScrollTo().performClick()
            compose.waitUntil(10000){graph.trackDetails.state.value.detail!=null&&!graph.trackDetails.state.value.loading}
            compose.onNodeWithText("Source quality").assertExists()
            compose.onNodeWithText("flac").assertExists()
            compose.onNodeWithText("Edit metadata").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Title").performTextReplacement("Personal title")
            compose.onNodeWithContentDescription("Close Edit metadata").performScrollTo().performClick()
            compose.onNodeWithText("Keep editing").performClick()
            settleNativeWindow()
            compose.onNodeWithContentDescription("Title").assertTextContains("Personal title")
            compose.runOnIdle {assertTrue(writes.isEmpty())}
            captureListeningStage("details-editor-kept-before-save")
            finishNativeComposition()
            compose.onNodeWithContentDescription("Title").assertTextContains("Personal title")
            compose.onNodeWithText("Save metadata").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
            compose.waitUntil(10000){graph.trackDetails.state.value.detail?.track?.title=="Personal title"&&graph.trackDetails.state.value.outcome==MutationOutcome.Confirmed}
            compose.onNodeWithText("Reset to original").performScrollTo().performClick()
            compose.onNodeWithText("Cancel reset").performClick()
            compose.runOnIdle {assertEquals(1,writes.size)}
            compose.onNodeWithText("Reset to original").performScrollTo().performClick()
            compose.onNodeWithText("Confirm metadata reset").performClick()
            compose.waitUntil(10000){graph.trackDetails.state.value.detail?.edited==false&&graph.trackDetails.state.value.outcome==MutationOutcome.Confirmed}
            compose.onNodeWithContentDescription("Back to Song details").performScrollTo().performClick()
            compose.onNodeWithText("Remove from Library").performScrollTo().performClick()
            compose.onNodeWithText("Cancel removal").performClick()
            settleNativeWindow()
            assertEquals(2,writes.size)
            assertEquals(JsonNull,Json.parseToJsonElement(writes.last()).jsonObject["title"])
            assertEquals(query,graph.library.state.value.query)
            // The ordinary sheet header scrolls with its long details body.
            compose.onNodeWithContentDescription("Close Song details").performScrollTo().assertIsDisplayed().performClick()
            assertNull(graph.trackDetails.state.value.detail)
        } catch(error:Throwable) {
            println("DETAILS_FAILURE writes=${writes.size} state=${graph.trackDetails.state.value}")
            try {captureListeningStage("details-journey-failure")}catch(capture:Throwable){error.addSuppressed(capture)}
            throw error
        } finally {server.dispatcher=fallback;graph.session.retire()}
    }
}
