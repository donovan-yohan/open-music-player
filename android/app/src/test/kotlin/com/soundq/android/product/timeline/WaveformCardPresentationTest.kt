package com.soundq.android.product.timeline

import com.soundq.designsystem.appearanceColors
import soundq.design.generated.SoundQAppearance
import org.junit.Assert.*
import org.junit.Test
import androidx.compose.ui.graphics.Color

class WaveformCardPresentationTest {
    @Test fun guideKeepsItsSharedAxisButDoesNotOverpaintIdentityGlyphRegions() {
        val masks=listOf(androidx.compose.ui.geometry.Rect(10f,8f,100f,60f),androidx.compose.ui.geometry.Rect(10f,50f,100f,80f))
        assertEquals(listOf(0f to 8f,80f to 125f),waveformGuideSegments(125f,20f,masks))
        assertEquals(listOf(0f to 125f),waveformGuideSegments(125f,120f,masks))
    }
    @Test fun plotBackingFollowsResolvedChoiceNotSystemBrightness() {
        assertEquals(Color.White,waveformPlotBacking(appearanceColors(SoundQAppearance.Light,true)))
        assertEquals(Color(0xff090b0d),waveformPlotBacking(appearanceColors(SoundQAppearance.Dark,false)))
        assertEquals(Color.White,waveformPlotBacking(appearanceColors(SoundQAppearance.System,false)))
        assertEquals(Color(0xff090b0d),waveformPlotBacking(appearanceColors(SoundQAppearance.System,true)))
    }
    @Test fun normalAndEnlargedCardsRetainFiftySevenClearDpWithoutShrinkingText() {
        assertEquals(WaveformCardGeometry(125f,48f),waveformCardGeometry(1f,false,0f))
        assertEquals(WaveformCardGeometry(125f,60f),waveformCardGeometry(1f,true,53f))
        assertEquals(WaveformCardGeometry(165f,100f),waveformCardGeometry(1.3f,true,91f))
        val large=waveformCardGeometry(2f,true,140f)
        assertEquals(140f,large.cardHeight,0f)
        assertEquals(57f,large.bodyHeight-large.cardHeight-8f,0f)
    }
}
