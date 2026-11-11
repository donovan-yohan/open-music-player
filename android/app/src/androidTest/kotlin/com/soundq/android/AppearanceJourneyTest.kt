package com.soundq.android

import android.app.UiModeManager
import android.content.res.Configuration
import androidx.compose.ui.test.*
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.semantics.SemanticsProperties
import soundq.design.generated.SoundQAppearanceMapping
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.findViewTreeLifecycleOwner
import androidx.compose.ui.semantics.getOrNull
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.preferences.*
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Compiled-only until separately granted exclusive Android runtime. Synthetic HTTPS fixture. */
class AppearanceJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    /** Navigation-only discriminator. No playback, choices, uiMode or paint matrix. */
    @Test fun ordinarySettingsAppearanceCloseReopenBackPreservesMountedSettings() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val graph=(instrumentation.targetContext.applicationContext as FixtureApplication).graph
        val phases=org.json.JSONArray();val lifecycle=org.json.JSONArray()
        val observer=androidx.lifecycle.LifecycleEventObserver {_,event->if(lifecycle.length()<64)lifecycle.put(org.json.JSONObject().put("event",event.name).put("uptimeMs",android.os.SystemClock.uptimeMillis()))}
        var primary:Throwable?=null
        fun observe(stage:String) {
            val phase=org.json.JSONObject().put("stage",stage).put("uptimeMs",android.os.SystemClock.uptimeMillis());phases.put(phase)
            // Observe native ownership before Compose's idle synchronization after Android Back.
            instrumentation.runOnMainSync {
                val activity=compose.activity;val view=activity.window.decorView
                phase.put("activity",System.identityHashCode(activity)).put("lifecycle",activity.lifecycle.currentState.name)
                    .put("decor",System.identityHashCode(view)).put("attached",view.isAttachedToWindow)
                    .put("windowFocus",activity.hasWindowFocus()).put("touchMode",view.isInTouchMode)
                    .put("nativeFocus",view.findFocus()?.let(System::identityHashCode))
            }
            val trees=org.json.JSONObject();phase.put("trees",trees)
            for(unmerged in listOf(false,true)) {
                val nodes=compose.onAllNodes(SemanticsMatcher("navigation snapshot"){true},useUnmergedTree=unmerged).fetchSemanticsNodes()
                val rows=org.json.JSONArray();val roots=java.util.IdentityHashMap<Any,org.json.JSONObject>()
                for(node in nodes) {
                    val root=node.root ?: continue;val config=node.config
                    if(!roots.containsKey(root)) {
                        val view=(root as? ViewRootForTest)?.view
                        roots[root]=org.json.JSONObject().put("identity",System.identityHashCode(root)).put("class",root.javaClass.name)
                            .put("viewIdentity",view?.let(System::identityHashCode)).put("attached",view?.isAttachedToWindow)
                            .put("windowFocus",view?.hasWindowFocus()).put("touchMode",view?.isInTouchMode)
                            .put("lifecycle",view?.findViewTreeLifecycleOwner()?.lifecycle?.currentState?.name)
                    }
                    val texts=config.getOrNull(SemanticsProperties.Text)?.map {it.text}.orEmpty()
                    val descriptions=config.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
                    val scroll=config.getOrNull(SemanticsProperties.VerticalScrollAxisRange)
                    if(texts.isNotEmpty()||descriptions.isNotEmpty()||scroll!=null||config.contains(SemanticsProperties.Heading))rows.put(org.json.JSONObject()
                        .put("id",node.id).put("root",System.identityHashCode(root)).put("parent",node.parent?.id)
                        .put("heading",config.contains(SemanticsProperties.Heading)).put("text",org.json.JSONArray(texts))
                        .put("descriptions",org.json.JSONArray(descriptions)).put("bounds",node.boundsInRoot.toString())
                        .put("focused",config.getOrNull(SemanticsProperties.Focused)).put("enabled",!config.contains(SemanticsProperties.Disabled))
                        .put("click",config.contains(androidx.compose.ui.semantics.SemanticsActions.OnClick))
                        .put("scroll",scroll?.value?.invoke()).put("scrollMax",scroll?.maxValue?.invoke()))
                }
                trees.put(if(unmerged)"unmerged" else "merged",org.json.JSONObject().put("nodeCount",nodes.size).put("nodes",rows).put("roots",org.json.JSONArray(roots.values.toList())))
            }
        }
        graph.session.retire()
        compose.runOnIdle {compose.activity.lifecycle.addObserver(observer)}
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("appearance-navigation@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.rows.size>=3&&graph.appearancePreferences.state.value.ready}
            compose.onNodeWithContentDescription("Account and settings").assertIsDisplayed().assertIsEnabled().performClick()
            compose.onNode(hasText("Settings") and hasClickAction()).performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
            val opener=compose.onNodeWithContentDescription("Choose appearance").performScrollTo().assertIsDisplayed().assertIsEnabled()
            val settingsRoot=opener.fetchSemanticsNode().root;val settingsBounds=opener.fetchSemanticsNode().boundsInRoot
            fun offset()=compose.onNode(hasScrollAction() and hasAnyDescendant(hasContentDescription("Choose appearance")))
                .fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()
            val settingsOffset=offset();assertTrue("Appearance opener requires nonzero Settings scroll",settingsOffset>0f)
            fun assertReturn(stage:String) {
                compose.onNodeWithText("Choose how SoundQ looks on this device.").assertDoesNotExist()
                compose.onNodeWithContentDescription("Close Appearance").assertDoesNotExist()
                val heading=compose.onNode(hasText("Settings") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading)).assertExists()
                opener.assertIsDisplayed().assertIsEnabled().assertIsFocused()
                val returned=opener.fetchSemanticsNode()
                assertSame("$stage retains mounted Settings root",settingsRoot,returned.root)
                assertSame("$stage heading belongs to mounted Settings root",settingsRoot,heading.fetchSemanticsNode().root)
                assertEquals("$stage preserves opener bounds",settingsBounds,returned.boundsInRoot)
                assertEquals("$stage preserves Settings scroll",settingsOffset,offset(),0f)
            }
            observe("before-open")
            opener.performClick()
            compose.onNodeWithText("Choose how SoundQ looks on this device.").assertExists()
            instrumentation.setInTouchMode(false)
            val close=compose.onNodeWithContentDescription("Close Appearance").assertIsDisplayed().assertIsEnabled()
            close.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus){assertTrue(it())}
            close.assertIsFocused()
            observe("before-close")
            instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_DPAD_CENTER)
            observe("after-close");assertReturn("Close")
            instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_DPAD_CENTER)
            compose.onNodeWithText("Choose how SoundQ looks on this device.").assertExists()
            compose.onNodeWithContentDescription("Close Appearance").assertExists()
            observe("before-back")
            instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            observe("after-back");assertReturn("Back")
        } catch(failure:Throwable) {
            primary=failure
            try {observe("failure")}catch(diagnostic:Throwable){failure.addSuppressed(diagnostic)}
            throw failure
        } finally {
            try {
                compose.runOnIdle {compose.activity.lifecycle.removeObserver(observer)}
                instrumentation.targetContext.filesDir.resolve("appearance-back-diagnostic.json").writeText(org.json.JSONObject()
                    .put("phases",phases).put("lifecycle",lifecycle).put("failureClass",primary?.javaClass?.name).toString())
            }catch(diagnostic:Throwable){val failure=primary;if(failure!=null)failure.addSuppressed(diagnostic) else throw diagnostic}
            finally {graph.session.retire()}
        }
    }
    private fun assertMountedSheetPaint(dark:Boolean) {
        // Measure only the empty layout spacing between the heading and instruction text.
        // Reject an empty/clipped region rather than sampling glyphs or radio-row focus paint.
        val headingNode=compose.onNode(hasText("Appearance") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading)).fetchSemanticsNode()
        val instructionNode=compose.onNodeWithText("Choose how SoundQ looks on this device.").fetchSemanticsNode()
        val heading=headingNode.boundsInRoot
        val instruction=instructionNode.boundsInRoot
        assertSame("Heading and instruction belong to the same mounted sheet root",headingNode.root,instructionNode.root)
        val root=instructionNode.root as ViewRootForTest
        // Rasterize the actual mounted Compose root for bounded sheet-paint assertions.
        // MainActivity and its inherited modal policy permit system screen capture.
        val image=compose.runOnIdle {
            assertTrue(compose.activity.window.attributes.flags and android.view.WindowManager.LayoutParams.FLAG_SECURE == 0)
            val view=root.view
            assertTrue(view.width>0&&view.height>0)
            android.graphics.Bitmap.createBitmap(view.width,view.height,android.graphics.Bitmap.Config.ARGB_8888).also {
                view.draw(android.graphics.Canvas(it))
            }.asImageBitmap()
        }
        val pixels=image.toPixelMap()
        val left=kotlin.math.ceil(maxOf(heading.left,instruction.left)).toInt()+1
        val right=kotlin.math.floor(minOf(heading.right,instruction.right)).toInt()-1
        val top=kotlin.math.ceil(heading.bottom).toInt()+1
        val bottom=kotlin.math.floor(instruction.top).toInt()-1
        assertTrue("Measured heading-to-instruction background gap must be visible",left>=0&&right<image.width&&top>=0&&bottom<image.height&&right>left&&bottom>top)
        val expected=(if(dark)SoundQAppearanceMapping.dark else SoundQAppearanceMapping.light).w9_color_sheet_background.toArgb()
        for(y in top..bottom)for(x in left..right) {
            val actual=pixels[x,y].toArgb()
            for(shift in listOf(0,8,16,24))assertTrue("Mounted Appearance sheet paint at ($x,$y), expected ${expected.toUInt().toString(16)}, got ${actual.toUInt().toString(16)}",kotlin.math.abs(((actual ushr shift) and 255)-((expected ushr shift) and 255))<=2)
        }
    }
    @Test fun settingsChoicesPersistAndRepaintMountedProductWithoutAutoplayOrQueueReplacement() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        graph.session.retire()
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("appearance@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){graph.library.state.value.rows.size>=3&&graph.appearancePreferences.state.value.ready}
        val activity=compose.activity
        val model=compose.runOnIdle {ViewModelProvider(activity)[ProductViewModel::class.java]}
        val controller=model.controller
        try {
            // Read-only diagnostics preserve the original predicate, deadlines and Pause dispatch.
            val pauseDiagnostic=compose.runOnIdle {PauseBoundaryDiagnostic(model,graph.session::version)}
            var pauseFailure:Throwable?=null
            val paused=try {
                compose.runOnIdle {model.play(0,graph.library.state.value.rows)}
                compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
                compose.runOnIdle {pauseDiagnostic.beforePause();model.controller.pause()}
                compose.settledPausedPlayback(model)
            } catch(primary:Throwable) {pauseFailure=primary;throw primary}
            finally {
                try {compose.runOnIdle {pauseDiagnostic.close()}}
                catch(diagnostic:Throwable) {val primary=pauseFailure;if(primary!=null)primary.addSuppressed(diagnostic) else throw diagnostic}
            }
            compose.onNodeWithContentDescription("Account and settings").performClick()
            compose.onNodeWithText("Settings").performClick()
            val opener=compose.onNodeWithContentDescription("Choose appearance").performScrollTo()
            // Settings owns a retained viewport, not a heading fixed above its scroll.
            // Capture it before opening so Close/Back cannot pass by resetting to the top.
            val settingsRoot=opener.fetchSemanticsNode().root
            val settingsBounds=opener.fetchSemanticsNode().boundsInRoot
            fun readSettingsOffset()=compose.onNode(hasScrollAction() and hasAnyDescendant(hasContentDescription("Choose appearance")))
                .fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()
            val capturedSettingsOffset=readSettingsOffset()
            assertTrue("Appearance opener requires a nonzero Settings scroll",capturedSettingsOffset>0f)
            fun assertSettingsReturn(stage:String) {
                compose.onNodeWithText("Choose how SoundQ looks on this device.").assertDoesNotExist()
                compose.onNodeWithContentDescription("Close Appearance").assertDoesNotExist()
                val heading=compose.onNode(hasText("Settings") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
                heading.assertExists()
                opener.assertIsDisplayed().assertIsFocused()
                val returned=opener.fetchSemanticsNode()
                assertSame("$stage retains the mounted sheet root",settingsRoot,returned.root)
                assertSame("$stage Settings heading belongs to that root",settingsRoot,heading.fetchSemanticsNode().root)
                assertEquals("$stage retains Settings scroll",capturedSettingsOffset,readSettingsOffset(),0f)
                assertEquals("$stage retains opener viewport bounds",settingsBounds,returned.boundsInRoot)
                android.util.Log.i("AppearanceReturn",org.json.JSONObject().put("stage",stage)
                    .put("scroll",readSettingsOffset()).put("openerBounds",returned.boundsInRoot.toString())
                    .put("headingBounds",heading.fetchSemanticsNode().boundsInRoot.toString())
                    .put("openerFocused",returned.config[SemanticsProperties.Focused])
                    .put("sameRoot",returned.root===settingsRoot).toString())
            }
            android.util.Log.i("AppearanceReturn",org.json.JSONObject().put("stage","before-open")
                .put("scroll",capturedSettingsOffset).put("openerBounds",settingsBounds.toString()).toString())
            opener.performClick()
            val light=compose.onNode(hasText("Light") and hasClickAction())
            val node=light.fetchSemanticsNode().id
            // RequestFocus does not enter keyboard mode. Android performClick is touch input,
            // and SystemDefined clickable focus is unavailable in that mode in pinned Compose.
            val instrumentation=InstrumentationRegistry.getInstrumentation()
            instrumentation.setInTouchMode(false)
            val appearanceRoot=light.fetchSemanticsNode().root as ViewRootForTest
            compose.runOnIdle {assertFalse(appearanceRoot.view.isInTouchMode)}
            light.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus){it()}
            for(choice in listOf(Appearance.Light,Appearance.Dark,Appearance.System)) {
                val row=compose.onNode(hasText(choice.name) and hasClickAction())
                row.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus){assertTrue(it())}
                row.assertIsFocused()
                instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_DPAD_CENTER)
                compose.waitUntil(10000){graph.appearancePreferences.state.value.choice==choice&&graph.appearancePreferences.state.value.error==null}
                row.assertIsSelected().assertIsFocused()
                compose.onNodeWithContentDescription("Close Appearance").assertIsDisplayed()
                assertEquals(node,light.fetchSemanticsNode().id)
                if(choice!=Appearance.System)assertMountedSheetPaint(choice==Appearance.Dark)
                val rebuilt=AppearancePreferences(graph.directory.resolve("appearance.v1.json"));rebuilt.load()
                assertEquals(choice,rebuilt.state.value.choice)
                compose.runOnIdle {
                    assertSame(activity,compose.activity);assertSame(controller,model.controller)
                    assertActualPausedUnchanged(paused)
                    assertEquals(paused.projection.queue,model.playback.value.queue)
                    assertEquals(paused.projection.selectedOccurrence,model.playback.value.selectedOccurrence)
                    assertFalse(model.playback.value.isPlaying)
                }
            }
            // Real Android application uiMode delivery, not Activity recreation or a palette test hook.
            if(android.os.Build.VERSION.SDK_INT>=31) {
                val manager=activity.getSystemService(UiModeManager::class.java)
                for(mode in listOf(UiModeManager.MODE_NIGHT_YES,UiModeManager.MODE_NIGHT_NO)) {
                    compose.runOnIdle {manager.setApplicationNightMode(mode)}
                    val expected=if(mode==UiModeManager.MODE_NIGHT_YES)Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                    compose.waitUntil(10000){(activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK)==expected}
                    compose.onNode(hasText("System") and hasClickAction()).assertIsSelected()
                    assertMountedSheetPaint(mode==UiModeManager.MODE_NIGHT_YES)
                    assertEquals(node,light.fetchSemanticsNode().id)
                    compose.runOnIdle {assertSame(activity,compose.activity);assertActualPausedUnchanged(paused)}
                }
                compose.runOnIdle {manager.setApplicationNightMode(UiModeManager.MODE_NIGHT_AUTO)}
            }
            compose.onNodeWithContentDescription("Close Appearance").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus){assertTrue(it())}
            instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_DPAD_CENTER)
            assertSettingsReturn("after-close")
            instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_DPAD_CENTER)
            compose.onNode(hasText("System") and hasClickAction()).assertIsSelected()
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            assertSettingsReturn("after-back")
            compose.runOnIdle {assertActualPausedUnchanged(paused);assertSame(activity,compose.activity);assertSame(controller,model.controller)}
            // Revealing the offscreen heading is a separate viewport action, after return proof.
            compose.onNode(hasText("Settings") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading)).performScrollTo().assertIsDisplayed()
        } finally {compose.runOnIdle {model.controller.pause();graph.session.retire()}}
    }
}
