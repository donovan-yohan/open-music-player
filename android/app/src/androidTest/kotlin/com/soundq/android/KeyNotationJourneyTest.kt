package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.preferences.*
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Ordinary ProductApp Settings -> durable owner -> real Song details. Compiled only, not run here. */
class KeyNotationJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    /** Reveal the real lazy item before resolving an otherwise uncomposed target. */
    private fun reveal(matcher:SemanticsMatcher):SemanticsNodeInteraction {
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(matcher)
        return compose.onNode(matcher).assertIsDisplayed().assertIsEnabled()
    }

    private fun click(label:String)=compose.onNode(hasText(label) and hasClickAction()).performScrollTo().performClick()
    @Test fun choiceSurvivesReconstructionAndChangesDetailsWithoutAutoplayOrCorrectionWrites() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val writes=CopyOnWriteArrayList<String>()
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath
            fun reply(body:String)=MockResponse.Builder().code(200).addHeader("Content-Type","application/json").body(body).build()
            if(path=="/api/v1/library"&&request.url.queryParameter("limit")=="100")return reply("""{"tracks":[{"id":1,"title":"Fixture 1","artist":"Synthetic ensemble","duration_ms":12000,"mb_verified":false,"has_metadata_override":false}],"total":1,"limit":100,"offset":0}""")
            if(path=="/api/v1/tracks/1/analysis"&&request.method=="GET")return reply("""{"track_id":1,"schema_version":1,"override_revision":3,"status":"analyzed","updated_at":"2026-10-28T00:00:00Z","summary":{"key":{"value":"Am"},"camelot":{"value":"8A"}},"overrides":{},"effective_timing":{}}""")
            if(path.startsWith("/api/v1/tracks/1/")&&request.method!="GET")writes.add(request.method+" "+path)
            return fallback.dispatch(request)
        }}
        try {
            graph.session.retire()
            // Synthetic installation fixture only. No production account or external data.
            graph.keyNotationPreferences.load()
            assertTrue(graph.keyNotationPreferences.setChoice(graph.keyNotationPreferences.capture()!!,KeyNotation.Camelot){true})
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("notation@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.rows.size>=3&&graph.keyNotationPreferences.state.value.ready}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val controller=model.controller
            compose.runOnIdle {assertFalse(model.playback.value.isPlaying)}
            val before=compose.runOnIdle {model.playback.value}
            for(choice in listOf(KeyNotation.Musical,KeyNotation.Camelot)) {
                reveal(hasContentDescription("Account and preview information")).performClick();click("Settings")
                click(if(choice==KeyNotation.Musical)"Musical key" else "Camelot")
                compose.waitUntil(10000){graph.keyNotationPreferences.state.value.choice==choice&&graph.keyNotationPreferences.state.value.error==null}
                val rebuilt=KeyNotationPreferences(graph.directory.resolve("key-notation.v1.json"));rebuilt.load()
                assertEquals(choice,rebuilt.state.value.choice)
                compose.onNodeWithContentDescription("Close Settings").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
                reveal(hasContentDescription("More for Fixture 1")).performClick();click("Song details")
                compose.waitUntil(10000){graph.trackDetails.state.value.analysis!=null&&!graph.trackDetails.state.value.loading}
                compose.onNodeWithText(if(choice==KeyNotation.Musical)"Am" else "8A").assertExists()
                compose.onNodeWithText(if(choice==KeyNotation.Musical)"8A" else "Am").assertDoesNotExist()
                click("Correct analysis")
                compose.onNodeWithText("Current: Tempo not set · Am · 8A").assertExists()
                click("Key & Camelot")
                compose.onNodeWithContentDescription("Corrected musical key").assertExists()
                compose.onNodeWithContentDescription("Corrected Camelot").assertExists()
                compose.onNodeWithContentDescription("Back to Song details").performScrollTo().performClick()
                compose.onNodeWithContentDescription("Close Song details").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
                compose.runOnIdle {
                    assertSame(controller,model.controller);assertFalse(model.playback.value.isPlaying)
                    assertEquals(before.queue,model.playback.value.queue)
                    assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
                    assertTrue(writes.isEmpty())
                }
            }
        }finally {server.dispatcher=fallback;graph.session.retire()}
    }
}
