package com.soundq.android

import android.graphics.Bitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/** Ordinary synthetic-account navigation. No provider, original file or Play command. */
class HomeCollectionJourneyTest {
    private val compose=createAndroidComposeRule<MainActivity>()
    private var original:Dispatcher?=null
    private val offsets=CopyOnWriteArrayList<Int>()
    private val failAppend=AtomicBoolean(true)
    private val transport=object:ExternalResource() {
        override fun before() {
            val fallback=ProductTransportFixture.server.dispatcher;original=fallback
            ProductTransportFixture.server.dispatcher=object:Dispatcher() {
                override fun dispatch(request:RecordedRequest):MockResponse {
                    val path=request.url.encodedPath
                    if(path=="/api/v1/me/plays/top") {
                        assertEquals("25",request.url.queryParameter("limit"))
                        assertEquals("true",request.url.queryParameter("owned"))
                        val rows=(1..25).joinToString(",") {"""{"id":$it,"title":"Top $it","artist":"Synthetic artist","inLibrary":true}"""}
                        return MockResponse.Builder().body("""{"tracks":[$rows],"days":30,"limit":25,"ownedOnly":true}""").build()
                    }
                    if(path!="/api/v1/me/plays/recent")return fallback.dispatch(request)
                    val offset=request.url.queryParameter("offset")!!.toInt();offsets+=offset
                    if(offset>0&&failAppend.compareAndSet(true,false))return MockResponse.Builder().code(503).body("{}").build()
                    val rows=(offset+1..minOf(offset+20,23)).joinToString(",") {"""{"id":$it,"title":"Recent $it","artist":"Synthetic artist","inLibrary":true}"""}
                    return MockResponse.Builder().body(recentFixtureBody("""{"tracks":[$rows]}""",offset,offset+20<23)).build()
                }
            }
        }
        override fun after(){original?.let {ProductTransportFixture.server.dispatcher=it}}
    }
    @get:Rule val rules:RuleChain=RuleChain.outerRule(transport).around(compose)

    private fun capture(name:String) {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val root=java.io.File(instrumentation.targetContext.getExternalFilesDir(null),"discovery-collections").apply {mkdirs()}
        val bitmap=requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {java.io.File(root,"$name.png").outputStream().use {check(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}}
        finally {bitmap.recycle()}
    }

    private fun collectionScrollOffset():Float {
        compose.waitForIdle()
        return compose.onNode(hasScrollAction()).fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()
    }

    @Test fun previewsOpenCompleteCollectionsAndBackPreservesPlayback() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        compose.signInThroughSettings("collections@example.test","test-only-password"){app.graph.session.capture()!=null}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.onAllNodesWithText("Home").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){model.home.recent.value.rows.size==20&&model.home.top.value.rows.size==25&&!model.home.top.value.loading}
        val before=model.playback.value
        compose.onNodeWithText("Recent 6").assertDoesNotExist()
        capture("home-preview")
        compose.onNodeWithContentDescription("View all Recently played").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Back to Home").assertIsDisplayed()
        compose.onNodeWithText("Recent 20").performScrollTo().assertIsDisplayed()
        assertEquals(listOf(0),offsets.toList())
        compose.onNodeWithContentDescription("Load more").performScrollTo().performClick()
        compose.waitUntil(10000){model.home.recent.value.error!=null}
        compose.onNodeWithText("Retry Recently played").performScrollTo().performClick()
        compose.waitUntil(10000){model.home.recent.value.rows.size==23&&!model.home.recent.value.loading}
        compose.onNodeWithText("Recent 23").performScrollTo().assertIsDisplayed()
        val recentOffset=collectionScrollOffset()
        assertTrue("Recent must actually have scrolled",recentOffset>0f)
        assertEquals(listOf(0,20,20),offsets.toList())
        compose.onNodeWithContentDescription("Back to Home").performClick()
        compose.onNodeWithText("Recent 6").assertDoesNotExist()
        compose.onNodeWithContentDescription("View all Your top tracks").performScrollTo().performClick()
        assertEquals("Top must not inherit Recent's scroll position",0f,collectionScrollOffset(),0f)
        compose.onNodeWithText("Top 25").performScrollTo().assertIsDisplayed()
        capture("top-collection")
        compose.onNodeWithContentDescription("Back to Home").performClick()
        compose.onNodeWithText("Top 6").assertDoesNotExist()
        compose.onNodeWithContentDescription("View all Recently played").performScrollTo().performClick()
        assertEquals("Recent must restore its own position",recentOffset,collectionScrollOffset(),0f)
        compose.onNodeWithContentDescription("Back to Home").performClick()
        val after=model.playback.value
        assertEquals(before.queue,after.queue)
        assertEquals(before.selectedOccurrence,after.selectedOccurrence)
        assertEquals(before.isPlaying,after.isPlaying)
    }
}
