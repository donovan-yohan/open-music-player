package com.soundq.designsystem
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
class ComponentTest {
    @get:Rule val compose = createComposeRule()
    @Test fun iconActionUsesCallerStateAndDisabledCannotDispatch() {
        var count = 0
        compose.setContent { SoundQTheme {
            androidx.compose.foundation.layout.Column {
                SoundQIconButton(SoundQIcon.Check, "Select fixture", { count++ }, selected = true)
                SoundQIconButton(SoundQIcon.Play, "Unavailable playback", { count++ }, enabled = false)
            }
        } }
        compose.onNodeWithContentDescription("Select fixture").assertIsSelected().performClick()
        compose.onNodeWithContentDescription("Unavailable playback").assertIsNotEnabled().performTouchInput { click() }
        compose.runOnIdle { assertEquals(1, count) }
    }
    @Test fun fieldEditsRealTextAndReportsValidation() {
        compose.setContent { SoundQTheme {
            var text by remember { mutableStateOf("") }
            SoundQTextField(text, { text = it }, "Fixture query", error = "Example validation")
        } }
        compose.onNodeWithText("Fixture query").performTextInput("海辺")
        compose.onNodeWithText("海辺").assertExists()
        compose.onNodeWithText("Example validation").assertExists()
    }
    @Test fun rowWrapsAtDoubleNativeFontScaleAndRetainsAction() {
        var selected = false
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) {
                SoundQTheme {
                    SoundQRow("A deliberately long synthetic fixture title that wraps", "Synthetic artist", false, { selected = true })
                }
            }
        }
        compose.onNodeWithText("A deliberately long synthetic fixture title that wraps").performClick()
        compose.runOnIdle { assertEquals(true, selected) }
    }
}
