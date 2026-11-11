package com.soundq.designsystem

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class SettingsIconTest {
    @get:Rule val compose=createComposeRule()

    @Test fun sharedSettingsGlyphHasCenteredOpenHubAndSymmetricUnclippedTeeth() {
        compose.setContent {
            SoundQTheme {
                Box(Modifier.size(24.dp).background(Color.White).testTag("settings-glyph")) {
                    SoundQIcon(SoundQIcon.Settings,"Settings",tint=Color.Black)
                }
            }
        }
        compose.onNodeWithContentDescription("Settings").assertIsDisplayed()
        val image=compose.onNodeWithTag("settings-glyph").captureToImage()
        val file=File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"settings-icon.png")
        file.outputStream().use { image.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it) }
        val pixels=image.toPixelMap()
        val w=pixels.width;val h=pixels.height
        assertEquals(w,h)
        fun ink(x:Int,y:Int)=1f-pixels[x,y].red
        var total=0.0;var weightX=0.0;var weightY=0.0;var rotatedDifference=0.0
        for(y in 0 until h)for(x in 0 until w) {
            val value=ink(x,y).toDouble()
            total+=value;weightX+=value*x;weightY+=value*y
            rotatedDifference+=kotlin.math.abs(value-ink(w-1-y,x))
        }
        assertTrue("Gear must paint a recognizable outline",total>w*h*.12)
        assertTrue("Quarter-turn symmetry must not be mangled",rotatedDifference/total<.08)
        assertEquals((w-1)/2.0,weightX/total,.4)
        assertEquals((h-1)/2.0,weightY/total,.4)
        for(y in 0 until h)for(x in 0 until w) {
            val dx=(x+.5)/w*24-12;val dy=(y+.5)/h*24-12
            if(dx*dx+dy*dy<1.5*1.5)assertTrue("Central hub must remain open",ink(x,y)<.05)
        }
        for(i in 0 until w) {
            assertTrue("Outline must not touch viewport edges",ink(i,0)<.05&&ink(i,h-1)<.05&&ink(0,i)<.05&&ink(w-1,i)<.05)
        }
    }
}
