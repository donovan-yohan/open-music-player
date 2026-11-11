package com.soundq.android.product

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.soundq.android.data.LibraryAnalysisFacts
import com.soundq.android.data.preferences.KeyNotation
import com.soundq.android.data.preferences.KeyNotationState
import com.soundq.designsystem.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import soundq.design.generated.SoundQAppearance

/** Uses the accepted analysis model and actual consuming media row, fonts, and native ink. */
class LibraryMetadataReadabilityTest {
    @get:Rule val compose=createComposeRule()
    @Test fun narrowCamelotFactsPaintCompleteWithReferenceColours() = checkRow(320,1f,false,false)
    @Test fun normalMusicalFactsKeepCamelotColour() = checkRow(360,1f,true,false)
    @Test fun enlargedMusicalFactsReflowWithoutDroppingValues() = checkRow(320,2f,true,false)
    @Test fun enlargedLongMusicalFactsStayComplete() = checkRow(320,2f,true,false,longMusical=true)
    @Test fun darkCamelotUsesReferenceWheel() = checkRow(360,1f,false,true)
    @Test fun compactMetadataStillPaintsEveryFact() = checkRow(320,1.5f,true,false,true)
    @Test fun unknownMemberDurationKeepsCompleteNativeGlyphAndIdentity() {
        compose.setContent {SoundQTheme {Box(Modifier.width(320.dp)) {
            SoundQMediaRow("Unknown duration","Fixture artist",false,{},{},metadata={LibraryMetadataContent(memberDurationMetadata(0))})
        }}}
        saveFrame("unknown-duration")
        assertComplete("—:—")
        compose.onNodeWithContentDescription("Duration unavailable",substring=true).assertExists()
        compose.onNodeWithContentDescription("Unknown duration, Fixture artist",substring=true).assertHeightIsEqualTo(72.dp)
        compose.onNodeWithContentDescription("More for Unknown duration").assertWidthIsAtLeast(48.dp)
    }

