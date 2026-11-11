package com.soundq.android

import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.imports.ImportSubmitBindingKey
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

class NativeJourneySeamTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun ordinaryStartupHasRetiredBootstrap() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        assertTrue(app.graphCreatedOnMain)
        assertTrue(ProductTransportFixture.networkingStayedOffMain)
        assertFalse(app.bootstrapThread.isAlive)
        compose.onNodeWithContentDescription("Email").assertExists()
    }
    @Test fun explicitImportCommitsComposingEditorAndRetiresOldCapture() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val fallback=ProductTransportFixture.server.dispatcher
        val posts=CopyOnWriteArrayList<String>()
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath!="/api/v1/downloads" || request.method!="POST")return fallback.dispatch(request)
                posts.add(request.body!!.utf8())
                return MockResponse.Builder().code(201).body("""{"job_id":"123e4567-e89b-12d3-a456-426614174071","status":"queued"}""").build()
            }
        }
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("seam@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            compose.onNodeWithContentDescription("Account and preview information").performClick()
            compose.onNodeWithText("Imports").performClick()
            compose.onNodeWithContentDescription("Source URL").performClick()
            compose.runOnIdle {
                fun find(view:View):View? {
                    if(view.javaClass.name=="androidx.compose.ui.platform.AndroidComposeView")return view
                    if(view is ViewGroup)for(i in 0 until view.childCount)find(view.getChildAt(i))?.let {return it}
                    return null
                }
                val view=checkNotNull(find(compose.activity.window.decorView))
                val connection=checkNotNull(view.onCreateInputConnection(EditorInfo()))
                assertTrue(connection.setComposingText("https://youtu.be/import-fixture",1))
            }
            compose.waitForIdle()
            val binding=compose.onNodeWithText("Import").fetchSemanticsNode().config[ImportSubmitBindingKey]
            assertNotNull("positive native composing editor control",binding.editor.composition)
            assertEquals("https://youtu.be/import-fixture",binding.editor.text)
            assertSame(app.graph.imports.state.value.draft,binding.draft)
            compose.onNodeWithText("Import").performScrollTo().assertIsEnabled().performClick()
            compose.waitUntil(3000){app.graph.imports.state.value.acknowledgement!=null}
            assertEquals(1,posts.size)
            compose.runOnIdle {binding.submit()}
            compose.waitForIdle()
            assertEquals(1,posts.size)
            compose.onNodeWithText("Another link").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Source URL").performTextInput("https://youtu.be/deliberate-next")
            compose.runOnIdle {binding.submit()}
            assertFalse(app.graph.imports.state.value.consumed)
            assertEquals(1,posts.size)
            compose.onNodeWithText("Import").performScrollTo().performClick()
            compose.waitUntil(3000){app.graph.imports.state.value.acknowledgement!=null}
            assertEquals(2,posts.size)
            assertTrue(posts[1].contains("https://youtu.be/deliberate-next"))
            val next=compose.onNodeWithText("Import").fetchSemanticsNode().config[ImportSubmitBindingKey]
            compose.onNodeWithContentDescription("Close Imports").performScrollTo().performClick()
            compose.runOnIdle {next.submit();binding.submit()}
            assertEquals(2,posts.size)
        } finally {ProductTransportFixture.server.dispatcher=fallback;app.graph.session.retire()}
    }
}
