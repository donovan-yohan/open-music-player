package com.soundq.designsystem

import android.view.Window
import android.view.WindowInsetsController
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.window.DialogWindowProvider
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import soundq.design.generated.SoundQAppearance

/** Real Compose Dialog/window flags on the host. Device SystemUI contrast remains a runtime gate. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class SharedPlayerBarsRepairTest {
    @get:Rule val compose=createComposeRule()

    @Test fun sameDialogUpdatesBothSystemBarAppearancesFromResolvedTheme() {
        val appearance=mutableStateOf(SoundQAppearance.Light)
        val open=mutableStateOf(true)
        var dialog:Window?=null
        var transport=0
        compose.setContent {SoundQTheme(appearance=appearance.value) {
            if(open.value)SoundQFullPlayer("Song","Artist",false,true,false,65000,0,"same",
                {open.value=false},{transport++},{transport++},{},artwork={
                    dialog=(LocalView.current.parent as DialogWindowProvider).window
                })
        }}
        compose.onNodeWithTag("player-window",useUnmergedTree=true).assertIsDisplayed()
        val original=checkNotNull(dialog)
        fun checkBars(light:Boolean) {
            compose.runOnIdle {
                assertSame(original,dialog)
                val flags=original.insetsController!!.systemBarsAppearance
                assertEquals(light,flags and WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS != 0)
                assertEquals(light,flags and WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS != 0)
            }
        }
        checkBars(true)
        compose.runOnIdle {appearance.value=SoundQAppearance.Dark}
        checkBars(false)
        compose.runOnIdle {appearance.value=SoundQAppearance.Light}
        checkBars(true)
        compose.onNodeWithContentDescription("Close Now playing").performClick()
        compose.onNodeWithTag("player-window",useUnmergedTree=true).assertDoesNotExist()
        compose.runOnIdle {assertEquals(0,transport)}
    }
}
