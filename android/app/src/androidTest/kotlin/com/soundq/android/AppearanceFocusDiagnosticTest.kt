package com.soundq.android

import android.util.Log
import androidx.compose.runtime.*
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.InputModeManager
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.preferences.*
import com.soundq.android.product.preferences.AppearanceChoices
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Actual component and accepted file owner. Not the ordinary ProductApp route. */
class AppearanceFocusDiagnosticTest {
    @get:Rule val compose=createComposeRule()
    @Test fun actualChoicesDistinguishTouchRefusalFromKeyboardFocusAcrossAcceptedRepaint() {
        val file=File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,"focus-diagnostic-appearance.json")
        assertFalse(file.exists())
        val owner=AppearancePreferences(file).also {it.load()}
        lateinit var input:InputModeManager
        compose.setContent {
            input=LocalInputModeManager.current
            val state by owner.state.collectAsState()
            SoundQTheme(appearance=soundq.design.generated.SoundQAppearance.valueOf(state.choice.name)) { AppearanceChoices(owner) }
        }
        fun row(choice:Appearance)=compose.onNode(hasText(choice.name) and hasClickAction())
        fun observe(stage:String,choice:Appearance):Boolean {
            val node=row(choice).fetchSemanticsNode()
            val focused=node.config[SemanticsProperties.Focused]
            val mode=compose.runOnIdle {input.inputMode.toString()}
            val touch=compose.runOnIdle {(node.root as ViewRootForTest).view.isInTouchMode}
            Log.i("AppearanceFocusDiagnostic","stage=$stage choice=$choice id=${node.id} focused=$focused selected=${node.config[SemanticsProperties.Selected]} mode=$mode touch=$touch revision=${owner.state.value.revision}")
            return focused
        }
        try {
            compose.waitForIdle()
            compose.mainClock.advanceTimeByFrame();compose.waitForIdle()
            val light=row(Appearance.Light)
            val identity=light.fetchSemanticsNode().id
            compose.runOnIdle {assertTrue(input.requestInputMode(InputMode.Touch))}
            var touchRequest=true
            light.performSemanticsAction(SemanticsActions.RequestFocus){touchRequest=it()}
            assertFalse("SystemDefined clickable focus refuses Touch before click",touchRequest)
            assertFalse(observe("touch-before-click",Appearance.Light))
            light.performClick()
            assertFalse(observe("touch-after-input",Appearance.Light))
            compose.waitUntil(10000){owner.state.value.choice==Appearance.Light&&owner.state.value.error==null}
            light.assertIsSelected().assertIsNotFocused()
            assertFalse(observe("touch-accepted-repaint",Appearance.Light))
            assertEquals(identity,light.fetchSemanticsNode().id)
            compose.runOnIdle {assertTrue(input.requestInputMode(InputMode.Keyboard));assertEquals(InputMode.Keyboard,input.inputMode)}
            val dark=row(Appearance.Dark)
            var keyboardRequest=false
            dark.performSemanticsAction(SemanticsActions.RequestFocus){keyboardRequest=it()}
            assertTrue("Same actual row accepts keyboard focus",keyboardRequest)
            assertTrue(observe("keyboard-before-input",Appearance.Dark))
            dark.performKeyInput {pressKey(Key.Enter)}
            assertTrue(observe("keyboard-after-input",Appearance.Dark))
            compose.waitUntil(10000){owner.state.value.choice==Appearance.Dark&&owner.state.value.error==null}
            dark.assertIsSelected().assertIsFocused()
            assertTrue(observe("keyboard-accepted-repaint",Appearance.Dark))
            assertEquals(identity,light.fetchSemanticsNode().id)
            val rebuilt=AppearancePreferences(file).also {it.load()}
            assertEquals(Appearance.Dark,rebuilt.state.value.choice)
            // A later frame must not let initial focus steal this accepted row.
            compose.mainClock.advanceTimeByFrame();compose.waitForIdle()
            dark.assertIsFocused()
            assertTrue(observe("keyboard-later-frame",Appearance.Dark))
        } finally {file.delete()}
    }
}
