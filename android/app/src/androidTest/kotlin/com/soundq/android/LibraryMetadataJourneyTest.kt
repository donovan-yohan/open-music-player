package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.preferences.KeyNotation
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/** Ordinary ProductApp hydration and Settings update, not a standalone row fixture. */
class LibraryMetadataJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun reveal(matcher:SemanticsMatcher):SemanticsNodeInteraction {
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(matcher)
        return compose.onNode(matcher).assertIsDisplayed().assertIsEnabled()
    }
    @Test fun compactFactsPaintAndSettingsNotationUpdatesWithoutRefetchOrPlayback() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val pages=AtomicInteger();val analysisReads=AtomicInteger()
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            if(request.url.encodedPath=="/api/v1/library") {
                val fields=request.url.queryParameter("fields").orEmpty().split(',')
                assertTrue("analysis_summary" in fields);assertTrue("analysis_status" in fields)
                pages.incrementAndGet()
                return MockResponse.Builder().body("""{"tracks":[{"id":7,"title":"Metadata song 音楽","artist":"Synthetic ensemble","duration_ms":222999,"is_liked":true,"analysis_status":"analyzed","analysis_summary":{"bpm":{"value":127.5},"key":{"value":"A minor"},"camelot":{"value":"8A"}}}],"total":1,"limit":20,"offset":0}""").build()
            }
            if(request.url.encodedPath.endsWith("/analysis"))analysisReads.incrementAndGet()
            return fallback.dispatch(request)
        }}
        val row=hasText("Metadata song 音楽") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Metadata song 音楽"))
        fun speech(key:String)="Duration 3 minutes 42 seconds, Tempo 128 BPM, Key $key"
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("library-metadata@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.rows.singleOrNull()?.id?.value==7L&&graph.keyNotationPreferences.state.value.ready}
            reveal(row)
            compose.onNodeWithContentDescription(speech("8A"),useUnmergedTree=true).assertIsDisplayed()
            compose.onNode(hasText("Liked") and hasAnyAncestor(hasClickAction() and hasAnyDescendant(hasContentDescription("More for Metadata song 音楽"))),useUnmergedTree=true).assertIsDisplayed()
            val before=graph.controller.state.value
            val captured=graph.library.captureTrack(graph.library.state.value.rows.single())!!
            val hydratedPages=pages.get()
            for(choice in listOf(KeyNotation.Musical,KeyNotation.Camelot)) {
                reveal(hasContentDescription("Account and preview information")).performClick()
                compose.onNode(hasText("Settings") and hasClickAction()).performScrollTo().performClick()
                compose.onNode(hasText(if(choice==KeyNotation.Musical)"Musical key" else "Camelot") and hasClickAction()).performScrollTo().performClick()
                compose.waitUntil(10000){graph.keyNotationPreferences.state.value.choice==choice&&graph.keyNotationPreferences.state.value.error==null}
                compose.onNodeWithContentDescription("Close Settings").performScrollTo().performClick()
                reveal(row)
                compose.onNodeWithContentDescription(speech(if(choice==KeyNotation.Musical)"A minor" else "8A"),useUnmergedTree=true).assertIsDisplayed()
                compose.runOnIdle {
                    assertTrue(graph.library.owns(captured))
                    assertEquals(before.queue,graph.controller.state.value.queue)
                    assertEquals(before.selectedOccurrence,graph.controller.state.value.selectedOccurrence)
                    assertFalse(graph.controller.state.value.isPlaying)
                }
                assertEquals("Notation changes must use the existing facts",hydratedPages,pages.get())
                assertEquals("No per-row analysis request",0,analysisReads.get())
            }
            val more=compose.onNodeWithContentDescription("More for Metadata song 音楽").assertIsDisplayed().assertIsEnabled()
            more.assertWidthIsAtLeast(androidx.compose.ui.unit.Dp(48f));more.assertHeightIsAtLeast(androidx.compose.ui.unit.Dp(48f))
        }finally {server.dispatcher=fallback;graph.session.retire()}
    }
}
