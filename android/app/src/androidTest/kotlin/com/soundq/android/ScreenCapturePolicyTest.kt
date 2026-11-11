package com.soundq.android

import android.graphics.Rect
import android.view.WindowManager
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ScreenCapturePolicyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    @Test fun mainActivityAllowsScreenCaptureBeforeAndAfterRecreation() {
        assertMainWindowCapturable()
        compose.activityRule.scenario.recreate()
        assertMainWindowCapturable()
    }

    private fun assertMainWindowCapturable() {
        compose.waitForIdle()
        val bounds=compose.runOnIdle {
            assertEquals("MainActivity must allow screenshots and screen recording",0,
                compose.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE)
            Rect().also {
                assertTrue("Product content must be visible",
                    compose.activity.findViewById<android.view.View>(android.R.id.content).getGlobalVisibleRect(it))
            }
        }
        val image=checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()) {
            "System screenshot must be available"
        }
        try {
            // Inspect the middle of the app, excluding system bars and their visible pixels.
            assertTrue("Product bounds must fit inside the system screenshot",
                bounds.left>=0&&bounds.top>=0&&bounds.right<=image.width&&bounds.bottom<=image.height)
            val left=bounds.left+bounds.width()/4
            val top=bounds.top+bounds.height()/3
            val width=bounds.width()/2
            val height=bounds.height()/3
            assertTrue("Product screenshot region must not be empty",width>0&&height>0)
            val pixels=IntArray(width*height)
            image.getPixels(pixels,0,width,left,top,width,height)
            assertTrue("System screenshot must contain app content, not a secure-window black frame",
                pixels.any { (it ushr 24)!=0 && (it and 0x00ffffff)!=0 })
        } finally {image.recycle()}
    }
}
