package com.soundq.designsystem

import org.junit.Assert.*
import org.junit.Test
import soundq.design.generated.SoundQAppearance
import soundq.design.generated.SoundQAppearanceMapping as M

class AppearancePaletteTest {
    @Test fun systemResolvesCurrentBrightnessWithoutPersistingIt() {
        assertEquals(M.light.semantic_color_background,appearanceColors(SoundQAppearance.System,false).background)
        assertEquals(M.dark.semantic_color_background,appearanceColors(SoundQAppearance.System,true).background)
    }
    @Test fun explicitChoicesIgnoreOppositeSystemBrightness() {
        assertEquals(M.light.semantic_color_text,appearanceColors(SoundQAppearance.Light,true).text)
        assertEquals(M.dark.semantic_color_text,appearanceColors(SoundQAppearance.Dark,false).text)
    }
}
