package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

/** Compiled native import journey. Uses the existing runner; no deployed source/account. */
class ImportJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun heldImportAckStatusRecentAndOpenLibraryPreserveListeningQueue() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server
        val original=server.dispatcher
        val fixture=ImportJourneyDispatcher(original)
        server.dispatcher=fixture
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("import-fixture@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val row=hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))
            compose.onNode(row).performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            val queueBefore=model.playback.value.queue
            assertTrue(queueBefore.isNotEmpty())
            val selectedBefore=model.playback.value.selectedOccurrence
            compose.onNodeWithContentDescription("Account and settings").performClick()
            compose.onNodeWithText("Imports").performClick()
            compose.onNodeWithContentDescription("Source URL").performTextInput("https://youtu.be/import-fixture")
            val beforeTap=compose.onNodeWithText("Import").fetchSemanticsNode().config[com.soundq.android.product.imports.ImportSubmitBindingKey]
            println("IMPORT_DIAG before text=${beforeTap.editor.text} composition=${beforeTap.editor.composition} sameDraft=${beforeTap.draft===app.graph.imports.state.value.draft} draft=${app.graph.imports.state.value.draft.text}")
            compose.onNodeWithText("Import",useUnmergedTree=true).performScrollTo().performClick()
            assertTrue("Import dispatch missing: composition=${beforeTap.editor.composition} sameDraft=${beforeTap.draft===app.graph.imports.state.value.draft} state=${app.graph.imports.state.value}",fixture.entered.await(3,TimeUnit.SECONDS))
            compose.onNodeWithText("Submitting import").assertExists()
            assertNull(app.graph.imports.state.value.acknowledgement)
            assertEquals(1,fixture.posts.get())
            fixture.release.countDown()
            compose.waitUntil(10000){app.graph.imports.state.value.acknowledgement!=null}
            compose.onNodeWithText("Check import").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.selected?.track?.value==71L}
            assertEquals(queueBefore,model.playback.value.queue)
            assertEquals(selectedBefore,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            compose.onNodeWithText("Open in Library").performScrollTo().performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Imported fixture row").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Imported fixture row").assertIsDisplayed()
            assertEquals(queueBefore,model.playback.value.queue)
            assertEquals(selectedBefore,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            // Imported-row reveal scrolls the lazy Library to its row; enlarged text retires header0.
            compose.onNode(hasScrollToIndexAction()).performScrollToIndex(0)
            // Account is in the fixed Library header, outside the scrollable tracks.
            compose.onNodeWithContentDescription("Account and settings").assertIsDisplayed().performClick()
            compose.onNodeWithText("Imports").performClick()
            compose.onNodeWithContentDescription("Refresh recent imports").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.recent.size==1}
            assertEquals(1,fixture.posts.get())
        } finally {fixture.release.countDown();server.dispatcher=original;app.graph.session.retire()}
    }
}
private class ImportJourneyDispatcher(private val fallback:Dispatcher):Dispatcher() {
    val entered=CountDownLatch(1);val release=CountDownLatch(1);val posts=AtomicInteger()
    private val id="123e4567-e89b-12d3-a456-426614174071"
    private val job="""{"job_id":"$id","status":"complete","progress":100,"track_id":71,"source_type":"youtube","url":"https://youtu.be/import-fixture","created_at":"2026-10-28T00:00:00Z"}"""
    override fun dispatch(request:RecordedRequest):MockResponse {
        val path=request.url.encodedPath
        if(path.startsWith("/api/v1/downloads")) {
            if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return reply("{}",401)
            if(request.method=="POST") {posts.incrementAndGet();entered.countDown();check(release.await(10,TimeUnit.SECONDS));return reply("""{"job_id":"$id","status":"queued"}""",201)}
            return reply(if(path=="/api/v1/downloads")"""{"jobs":[$job]}""" else job)
        }
        if(path=="/api/v1/library" && posts.get()>0)return reply("""{"tracks":[{"id":71,"title":"Imported fixture row","artist":"Synthetic ensemble","is_liked":false}],"total":1,"limit":20,"offset":0}""")
        return fallback.dispatch(request)
    }
    private fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
}
