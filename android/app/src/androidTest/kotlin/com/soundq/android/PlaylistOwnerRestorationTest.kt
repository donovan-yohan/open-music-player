package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.product.*
import mockwebserver3.*
import okhttp3.tls.HandshakeCertificates
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Actual ProductApp + framework SaveableStateRegistry. Parent owns compilation and execution. */
class PlaylistOwnerRestorationTest {
    @get:Rule val compose=createComposeRule()
    @Test fun anotherAccountAtEqualEpochCannotRestoreDraftOrReturnJob()=journey("B",false,false)
    @Test fun anotherEndpointAtEqualEpochCannotRestoreDraftOrReturnJob()=journey("A",true,false)
    @Test fun asynchronousOtherAccountCannotRestoreDraftOrReturnJob()=journey("B",false,true)
    @Test fun sameOwnerRestoresDraftAndExactOriginatingJob()=journey("A",false,false)
    @Test fun asynchronousSameOwnerRestoresDraftAndExactOriginatingJob()=journey("A",false,true)

    private fun journey(account:String,replaceEndpoint:Boolean,async:Boolean) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val io=Executors.newSingleThreadExecutor()
        val server=MockWebServer()
        val requests=CopyOnWriteArrayList<String>()
        val refreshEntered=CountDownLatch(1);val releaseRefresh=CountDownLatch(1)
        val stores=mutableListOf<ViewModelStore>()
        val graphs=mutableListOf<AppGraph>()
        val job="123e4567-e89b-12d3-a456-426614174092"
        val same=account=="A"&&!replaceEndpoint
        val url="https://youtube.com/playlist?list=PLowner"
        val description="Private owner A description"
        fun progress()="""{"id":"$job","playlistId":17,"status":"complete","totalItems":1,"importedItems":1,"queuedItems":0,"failedItems":0,"skippedItems":0,"items":[{"id":1,"title":"Owner entry","status":"imported","trackId":71}]}"""
        fun graph(endpoint:ApiEndpoint,owner:String?,storeTokens:SecretTokens?=null):AppGraph = io.submit<AppGraph> {
            AppGraph(app,endpoint,app.fixtureClient,object:SessionStore {
                override fun load(endpoint:ApiEndpoint)=storeTokens
                override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
                override fun clear(){}
            },app.fixtureClient).also {g->if(owner!=null)check(g.session.accept(g.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-refresh",owner)))}
        }.get(10,TimeUnit.SECONDS).also {graphs.add(it)}
        fun model(g:AppGraph):ProductViewModel=compose.runOnIdle {
            app.graph=g
            ProductViewModel(app).also {m->ViewModelStore().also {it.put("owner",m);stores.add(it)}}
        }
        fun scroll(match:SemanticsMatcher){compose.onNodeWithTag("acquisition-list").performScrollToNode(match)}
        fun fill(label:String,value:String){val m=hasText(label) and hasSetTextAction();scroll(m);compose.onNode(m).performTextReplacement(value)}
        fun fieldsRetained() {
            compose.waitUntil(10000){compose.onAllNodesWithTag("acquisition-list").fetchSemanticsNodes().size==1}
            scroll(hasText("YouTube playlist"))
            compose.onNodeWithText("YouTube playlist").assertIsSelected()
            for((label,value) in listOf("YouTube playlist URL" to url,"New playlist name (optional)" to "Private owner A name","Playlist description (optional)" to description,"Maximum items (1–1000)" to "42")) {
                val m=hasText(label) and hasSetTextAction();scroll(m);compose.onNode(m).assertTextContains(value)
            }
        }
        fun openTools() {
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Discover options").performClick()
            compose.onNodeWithText("Server tools").performClick()
        }
        val fixture=ProductTransportFixture.server
        val fallback=fixture.dispatcher
        val dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath;requests.add("${request.method} $path")
            fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
            return when {
                path.endsWith("/auth/refresh")-> {
                    refreshEntered.countDown();check(releaseRefresh.await(10,TimeUnit.SECONDS))
                    reply("""{"accessToken":"synthetic-fixture-access","refreshToken":"synthetic-new-refresh","user":{"id":"$account"}}""")
                }
                path.endsWith("/playlist-imports")&&request.method=="POST"->reply(progress(),202)
                path.endsWith("/playlist-imports/$job")->reply(progress())
                path.endsWith("/playlists/17")->reply("""{"id":17,"name":"Owner playlist","description":"","isPublic":false,"trackCount":0,"durationMs":0,"tracks":[]}""")
                path.endsWith("/queue")->reply("""{"items":[],"currentPosition":0,"updatedAt":"2026-10-29T00:00:00Z"}""")
                else->fallback.dispatch(request)
            }
        }}
        try {
            fixture.dispatcher=dispatcher
            io.submit {server.useHttps(HandshakeCertificates.Builder().heldCertificate(ProductTransportFixture.certificate).build().sslSocketFactory());server.dispatcher=dispatcher;server.start()}.get(10,TimeUnit.SECONDS)
            val first=graph(ProductTransportFixture.endpoint,"A")
            // Deliberately non-Snapshot. It changes only when restoration reruns setContent.
            compose.runOnIdle {app.graph.close()}
            var currentModel=model(first)
            val restoration=StateRestorationTester(compose)
            restoration.setContent {ProductApp(currentModel)}
            openTools()
            compose.onNodeWithText("YouTube playlist").performScrollTo().performClick()
            fill("YouTube playlist URL",url);fill("New playlist name (optional)","Private owner A name")
            fill("Playlist description (optional)",description);fill("Maximum items (1–1000)","42")
            scroll(hasText("Import playlist"));compose.onNodeWithText("Import playlist").performClick()
            compose.waitUntil(10000){first.acquisition.state.value.playlist?.id?.value==job&&!first.acquisition.state.value.busy}
            scroll(hasText("Open playlist"));compose.onNodeWithText("Open playlist").performClick()
            compose.waitUntil(10000){first.playlistDetail.state.value.detail!=null}
            compose.onNodeWithContentDescription("Back to playlists").performClick()
            compose.waitUntil(10000){!first.acquisition.state.value.busy&&first.acquisition.state.value.playlist?.id?.value==job}
            fieldsRetained() // Positive real navigation before process-state restoration.
            val endpoint=if(replaceEndpoint)io.submit<ApiEndpoint>{ApiEndpoint.parse(server.url("/api/v1").toString())}.get() else ProductTransportFixture.endpoint
            val second=graph(endpoint,if(async)null else account,if(async)SecretTokens("synthetic-fixture-access","synthetic-refresh",account)else null)
            if(!async)assertEquals(first.session.version(),second.session.version())
            val oldModel=currentModel
            val before=oldModel.playback.value
            val boundary=requests.size
            currentModel=model(second)
            restoration.emulateSavedInstanceStateRestore()
            if(async) {
                // Real saved-token refresh, held across Pending composition before authority exists.
                compose.waitForIdle()
                val restoring=io.submit<Boolean> {second.api.restore()}
                assertTrue(refreshEntered.await(10,TimeUnit.SECONDS));compose.waitForIdle()
                compose.onNodeWithText(description).assertDoesNotExist()
                assertTrue(requests.drop(boundary).none {it.contains("/playlist-imports/")})
                releaseRefresh.countDown();assertTrue(restoring.get(10,TimeUnit.SECONDS))
                compose.waitForIdle()
                assertEquals(first.session.version(),second.session.version())
            }
            compose.waitUntil(10000){compose.onAllNodesWithTag("acquisition-list").fetchSemanticsNodes().isNotEmpty()&&!second.acquisition.state.value.busy}
            if(same) {
                fieldsRetained()
                compose.waitUntil(10000){second.acquisition.state.value.playlist?.id?.value==job}
                assertEquals(listOf("GET /api/v1/playlist-imports/$job"),requests.drop(boundary).filter {it.contains("/playlist-imports/")})
            } else {
                assertTrue("Restored owner must not dispatch the previous owner's job",requests.drop(boundary).none {it.contains("/playlist-imports/")})
                // New owner defaults to Jobs, then opening the editor must reveal empty fields.
                scroll(hasText("Jobs"))
                compose.onNodeWithText("Jobs").assertIsSelected()
                compose.onNodeWithText("YouTube playlist").performClick()
                for(label in listOf("YouTube playlist URL","New playlist name (optional)","Playlist description (optional)")) {
                    val m=hasText(label) and hasSetTextAction();scroll(m)
                    compose.onNode(m).assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.EditableText,androidx.compose.ui.text.AnnotatedString("")))
                }
                val m=hasText("Maximum items (1–1000)") and hasSetTextAction();scroll(m);compose.onNode(m).assertTextContains("500")
                assertTrue(requests.drop(boundary).none {it.contains("/playlist-imports/")})
            }
            assertTrue(requests.drop(boundary).none {it.startsWith("POST ")&&it!="POST /api/v1/auth/refresh"})
            assertEquals(if(async)1 else 0,requests.drop(boundary).count {it=="POST /api/v1/auth/refresh"})
            assertEquals(1,requests.count {it=="POST /api/v1/playlist-imports"})
            assertEquals(before.queue,currentModel.playback.value.queue)
            assertEquals(before.selectedOccurrence,currentModel.playback.value.selectedOccurrence)
            assertFalse(currentModel.playback.value.isPlaying)
            assertTrue(requests.none {it.contains("/playback/urls")})
        } finally {
            releaseRefresh.countDown()
            compose.runOnIdle {stores.forEach {it.clear()};graphs.forEach {it.close()}}
            fixture.dispatcher=fallback
            io.submit {server.close()}.get(5,TimeUnit.SECONDS);io.shutdownNow()
        }
    }
}
