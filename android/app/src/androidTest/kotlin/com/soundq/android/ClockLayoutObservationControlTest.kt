package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.designsystem.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import kotlin.math.*

/** Diagnostic API controls, not an ordinary app journey or a production repair. */
class ClockLayoutObservationControlTest {
    @get:Rule val compose=createComposeRule()
    private data class Observed(val width:Float,val layout:TextLayoutResult,val ink:List<Int>) {
        val complete:Boolean get() = layout.lineCount==1 &&
            layout.multiParagraph.intrinsics.maxIntrinsicWidth<=width+.5f &&
            layout.layoutInput.text.text.indices.all {i->
                val glyph=layout.getBoundingBox(i)
                glyph.left>=-.5f && glyph.right<=width+.5f
            } && ink.all {it>0}
        override fun toString()="allocated=$width size=${layout.size} natural=${layout.multiParagraph.intrinsics.maxIntrinsicWidth} paragraph=${layout.multiParagraph.width} lineCount=${layout.lineCount} lineRight=${layout.getLineRight(0)} overflowFlag=${layout.didOverflowWidth} ink=$ink complete=$complete"
    }
    private fun observe(tag:String):Observed {
        val node=compose.onNodeWithTag(tag).assertIsDisplayed()
        val layouts=mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult){it(layouts)}
        val layout=layouts.single()
        val semantics=node.fetchSemanticsNode()
        val bounds=semantics.boundsInRoot
        val ink=compose.runOnIdle {
            val view=(semantics.root as ViewRootForTest).view
            val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
            try {
                view.draw(Canvas(bitmap))
                val background=bitmap.getPixel(floor(bounds.left).toInt(),floor(bounds.top).toInt())
                layout.layoutInput.text.text.indices.filter {!layout.layoutInput.text.text[it].isWhitespace()}.map {i->
                    val glyph=layout.getBoundingBox(i)
                    var count=0
                    for(y in max(0,ceil(bounds.top+glyph.top).toInt()) until min(bitmap.height,floor(bounds.top+glyph.bottom).toInt()))
                        for(x in max(0,ceil(bounds.left+glyph.left).toInt()) until min(bitmap.width,floor(bounds.left+glyph.right).toInt()))
                            if(x>=bounds.left && x<bounds.right && y>=bounds.top && y<bounds.bottom && bitmap.getPixel(x,y)!=background)count++
                    count
                }
            } finally {bitmap.recycle()}
        }
        return Observed(bounds.width,layout,ink)
    }
    @Test fun simpleStringSemanticsFlagIsNotThePaintedClockWidthOracle() {
        compose.setContent {SoundQTheme {
            Column(Modifier.fillMaxSize().background(SoundQ.colors.player)) {
                Box(Modifier.width(176.dp)) {
                    Text("0:06 / 0:12",Modifier.testTag("fitting-clock"),style=SoundQ.typography.mono,color=SoundQ.colors.text,softWrap=false)
                }
                Box(Modifier.width(24.dp)) {
                    Text("0:06 / 0:12",Modifier.testTag("clipped-clock"),style=SoundQ.typography.mono,color=SoundQ.colors.text,softWrap=false)
                }
            }
        }}
        val fitting=observe("fitting-clock")
        val clipped=observe("clipped-clock")
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val label=InstrumentationRegistry.getArguments().getString("captureLabel") ?: "clock-controls"
        require(label.matches(Regex("[a-zA-Z0-9-]+")))
        val dir=File(instrumentation.targetContext.getExternalFilesDir(null),"listening-20261105/$label")
        check(dir.mkdirs()||dir.isDirectory)
        File(dir,"clock-layout-controls.txt").writeText("fitting=$fitting\nclipped=$clipped\n")
        assertTrue("Full clock must fit and paint in the wide positive control: $fitting",fitting.complete)
        assertTrue("Pinned simple-String semantics reconstructs a wider paragraph: $fitting",fitting.layout.multiParagraph.width>fitting.width)
        assertTrue("Retain the actual misleading legacy flag as diagnostic evidence",fitting.layout.didOverflowWidth)
        assertFalse("A genuinely narrow/clipped clock must fail the natural/glyph/paint oracle: $clipped",clipped.complete)
        assertTrue(clipped.layout.multiParagraph.intrinsics.maxIntrinsicWidth>clipped.width)
    }
}
