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
import java.util.concurrent.atomic.AtomicBoolean

/** OFF-2/OFF-3 ordinary signed-in Downloads action, not an auth-state-only witness. */
class DeviceCopyIntentJourneyTest {
    private val compose=createAndroidComposeRule<MainActivity>()
    private val blocked=AtomicBoolean(false)
    private var original:Dispatcher?=null
    private val transport=object:ExternalResource(){
        override fun before() {
            val delegate=ProductTransportFixture.server.dispatcher;original=delegate
            ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(blocked.get()) {
                    ProductTransportFixture.requests.add("FORBIDDEN "+request.method+" "+request.url.encodedPath)
                    return MockResponse.Builder().code(503).body("{}").build()
                }
                if(request.url.encodedPath=="/api/v1/library") {
                    ProductTransportFixture.requests.add(request.method+" "+request.url.encodedPath)
                    val art=ProductTransportFixture.origin.resolve("/media/remote-cover.png")
                    return MockResponse.Builder().body("""{"tracks":[{"id":1,"title":"Fixture 1","artist":"Synthetic ensemble","duration_ms":12000,"artwork_url":"$art"},{"id":2,"title":"Fixture 2","artist":"Synthetic ensemble","duration_ms":12000}],"total":2,"limit":20,"offset":0}""").build()
                }
                return delegate.dispatch(request)
            }}
        }
        override fun after(){blocked.set(false);original?.let {ProductTransportFixture.server.dispatcher=it}}
    }
    @get:Rule val rules:RuleChain=RuleChain.outerRule(transport).around(compose)
    private fun click(label:String){compose.onAllNodesWithText(label).filterToOne(hasClickAction()).performScrollTo().performClick()}
    @Test fun signedInDeviceActionSuppressesArtworkAndCustodyLossFallbackWhileGenericLibraryStreams() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("synthetic-device-intent@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        click("Sign in")
        compose.waitUntil(10000){graph.library.state.value.rows.size==2}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(10000){model.playback.value.connection==PlaybackProjection.Connection.Connected}
        compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().performClick()
        click("Download to device");click("Open Downloads")
        compose.waitUntil(15000){graph.downloads.state.value.rows.singleOrNull()?.status==DownloadStatus.Complete}
        compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
        compose.onNodeWithText("Play device copy").assertIsDisplayed()
        assertNotNull(graph.downloads.state.value.rows.single().track.artwork)
        kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO){graph.presence.disconnect()}
        val before=ProductTransportFixture.requests.size
        blocked.set(true)
        click("Play device copy")
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
        assertTrue("valid explicit copy sends no artwork/descriptor/media request",ProductTransportFixture.requests.drop(before).isEmpty())
        compose.onNodeWithContentDescription("Pause").performClick()
        // Positive Complete presentation precedes storage invalidation. No load/refresh of Downloads here.
        compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
        compose.onNodeWithText("Play device copy").assertIsDisplayed()
        val row=graph.downloads.state.value.rows.single()
        // Prior fixture endpoints retain their own device copies. Corrupt only this accepted owner.
        val copyDirectory=com.soundq.android.data.offline.DeviceDownloads::class.java.getDeclaredField("directory").apply {isAccessible=true}.get(graph.downloads) as java.io.File
        val artifact=copyDirectory.listFiles()!!.single {it.extension=="audio"}
        artifact.writeBytes(ByteArray(artifact.length().toInt()){42})
        assertSame(row,graph.downloads.state.value.rows.single())
        click("Play device copy")
        compose.waitUntil(15000){model.playback.value.error!=null&&!model.playback.value.preparing}
        compose.onNodeWithText("Audio could not be played. Retry playback.").performScrollTo().assertIsDisplayed()
        assertTrue("lost local custody sends no refresh/descriptor/media/artwork request: ${ProductTransportFixture.requests.drop(before)}; localOnly=${model.playback.value.localOnly}",ProductTransportFixture.requests.drop(before).isEmpty())
        // Ordinary Library listening retains remote fallback. No global offline toggle.
        blocked.set(false)
        click("Back to Library")
        val streamingBefore=ProductTransportFixture.requests.size
        compose.onAllNodesWithText("Fixture 2").filterToOne(hasClickAction()).performScrollTo().performClick()
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.getOrNull(1)?.trackId==2L}
        val streaming=ProductTransportFixture.requests.drop(streamingBefore)
        val extension=if(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext is CallbackFrontendFixtureApplication)"mp3" else "wav"
        assertTrue(streaming.any {it=="POST /api/v1/playback/urls"});assertTrue(streaming.any {it=="GET /media/2.$extension"})
        compose.onNodeWithContentDescription("Pause").performClick()
    }
}
