package com.soundq.android

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

/** Actual mounted root OnClick is invoked while main is held: child disposal cannot mask admission. */
class DiscoveryRootAdmissionTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun navigateRefusesUnenteredSourceBeforeDisposal()=exercise(false,false)
    @Test fun importsReplacementRefusesUnenteredSourceBeforeDisposal()=exercise(true,false)
    @Test fun navigateRetainsEnteredDecisionWithoutQueueBeforeDisposal()=exercise(false,true)
    @Test fun importsReplacementRetainsEnteredDecisionWithoutQueueBeforeDisposal()=exercise(true,true)

    private fun exercise(openImports:Boolean,enteredDecision:Boolean) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val graph=app.graph;val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val decisions=AtomicInteger();val queues=AtomicInteger();val entered=CountDownLatch(1);val release=CountDownLatch(1)
        val candidate="""{"candidateId":"candidate-1","provider":"youtube","sourceUrl":"https://youtu.be/fixture","title":"Admission source","downloadable":true}"""
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath
            if(path=="/api/v1/discovery/search")return reply("""{"query":"admission","results":[$candidate],"providers":[{"provider":"youtube","status":"ok"}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}""")
            if(path=="/api/v1/source-selections"&&request.method=="POST") {
                decisions.incrementAndGet();entered.countDown();check(release.await(5,TimeUnit.SECONDS))
                return reply("""{"id":"123e4567-e89b-12d3-a456-426614174020","sessionId":"123e4567-e89b-12d3-a456-426614174010","selectedCandidateId":"candidate-1","action":"selected","selectedCandidate":$candidate}""",201)
            }
            if(path=="/api/v1/queue/items"&&request.method=="POST") {queues.incrementAndGet();return reply("""{"queue":{"items":[]},"downloadJobId":"123e4567-e89b-12d3-a456-426614174071","idempotent":false}""",202)}
            return fallback.dispatch(request)
        }}
        val pool=Executors.newSingleThreadExecutor()
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("admission@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.rows.isNotEmpty()}
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Search sources").performTextInput("admission")
            compose.onNodeWithContentDescription("Search",useUnmergedTree=true).performScrollTo().performClick()
            compose.waitUntil(10000){graph.discovery.state.value.results?.rows?.size==1}
            val rootNode=if(openImports)compose.onNodeWithContentDescription("Imports",useUnmergedTree=true) else compose.onAllNodesWithText("Library").filterToOne(hasClickAction())
            val action=rootNode.fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
            val choice=compose.runOnIdle {
                val field=DiscoveryRepository::class.java.getDeclaredField("view").apply {isAccessible=true}
                val view=field.get(graph.discovery) as DiscoveryView
                graph.discovery.inspect(view,graph.discovery.state.value.results!!.rows.single())!!
            }
            // Retain the original native root callback even if inspection subsequently mounts a modal.
            val post=compose.runOnIdle {
                val field=ImportRepository::class.java.getDeclaredField("view").apply {isAccessible=true}
                graph.imports.claimSource(field.get(graph.imports) as ImportView,choice)!!
            }
            var work:Future<*>?=null
            if(enteredDecision) {work=pool.submit {graph.imports.submit(post)};assertTrue(entered.await(3,TimeUnit.SECONDS))} else release.countDown()
            compose.runOnIdle {
                assertTrue(choice.valid());assertTrue(action())
                // Main cannot run apply/disposal until this block returns. This is the disputed window.
                if(enteredDecision)release.countDown() else work=pool.submit {graph.imports.submit(post)}
                work!!.get(5,TimeUnit.SECONDS)
                assertFalse("root callback itself must revoke the mounted source",choice.valid())
                assertEquals(if(enteredDecision)1 else 0,decisions.get());assertEquals(0,queues.get())
                assertFalse(graph.imports.state.value.pending)
                if(enteredDecision) {
                    assertEquals("123e4567-e89b-12d3-a456-426614174020",graph.imports.state.value.sourceReceipt!!.decision!!.id)
                    assertEquals(SourceImportPhase.QueueRefused,graph.imports.state.value.sourceReceipt!!.phase)
                } else assertEquals(SourceImportPhase.DecisionRefused,graph.imports.state.value.sourceReceipt!!.phase)
            }
            compose.waitForIdle();assertFalse(choice.valid())
            assertNull(graph.imports.state.value.acknowledgement)
        }finally {release.countDown();pool.shutdownNow();server.dispatcher=fallback;graph.session.retire()}
    }
    private fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
}
