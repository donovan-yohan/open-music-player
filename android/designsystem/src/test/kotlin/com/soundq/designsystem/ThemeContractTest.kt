package com.soundq.designsystem
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.TextUnit
import org.junit.Assert.*
import org.junit.Test
import soundq.design.generated.SoundQComposeTokens as T
class ThemeContractTest {
    @Test fun semanticColorsConsumeCanonicalTokens() {
        assertEquals(T.SEMANTIC_COLOR_PRIMARY, appearanceColors(soundq.design.generated.SoundQAppearance.Dark,false).primary)
        assertEquals(T.SEMANTIC_COLOR_TEXT, appearanceColors(soundq.design.generated.SoundQAppearance.Dark,false).text)
    }
    @Test fun nativeDimensionsAndTrackingAreTyped() {
        assertTrue(SoundQSizes.target >= 48.dp)
        val tracking: TextUnit = SoundQTypography.heading.letterSpacing
        assertEquals(T.SEMANTIC_LETTER_SPACING_HEADING, tracking)
        assertEquals(T.SEMANTIC_FONT_SIZE_H1, SoundQTypography.heading.fontSize)
    }
    @Test fun ordinaryMotionRetainsCanonicalDuration() {
        assertEquals(T.MOTION_DURATION_QUICK, SoundQMotion().selection.durationMillis)
    }
}
