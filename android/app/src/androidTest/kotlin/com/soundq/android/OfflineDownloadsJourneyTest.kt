package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.offline.DownloadStatus
import com.soundq.android.playback.PlaybackProjection
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Compiled ordinary-launch journey. Parent runtime owner executes with ProductFixtureRunner. */
class OfflineDownloadsJourneyTest {
    private val compose=createAndroidComposeRule<MainActivity>()
    private var original:Dispatcher?=null
    private val blockNetwork=AtomicBoolean(false)
    private val descriptorHeld=CountDownLatch(1)
    private val releaseDescriptor=CountDownLatch(1)
    private val firstDescriptor=AtomicBoolean(true)
    private val transport=object:ExternalResource(){
        override fun before() {
            val delegate=ProductTransportFixture.server.dispatcher;original=delegate
            ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(blockNetwork.get()){
                    ProductTransportFixture.requests.add("BLOCKED "+request.method+" "+request.url.encodedPath)
                    return MockResponse.Builder().code(503).body("{}").build()
                }
                if(request.url.encodedPath=="/api/v1/playback/urls"&&firstDescriptor.compareAndSet(true,false)){
                    descriptorHeld.countDown();check(releaseDescriptor.await(15,TimeUnit.SECONDS))
                }
                return delegate.dispatch(request)
            }}
        }
        override fun after(){releaseDescriptor.countDown();blockNetwork.set(false);original?.let {ProductTransportFixture.server.dispatcher=it}}
    }
    @get:Rule val rules:RuleChain=RuleChain.outerRule(transport).around(compose)
    private fun click(label:String){compose.onAllNodesWithText(label).filterToOne(hasClickAction()).performScrollTo().performClick()}
    @Test fun explicitDownloadCancelRetryRecreateBrowseAndMedia3PlayWithoutAnyNetworkThenConfirmedRemove() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("synthetic-offline@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        click("Sign in")
        compose.waitUntil(10000){graph.library.state.value.rows.size==3}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(10000){model.playback.value.connection==PlaybackProjection.Connection.Connected}
        compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().performClick()
        click("Download to device")
        assertTrue(descriptorHeld.await(10,TimeUnit.SECONDS))
        click("Open Downloads")
        compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
        compose.waitUntil(10000){compose.onAllNodesWithText("Cancel download").fetchSemanticsNodes().isNotEmpty()}
        click("Cancel download")
        compose.waitUntil(10000){model.downloads.value.rows.single().status==DownloadStatus.Cancelled}
        releaseDescriptor.countDown()
        compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
        click("Retry download")
        compose.waitUntil(15000){model.downloads.value.rows.single().status==DownloadStatus.Complete&&compose.onAllNodesWithContentDescription("More for Fixture 1").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
        compose.onNodeWithText("Play device copy").assertIsDisplayed().assertIsEnabled()
        val libraryIds=graph.library.state.value.rows.map {it.id}
        // Activity recreation is deliberately not claimed as normal-process death/restart.
        compose.activityRule.scenario.recreate()
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("More for Fixture 1").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
        compose.onNodeWithText("Play device copy").assertIsDisplayed().assertIsEnabled()
        val afterRecreate=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        val before=ProductTransportFixture.requests.size
        blockNetwork.set(true)
        // Exercise the exact service source's opaque URI, bounded seek and local byte path too.
        val scope=graph.session.capture()!!
        val track=graph.downloads.state.value.rows.single().track.id
        val expected=ByteArray(23)
        graph.downloads.acquire(scope,track)!!.use {it.seek(17);assertEquals(23,it.read(expected,0,23))}
        val uri=android.net.Uri.parse("soundq://track/1/compiled-offline-range")
        val grants=java.util.concurrent.ConcurrentHashMap<String,com.soundq.android.playback.MediaGrant>()
        grants[uri.toString()]=com.soundq.android.playback.MediaGrant(scope,track)
        val source=com.soundq.android.playback.SignedAudioDataSource(graph,grants)
        try {
            assertEquals(23L,source.open(androidx.media3.datasource.DataSpec.Builder().setUri(uri).setPosition(17).setLength(23).build()))
            val actual=ByteArray(23);assertEquals(23,source.read(actual,0,23));assertArrayEquals(expected,actual)
            assertEquals(androidx.media3.common.C.RESULT_END_OF_INPUT,source.read(actual,0,23));assertEquals(uri,source.uri)
        } finally {source.close()}
        click("Play device copy")
        compose.waitUntil(15000){afterRecreate.playback.value.isPlaying&&afterRecreate.playback.value.positionMs>0&&afterRecreate.playback.value.queue.map {it.trackId}==listOf(1L)}
        assertTrue("local source makes no HTTP dispatch",ProductTransportFixture.requests.drop(before).isEmpty())
        compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
        click("Remove device copy")
        click("Keep downloads")
        assertEquals(DownloadStatus.Complete,model.downloads.value.rows.single().status)
        click("Clear device downloads")
        click("Confirm removal")
        compose.waitUntil(10000){model.downloads.value.rows.isEmpty()}
        assertEquals(libraryIds,graph.library.state.value.rows.map {it.id})
        assertTrue(ProductTransportFixture.requests.drop(before).isEmpty())
        compose.onNodeWithContentDescription("Pause").performClick()
    }
}
