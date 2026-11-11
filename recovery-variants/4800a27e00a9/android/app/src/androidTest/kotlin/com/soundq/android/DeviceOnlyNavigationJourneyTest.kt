package com.soundq.android

import android.view.KeyEvent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.soundq.android.data.*
import com.soundq.android.data.offline.DownloadStatus
import com.soundq.android.playback.SoundQLibraryService
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.KeyGenerator
import androidx.test.platform.app.InstrumentationRegistry

/** Ordinary MainActivity/ProductApp, reconstructed encrypted session, real loopback TLS; no real credentials. */
class DeviceOnlyNavigationJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun click(label:String)=compose.onAllNodesWithText(label).filterToOne(hasClickAction()).performScrollTo().performClick()
    private fun back()=InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
    // Selector-only predecessor compatibility: preserve the actual native Back regression body on both snapshots.
    private fun listenOffline() {
        if(compose.onAllNodesWithText("Use device downloads").fetchSemanticsNodes().isNotEmpty())click("Use device downloads")
        else {click("More options");click("Listen offline")}
    }
    private fun files(root:File):Map<String,List<Byte>> = root.walkTopDown().filter {it.isFile}.associate {it.relativeTo(root).path to it.readBytes().toList()}
    private fun withDeviceOnly(body:(AppGraph,AtomicInteger,File,ExecutorService)->Unit) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val old=app.graph;val pool=Executors.newSingleThreadExecutor();val clears=AtomicInteger()
        val original=ProductTransportFixture.server.dispatcher
        var replacement:AppGraph?=null
        var primary:Throwable?=null
        try {
            val prepared=pool.submit<AppGraph> {
                val key=KeyGenerator.getInstance("AES").apply {init(256)}.generateKey()
                val file=File(old.directory,"device-navigation-fixture.session")
                val encrypted=EncryptedSessionStore(file){key}
                val seed=AppGraph(app,old.endpoint,app.fixtureClient,encrypted,app.fixtureClient)
                try {
                    check(seed.session.accept(seed.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh","fixture-account")))
                    val scope=seed.session.capture()!!;seed.downloads.load(scope)
                    if(seed.downloads.state.value.rows.none {it.track.id==TrackId(1)&&it.status==DownloadStatus.Complete}) {
                        seed.downloads.transfer(checkNotNull(seed.downloads.claim(scope,Track(TrackId(1),"Fixture 1","Synthetic ensemble",durationMs=12000)){true}))
                    }
                } finally {seed.close()}
                AppGraph(app,old.endpoint,app.fixtureClient,object:SessionStore {
                    override fun load(endpoint:ApiEndpoint)=encrypted.load(endpoint)
                    override fun save(endpoint:ApiEndpoint,tokens:SecretTokens)=encrypted.save(endpoint,tokens)
                    override fun clear(){clears.incrementAndGet();encrypted.clear()}
                },app.fixtureClient)
            }.get(15,TimeUnit.SECONDS)
            replacement=prepared
            compose.runOnIdle {
                compose.activity.stopService(android.content.Intent(app,SoundQLibraryService::class.java))
                compose.activity.viewModelStore.clear();old.close();app.graph=prepared
            }
            compose.activityRule.scenario.recreate()
            compose.waitUntil(10000){compose.onAllNodesWithText("More options").fetchSemanticsNodes().isNotEmpty()||compose.onAllNodesWithText("Use device downloads").fetchSemanticsNodes().isNotEmpty()}
            val before=ProductTransportFixture.requests.size
            listenOffline()
            compose.waitUntil(10000){prepared.session.state.value is AuthState.DeviceOnly&&prepared.downloads.state.value.ready&&prepared.downloads.state.value.rows.any {it.status==DownloadStatus.Complete}}
            compose.onNodeWithText("Downloads").assertIsDisplayed()
            compose.waitForIdle();captureOfflineAuthStage("offline-downloads")
            assertEquals(before,ProductTransportFixture.requests.size)
            body(prepared,clears,File(prepared.directory,"device-navigation-fixture.session"),pool)
        } catch(error:Throwable) {
            primary=error
            val refreshes=ProductTransportFixture.requests.count {it=="POST /api/v1/auth/refresh"}
            println("DEVICE_ONLY_FAILURE auth=${replacement?.session?.state?.value} loading=${replacement?.library?.state?.value?.loading} libraryError=${replacement?.library?.state?.value?.error} rows=${replacement?.library?.state?.value?.rows?.size} refreshRequests=$refreshes finishing=${compose.activity.isFinishing}")
            try {captureOfflineAuthStage("device-navigation-failure")}catch(capture:Throwable){error.addSuppressed(capture)}
            throw error
        }
        finally {
            val cleanup=runCatching {
                try {
                    ProductTransportFixture.server.dispatcher=original
                    compose.runOnIdle {compose.activity.stopService(android.content.Intent(app,SoundQLibraryService::class.java));replacement?.close()}
                    // Leave a fresh signed-out in-memory fixture graph for the next class, without clearing any saved bytes.
                    val reset=pool.submit<AppGraph> {
                        AppGraph(app,old.endpoint,app.fixtureClient,object:SessionStore {
                            private var saved:SecretTokens?=null
                            override fun load(endpoint:ApiEndpoint)=saved
                            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){saved=tokens}
                            override fun clear(){saved=null}
                        },app.fixtureClient).also {it.api.restore()}
                    }.get(10,TimeUnit.SECONDS)
                    compose.runOnIdle {app.graph=reset}
                } finally {pool.shutdownNow();check(pool.awaitTermination(5,TimeUnit.SECONDS))}
            }.exceptionOrNull()
            if(cleanup!=null) {if(primary!=null)primary.addSuppressed(cleanup) else throw cleanup}
        }
    }
    @Test fun explicitGoOnlineReturnsToLibraryAndHeldRepeatedBackDoesNotReplay() = withDeviceOnly {graph,clears,_,pool ->
        val downloads=pool.submit<Map<String,List<Byte>>>{files(File(graph.directory,"device-downloads"))}.get(5,TimeUnit.SECONDS)
        val delegate=ProductTransportFixture.server.dispatcher;val refreshes=AtomicInteger();val entered=CountDownLatch(1);val release=CountDownLatch(1)
        ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            if(request.url.encodedPath=="/api/v1/auth/refresh") {refreshes.incrementAndGet();entered.countDown();check(release.await(10,TimeUnit.SECONDS))}
            return delegate.dispatch(request)
        }}
        val before=ProductTransportFixture.requests.size
        try {
            click("Go online");assertTrue(entered.await(5,TimeUnit.SECONDS))
            compose.onNodeWithText("Going online").assertIsDisplayed()
            compose.waitForIdle();captureOfflineAuthStage("going-online")
            back();back();compose.waitForIdle()
            assertFalse(compose.activity.isFinishing);assertEquals(1,refreshes.get())
            release.countDown()
            compose.waitUntil(10000){graph.session.state.value is AuthState.SignedIn&&compose.onAllNodesWithContentDescription("More for Fixture 1").fetchSemanticsNodes().isNotEmpty()}
            assertEquals(AuthState.SignedIn("fixture-account"),graph.session.state.value)
            compose.onAllNodesWithText("Go online").assertCountEquals(0)
            assertEquals(0,clears.get());assertEquals(1,refreshes.get())
            assertFalse(ProductTransportFixture.requests.drop(before).any {it.contains("/auth/logout")})
            assertEquals(downloads,pool.submit<Map<String,List<Byte>>>{files(File(graph.directory,"device-downloads"))}.get(5,TimeUnit.SECONDS))
            val online=graph.session.capture()!!
            for(nativeBack in listOf(false,true)) {
                compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().performClick();click("Open Downloads")
                compose.onNodeWithText("Back to Library").assertIsDisplayed()
                if(nativeBack)back() else click("Back to Library")
                compose.waitUntil(10000){compose.onAllNodesWithText("Back to Library").fetchSemanticsNodes().isEmpty()&&compose.onAllNodesWithContentDescription("More for Fixture 1").fetchSemanticsNodes().isNotEmpty()}
                assertTrue(graph.session.current(online));assertEquals(0,clears.get());assertEquals(1,refreshes.get())
            }
        } finally {release.countDown()}
    }
    /** This test contains no new production symbol: replay these identical bytes against preserved predecessor. */
    @Test fun nativeBackFromDeviceOnlyRestoresSavedSessionAndReturnsToLibrary() = withDeviceOnly {graph,clears,_,pool ->
        val downloads=pool.submit<Map<String,List<Byte>>>{files(File(graph.directory,"device-downloads"))}.get(5,TimeUnit.SECONDS)
        val before=ProductTransportFixture.requests.size
        back()
        compose.waitUntil(10000){graph.session.state.value is AuthState.SignedIn&&compose.onAllNodesWithContentDescription("More for Fixture 1").fetchSemanticsNodes().isNotEmpty()}
        assertFalse(compose.activity.isFinishing);assertEquals(AuthState.SignedIn("fixture-account"),graph.session.state.value)
        assertEquals(1,ProductTransportFixture.requests.drop(before).count {it=="POST /api/v1/auth/refresh"})
        assertFalse(ProductTransportFixture.requests.drop(before).any {it.contains("/auth/logout")});assertEquals(0,clears.get())
        assertEquals(downloads,pool.submit<Map<String,List<Byte>>>{files(File(graph.directory,"device-downloads"))}.get(5,TimeUnit.SECONDS))
    }
    @Test fun failedGoOnlineKeepsExplicitSavedSessionAndDeviceDownloadsRecoveryReachable() = withDeviceOnly {graph,clears,file,pool ->
        val bytes=pool.submit<ByteArray>{file.readBytes()}.get(5,TimeUnit.SECONDS)
        val downloads=pool.submit<Map<String,List<Byte>>>{files(File(graph.directory,"device-downloads"))}.get(5,TimeUnit.SECONDS)
        val delegate=ProductTransportFixture.server.dispatcher;val refreshes=AtomicInteger()
        ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            if(request.url.encodedPath=="/api/v1/auth/refresh") {refreshes.incrementAndGet();return MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()}
            return delegate.dispatch(request)
        }}
        click("Go online")
        compose.waitUntil(10000){graph.session.state.value is AuthState.SignedOut&&compose.onAllNodesWithText("Connection interrupted").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("Reconnect").assertIsDisplayed().assertIsEnabled()
        compose.onNodeWithText("More options").assertIsDisplayed().assertIsEnabled()
        compose.waitForIdle();captureOfflineAuthStage("interrupted-connection")
        assertArrayEquals(bytes,pool.submit<ByteArray>{file.readBytes()}.get(5,TimeUnit.SECONDS));assertEquals(0,clears.get());assertEquals(1,refreshes.get())
        click("Reconnect")
        compose.waitUntil(10000){graph.session.state.value is AuthState.SignedOut&&compose.onAllNodesWithText("Connection interrupted").fetchSemanticsNodes().isNotEmpty()&&refreshes.get()==2}
        assertArrayEquals(bytes,pool.submit<ByteArray>{file.readBytes()}.get(5,TimeUnit.SECONDS));assertEquals(0,clears.get())
        listenOffline()
        compose.waitUntil(10000){graph.session.state.value is AuthState.DeviceOnly}
        compose.onNodeWithText("Go online").assertIsDisplayed().assertIsEnabled();assertEquals(2,refreshes.get())
        assertEquals(downloads,pool.submit<Map<String,List<Byte>>>{files(File(graph.directory,"device-downloads"))}.get(5,TimeUnit.SECONDS))
        ProductTransportFixture.server.dispatcher=delegate
        click("Go online")
        compose.waitUntil(10000){graph.session.state.value is AuthState.SignedIn}
        assertEquals(AuthState.SignedIn("fixture-account"),graph.session.state.value);assertEquals(0,clears.get())
    }
}