    private fun checkRow(width:Int,scale:Float,musical:Boolean,dark:Boolean,compact:Boolean=false,longMusical:Boolean=false) {
        val musicalKey=if(longMusical)"C♯ minor" else "A minor"
        val camelot=if(longMusical)"12A" else "8A"
        val fields=libraryRowMetadata(222000,LibraryAnalysisFacts(bpm=128.0,musicalKey=musicalKey,camelot=camelot),
            KeyNotationState(ready=true,choice=if(musical)KeyNotation.Musical else KeyNotation.Camelot))
        var activated=0;var more=0
        var bpmBackground=Color.Unspecified;var bpmForeground=Color.Unspecified
        compose.setContent {
            val actual=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(actual.density,scale)) {
                SoundQTheme(appearance=if(dark)SoundQAppearance.Dark else SoundQAppearance.Light) {
                    bpmBackground=androidx.compose.material3.MaterialTheme.colorScheme.secondaryContainer
                    bpmForeground=androidx.compose.material3.MaterialTheme.colorScheme.onSecondaryContainer
                    Box(Modifier.width(width.dp).background(SoundQ.colors.background)) {
                        if(compact)CompositionLocalProvider(LocalMediaRowCompactMetadata provides true) {LibraryMetadataContent(fields)}
                        else SoundQMediaRow("Readability fixture","Fixture artist",true,{activated++},{more++},
                            metadata={LibraryMetadataContent(fields)})
                    }
                }
            }
        }
        saveFrame("$width-$scale-$musical-$dark-$compact-$longMusical")
        val compactPaint=compact||scale>=1.3f
        fields.forEach {field -> assertComplete(if(compactPaint&&field.display=="128 BPM")"128" else field.display)}
        // Independent Flutter wheel oracle: 8A is hue 210; light S=.78/V=.58, dark S=.68/V=.78.
        assertInk(if(compactPaint)"128" else "128 BPM",bpmBackground,bpmForeground)
        val keyBackground=if(longMusical)Color(0xFF94215A) else if(dark)Color(0xFF4083C7) else Color(0xFF215A94)
        assertInk(if(musical)musicalKey else camelot,keyBackground,if(dark)Color.Black else Color.White)
        if(!compact) {
            val row=compose.onNodeWithContentDescription("Readability fixture, Fixture artist",substring=true)
            val height=if(scale>=1.3f)106.dp else 72.dp
            assertTrue("Readable rows must retain the ordinary quick-queue width budget",swipeQueueGeometry(height,true).fits(width.dp))
            row.assertHeightIsEqualTo(height)
            compose.onNodeWithTag("media-artwork",useUnmergedTree=true).assertWidthIsEqualTo(height).assertHeightIsEqualTo(height)
            val rowBounds=row.fetchSemanticsNode().boundsInRoot
            val metadataBounds=compose.onNodeWithTag("library-row-metadata",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
            assertTrue("Metadata outside reserved row",metadataBounds.bottom<=rowBounds.bottom+1f)
            assertTrue(row.fetchSemanticsNode().config.contains(androidx.compose.ui.semantics.SemanticsProperties.Selected))
            compose.onNodeWithContentDescription("More for Readability fixture").assertWidthIsAtLeast(48.dp).performClick()
            compose.runOnIdle {assertEquals(1,more);assertEquals(0,activated)}
            row.performClick();compose.runOnIdle {assertEquals(1,activated)}
        }
    }
    private fun assertComplete(text:String) {
        val node=compose.onNodeWithText(text,useUnmergedTree=true).assertIsDisplayed()
        val layouts=mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) {it(layouts)}
        val layout=layouts.single()
        assertEquals(text,layout.layoutInput.text.text)
        assertFalse("Overflow for $text",layout.hasVisualOverflow)
        for(line in 0 until layout.lineCount)assertFalse("Ellipsis for $text",layout.isLineEllipsized(line))
        text.indices.filter { !text[it].isWhitespace() }.forEach {i ->
            val box=layout.getBoundingBox(i)
            assertTrue("Glyph clipped for $text at $i",box.left>=-1f && box.right<=layout.size.width+1f && box.bottom<=layout.size.height+1f)
        }
        val bounds=node.fetchSemanticsNode().boundsInRoot
        val host=compose.onNodeWithTag("library-row-metadata",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        assertTrue("Metadata escapes host",bounds.left>=host.left-1 && bounds.right<=host.right+1 && bounds.bottom<=host.bottom+1)
    }
    /** Synthetic mounted View raster, not an OS screenshot or production-account capture. */
    private fun saveFrame(label:String) {
        val view=(compose.onRoot().fetchSemanticsNode().root as androidx.compose.ui.platform.ViewRootForTest).view
        compose.runOnIdle {
            val image=android.graphics.Bitmap.createBitmap(view.width,view.height,android.graphics.Bitmap.Config.ARGB_8888)
            try {
                view.draw(android.graphics.Canvas(image))
                val context=androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
                java.io.File(context.filesDir,"library-readability-$label.png").outputStream().use {assertTrue(image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))}
            } finally {image.recycle()}
        }
    }
    private fun assertInk(text:String,background:Color,foreground:Color) {
        val semantics=compose.onNodeWithText(text,useUnmergedTree=true).fetchSemanticsNode()
        val bounds=semantics.boundsInRoot
        val view=(semantics.root as androidx.compose.ui.platform.ViewRootForTest).view
        var bg=0;var fg=0
        fun near(a:Color,b:Color)=kotlin.math.abs(a.red-b.red)<.025f && kotlin.math.abs(a.green-b.green)<.025f && kotlin.math.abs(a.blue-b.blue)<.025f
        compose.runOnIdle {
            val image=android.graphics.Bitmap.createBitmap(view.width,view.height,android.graphics.Bitmap.Config.ARGB_8888)
            try {
                view.draw(android.graphics.Canvas(image))
                for(y in kotlin.math.ceil(bounds.top).toInt() until kotlin.math.floor(bounds.bottom).toInt())
                    for(x in kotlin.math.ceil(bounds.left).toInt() until kotlin.math.floor(bounds.right).toInt()) {
                        val pixel=Color(image.getPixel(x,y))
                        if(near(pixel,background))bg++
                        if(near(pixel,foreground))fg++
                    }
            } finally {image.recycle()}
        }
        assertTrue("Missing chip background for $text ($background)",bg>4)
        assertTrue("Missing contrasting glyph ink for $text ($foreground)",fg>4)
    }
}
