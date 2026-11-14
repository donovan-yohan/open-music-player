package com.soundq.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.data.home.*
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.home.HomeDestinationScreen
import com.soundq.designsystem.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Actual history caller and native TextLayoutResult, not a lookalike row or semantic-only fit. */
class HistoryFactsFitTest {
    @get:Rule val compose=createComposeRule()

    @Test fun enlargedHistoryKeepsCompleteNativeGlyphsAndEventFacts() = history(2f)
    @Test fun normalHistoryKeeps72DpAndCompleteEventFacts() = history(1f)
    @Test fun enlargedUnavailableHistoryKeepsMetadataAndContextOnIndependentLines() = history(2f,unavailable=true)

    private fun history(scale:Float,unavailable:Boolean=false) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val server=ProductTransportFixture.server
        val delegate=server.dispatcher
        val models=ViewModelStore()
        val lifetime=HomeRouteLifetime()
        val route=lifetime.enter(HomeDestination.History)
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            if(request.url.encodedPath!="/api/v1/me/plays/history")return delegate.dispatch(request)
            return MockResponse.Builder().body("""{"plays":[{"id":2,"track":{"id":7,"title":"ÉCHO","artist":"Beyoncé","inLibrary":${!unavailable}${if(unavailable)",\"durationMs\":222000"else ""}},"playedAt":"2026-10-28T00:00:00Z","skipped":$unavailable${if(unavailable)",\"contextType\":\"album\""else ""}}],"limit":50,"offset":0}""").build()
        }}
        try {
            val model=compose.runOnIdle {
                app.graph.session.accept(app.graph.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh","history-fit"))
                ProductViewModel(app).also {models.put("history-fit",it)}
            }
            compose.setContent {
                val actual=LocalDensity.current
                CompositionLocalProvider(LocalDensity provides Density(actual.density,scale)) {
                    SoundQTheme {Box(Modifier.requiredWidth(360.dp).fillMaxHeight().background(SoundQ.colors.background)) {
                        HomeDestinationScreen(model,route,{},{})
                    }}
                }
            }
            compose.waitUntil(10000){model.home.history.value.rows.size==1&&!model.home.history.value.loading}
            compose.onNodeWithText("ÉCHO",useUnmergedTree=true).assertIsDisplayed()
            saveFrame("history-${if(unavailable)"unavailable-"else ""}$scale")
            assertFits("ÉCHO")
            assertFits("Beyoncé",complete=true)
            java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"history-semantics.txt").writeText(compose.onRoot(useUnmergedTree=true).printToString())
            val facts=compose.onNode(hasText("2026",substring=true),useUnmergedTree=true).fetchSemanticsNode()
            val text=facts.config[androidx.compose.ui.semantics.SemanticsProperties.Text].single().text
            val layout=assertFits(text,complete=true)
            assertTrue("Event status must precede time",text.startsWith(if(unavailable)"Skipped · "else "Listened · "))
            val row=compose.onNode(hasText("ÉCHO") and hasClickAction())
            val rowBounds=row.fetchSemanticsNode().boundsInRoot
            val density=app.resources.displayMetrics.density
            if(scale>1f)assertTrue("Enlarged facts should wrap",layout.lineCount>1)
            else row.assertHeightIsEqualTo(72.dp)
            compose.onNodeWithTag("media-artwork",useUnmergedTree=true).assertWidthIsEqualTo(72.dp).assertHeightIsEqualTo(72.dp)
            compose.onNodeWithContentDescription("More for ÉCHO").assertWidthIsEqualTo(48.dp).assertHeightIsAtLeast(48.dp)
            assertTrue("History facts must stay inside their measured row",facts.boundsInRoot.bottom<=rowBounds.bottom+1f)
            assertEquals("History facts own the full text lane",rowBounds.width-(72+48+16)*density,facts.boundsInRoot.width,1f)
            if(unavailable) {
                assertTrue(text.endsWith(" · album · Not in your library"))
                assertFits("3:42",complete=true)
                val meta=compose.onNodeWithTag("library-row-metadata",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
                assertTrue("Facts have their own line below real metadata",meta.bottom<=facts.boundsInRoot.top+1f)
                row.assertIsNotEnabled()
            } else {
                compose.onNodeWithTag("library-row-metadata",useUnmergedTree=true).assertDoesNotExist()
                assertTrue("Natural history height must retain quick-queue width admission",swipeQueueGeometry((rowBounds.height/density).dp,false).fits(360.dp))
            }
            assertFalse(model.playback.value.isPlaying)
        } finally {
            compose.runOnIdle {lifetime.close();models.clear()}
            server.dispatcher=delegate
        }
    }

    private fun assertFits(text:String,complete:Boolean=false):TextLayoutResult {
        val layouts=mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(text,useUnmergedTree=true).performSemanticsAction(SemanticsActions.GetTextLayoutResult){it(layouts)}
        val layout=layouts.single()
        assertTrue("Native glyphs clipped vertically: $text; allocated=${layout.size.height}, paragraph=${layout.multiParagraph.height}",layout.size.height.toFloat()>=layout.multiParagraph.height)
        if(complete) {
            val node=compose.onNodeWithText(text,useUnmergedTree=true).fetchSemanticsNode()
            val diagnostic="text=$text input=${layout.layoutInput.text.text} size=${layout.size} bounds=${node.boundsInRoot} paragraph=${layout.multiParagraph.height} overflow=${layout.hasVisualOverflow} lines=${layout.lineCount} ends=${(0 until layout.lineCount).map {layout.getLineEnd(it,visibleEnd=true)}} ellipsis=${(0 until layout.lineCount).map {layout.isLineEllipsized(it)}}"
            java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"history-layout.txt").writeText(diagnostic)
            assertEquals("Native layout must contain the complete fact",text,layout.layoutInput.text.text)
            assertFalse("Essential event facts truncated: $diagnostic",layout.hasVisualOverflow)
            text.indices.filter {!text[it].isWhitespace()}.forEach {i ->
                val glyph=layout.getBoundingBox(i)
                assertTrue("Essential event facts truncated at glyph $i: $diagnostic",glyph.left>=-1f&&glyph.right<=node.boundsInRoot.width+1f&&glyph.bottom<=node.boundsInRoot.height+1f)
            }
        }
        return layout
    }

    /** Synthetic mounted View raster, not OS screenshot or phone capture. */
    private fun saveFrame(label:String) {
        val view=(compose.onRoot().fetchSemanticsNode().root as androidx.compose.ui.platform.ViewRootForTest).view
        compose.runOnIdle {
            val bitmap=android.graphics.Bitmap.createBitmap(view.width,view.height,android.graphics.Bitmap.Config.ARGB_8888)
            try {
                view.draw(android.graphics.Canvas(bitmap))
                java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"$label.png").outputStream().use {
                    assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))
                }
            } finally {bitmap.recycle()}
        }
    }
}
