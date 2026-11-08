package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.data.offline.DownloadStatus
import com.soundq.android.playback.*
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.KeyGenerator

/** Mounted production startup + Media3 consumer. Compilation is not runtime acceptance. */
class DeviceOnlyStartupJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun click(label:String){compose.onAllNodesWithText(label).filterToOne(hasClickAction()).performScrollTo().performClick()}
    @Test fun encryptedReconstructedGraphEntersDownloadsAndMedia3PlaysWithoutRemoteDispatch() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val old=app.graph
        compose.waitUntil(10000){old.session.state.value is AuthState.SignedOut}
        val pool=Executors.newSingleThreadExecutor();var graph:AppGraph?=null
        val original=ProductTransportFixture.server.dispatcher
        try {
            // All network/URL/store work stays off the native main looper.
            val prepared=pool.submit<AppGraph>{
                val key=KeyGenerator.getInstance("AES").apply {init(256)}.generateKey()
                val file=File(old.directory,"device-startup-fixture.session")
                val encrypted=EncryptedSessionStore(file){key}
                val online=AppGraph(app,old.endpoint,app.fixtureClient,encrypted,app.fixtureClient)
                check(online.session.accept(online.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh","fixture-account")))
                val scope=online.session.capture()!!
                online.downloads.load(scope)
                val track=Track(TrackId(1),"Fixture 1","Synthetic ensemble",durationMs=12000,artwork=ProductTransportFixture.origin.resolve("/media/cover.png").toString())
                online.downloads.transfer(checkNotNull(online.downloads.claim(scope,track){true}))
                check(online.downloads.state.value.rows.single().status==DownloadStatus.Complete)
                online.close()
                AppGraph(app,old.endpoint,app.fixtureClient,EncryptedSessionStore(file){key},app.fixtureClient)
            }.get(15,TimeUnit.SECONDS)
            graph=prepared
            val before=ProductTransportFixture.requests.size
            ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                ProductTransportFixture.requests.add("FORBIDDEN "+request.method+" "+request.url.encodedPath)
                return MockResponse.Builder().code(503).body("{}").build()
            }}
            compose.runOnIdle {
                compose.activity.stopService(android.content.Intent(app,SoundQLibraryService::class.java))
                // Activity recreation intentionally retains ViewModels. This graph-reconstruction
                // witness needs a fresh model, not the old model bound to the retired graph.
                compose.activity.viewModelStore.clear()
                old.close();app.graph=prepared
            }
            compose.activityRule.scenario.recreate()
            compose.waitUntil(10000){compose.onAllNodesWithText("More options").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("More options").assertIsEnabled()
            click("More options");click("Listen offline")
            compose.waitUntil(10000){prepared.session.state.value is AuthState.DeviceOnly&&prepared.downloads.state.value.rows.singleOrNull()?.status==DownloadStatus.Complete&&compose.onAllNodesWithContentDescription("More for Fixture 1").fetchSemanticsNodes().isNotEmpty()}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(10000){model.playback.value.connection==PlaybackProjection.Connection.Connected}
            assertFalse(model.playback.value.isPlaying)
            compose.onNodeWithText("Go online").assertIsDisplayed()
            compose.onAllNodesWithText("Discover").assertCountEquals(0)
            compose.onAllNodesWithText("Playlists").assertCountEquals(0)
            val scope=prepared.session.capture()!!
            pool.submit {
                val uri=android.net.Uri.parse("soundq://track/1/device-startup-range")
                val grants=ConcurrentHashMap<String,MediaGrant>();grants[uri.toString()]=MediaGrant(scope,TrackId(1))
                val expected=ByteArray(23);prepared.downloads.acquire(scope,TrackId(1))!!.use {it.seek(17);assertEquals(23,it.read(expected,0,23))}
                val source=SignedAudioDataSource(prepared,grants)
                try {
                    assertEquals(23L,source.open(androidx.media3.datasource.DataSpec.Builder().setUri(uri).setPosition(17).setLength(23).build()))
                    val actual=ByteArray(23);assertEquals(23,source.read(actual,0,23));assertArrayEquals(expected,actual)
                    assertEquals(androidx.media3.common.C.RESULT_END_OF_INPUT,source.read(actual,0,23))
                } finally {source.close()}
                val missing=android.net.Uri.parse("soundq://track/999/missing")
                grants[missing.toString()]=MediaGrant(scope,TrackId(999))
                assertEquals(SafeFailure.Reason.AudioUnavailable,(runCatching {source.open(androidx.media3.datasource.DataSpec(missing))}.exceptionOrNull() as SafeFailure).reason)
                source.close()
                ScopedArtworkLoader(prepared).use {loader ->assertTrue(runCatching {loader.loadBitmap(android.net.Uri.parse("https://localhost/cover")).get(2,TimeUnit.SECONDS)}.isFailure)}
            }.get(10,TimeUnit.SECONDS)
            compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
            click("Play device copy")
            try {compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0&&model.playback.value.queue.map {it.trackId}==listOf(1L)}}catch(failure:Throwable) {
                runCatching {compose.runOnIdle {
                    val sessions=androidx.media3.session.MediaSession::class.java.getDeclaredField("SESSION_ID_TO_SESSION_MAP").apply {isAccessible=true}.get(null) as Map<*,*>
                    val player=(sessions.values.single() as androidx.media3.session.MediaSession).player
                    var output=player
                    while(output is androidx.media3.common.ForwardingPlayer)output=output.wrappedPlayer
                    val native=output as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer
                    org.json.JSONObject().put("projection",model.playback.value.toString()).put("servicePlaying",player.isPlaying)
                        .put("servicePlayWhenReady",player.playWhenReady).put("serviceState",player.playbackState).put("serviceItems",player.mediaItemCount)
                        .put("playerError",player.playerError?.errorCode).put("native",native?.nativeDiagnostics())
                        .put("localRows",prepared.downloads.state.value.rows.size).put("sessionCurrent",prepared.session.current(scope))
                }}.onSuccess {observation->
                    failure.addSuppressed(AssertionError(observation.toString()))
                    runCatching {java.io.File(app.filesDir,"device-startup-diagnostic.json").writeText(observation.toString())}.onFailure(failure::addSuppressed)
                }.onFailure(failure::addSuppressed)
                throw failure
            }
            assertTrue(ProductTransportFixture.requests.drop(before).isEmpty())
            compose.onNodeWithContentDescription("Pause").performClick()
            click("More options")
            compose.onNode(hasText("Sign out") and hasClickAction()).performClick()
            compose.waitUntil(10000){prepared.session.state.value is AuthState.SignedOut&&model.playback.value.queue.isEmpty()}
            assertFalse(prepared.session.current(scope));assertTrue(ProductTransportFixture.requests.drop(before).isEmpty())
        } finally {
            ProductTransportFixture.server.dispatcher=original
            compose.runOnIdle {compose.activity.stopService(android.content.Intent(app,SoundQLibraryService::class.java));graph?.close()}
            pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))
        }
    }
}
