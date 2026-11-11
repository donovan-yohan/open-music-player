package com.soundq.android

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.product.ProductViewModel
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Ordinary routed UI. Actual producer bytes, synthetic HTTPS transport. Not executed by compilation. */
class MixExchangeJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    private fun reveal(matcher:SemanticsMatcher):SemanticsNodeInteraction {
        compose.onAllNodes(hasScrollToNodeAction()).filterToOne(hasAnyDescendant(hasText("Mixes"))).performScrollToNode(matcher)
        return compose.onNode(matcher).assertIsDisplayed().assertIsEnabled()
    }
    private fun click(label:String)=compose.onNode(hasText(label) and hasClickAction()).performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()

    @Test fun savedExportCopiesOnlyReceivedMetadataAndImportSelectsOnlyMatchingReadback() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        fun asset(name:String)=instrumentation.context.assets.open("mix-exchange/$name").bufferedReader().use {it.readText()}
        val rawInput=asset("import-input.json")
        val rawAck=asset("import-ack.json")
        val rawReadback=asset("import-readback.json")
        val rawExport=asset("export.json")
        val imported=Json.parseToJsonElement(rawAck).jsonObject
        val importedId=imported.getValue("id").jsonPrimitive.content
        val seedId="00000000-0000-4000-8000-000000000081"
        val seed=JsonObject(imported+mapOf("id" to JsonPrimitive(seedId),"name" to JsonPrimitive("Saved evening set")))
        val seedName=seed.getValue("name").jsonPrimitive.content
        val importedName=imported.getValue("name").jsonPrimitive.content
        val original=ProductTransportFixture.server.dispatcher
        val calls=CopyOnWriteArrayList<String>()
        val bodies=CopyOnWriteArrayList<String>()
        val requestedReadback=CountDownLatch(1)
        val releaseReadback=CountDownLatch(1)
        var acceptedCreate=false
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(!path.startsWith("/api/v1/mix-plans"))return original.dispatch(request)
                calls.add(request.method+" "+path)
                fun reply(body:String,status:Int=200)=MockResponse.Builder().code(status).body(body).build()
                if(path=="/api/v1/mix-plans"&&request.method=="GET")return reply(buildJsonObject {
                    put("data",JsonArray(if(acceptedCreate)listOf(seed,imported)else listOf(seed)))
                    put("total",if(acceptedCreate)2 else 1);put("limit",20);put("offset",0)
                }.toString())
                if(path=="/api/v1/mix-plans/$seedId/export"&&request.method=="GET")return reply(rawExport)
                if(path=="/api/v1/mix-plans/$seedId"&&request.method=="GET")return reply(seed.toString())
                if(path=="/api/v1/mix-plans/import"&&request.method=="POST") {
                    bodies.add(request.body!!.utf8())
                    if(bodies.size==1)return reply("""{"code":"MISSING_SOURCES","message":"private server detail must not be displayed"}""",422)
                    acceptedCreate=true
                    return reply(rawAck,201)
                }
                if(path=="/api/v1/mix-plans/$importedId"&&request.method=="GET") {
                    requestedReadback.countDown()
                    check(releaseReadback.await(10,TimeUnit.SECONDS)){"Readback fixture gate was not released"}
                    return reply(rawReadback)
                }
                return reply("{}",404)
            }
        }
        try {
            graph.session.retire()
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("mix-exchange@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.session.state.value is AuthState.SignedIn}
            compose.onNode(hasText("Mixes") and hasClickAction()).assertIsDisplayed().assertIsEnabled().performClick()
            reveal(hasText(seedName) and hasClickAction()).performClick()
            compose.waitUntil(10000){compose.onAllNodes(hasText("Mix name") and hasSetTextAction()).fetchSemanticsNodes().size==1}
            reveal(hasText("Mix name") and hasSetTextAction()).performTextReplacement("Unsaved local rename")
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val before=model.playback.value
            val requestsBefore=ProductTransportFixture.requests.size
            reveal(hasContentDescription("Mix import and export")).performClick()
            click("Export saved mix")
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Mix JSON").fetchSemanticsNodes().any {
                it.config.contains(androidx.compose.ui.semantics.SemanticsProperties.EditableText)&&
                    it.config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text==rawExport
            }}
            compose.onNodeWithContentDescription("Mix JSON").assertIsEnabled().assertTextContains(rawExport)
            click("Copy JSON")
            compose.runOnIdle {
                val clipboard=instrumentation.targetContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                assertEquals(rawExport,clipboard.primaryClip!!.getItemAt(0).text.toString())
            }
            compose.onNodeWithContentDescription("Back to mix exchange").performScrollTo().performClick()
            click("Import mix")
            compose.onNodeWithContentDescription("Mix JSON").performScrollTo().performTextReplacement(rawInput)
            click("Import mix")
            compose.waitUntil(10000){bodies.size==1&&compose.onAllNodesWithText("Matching audio is missing").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Mix JSON").assertTextContains(rawInput)
            compose.onNodeWithText("private server detail must not be displayed").assertDoesNotExist()
            assertFalse(calls.any {it=="GET /api/v1/mix-plans/$importedId"})
            click("Import mix")
            compose.waitUntil(10000){requestedReadback.count==0L}
            compose.onNodeWithContentDescription("Mix JSON").assertTextContains(rawInput)
            compose.onNode(hasText("Import mix") and hasClickAction()).assertIsNotEnabled()
            assertEquals(2,bodies.size)
            assertFalse(calls.any {it.startsWith("PUT ")})
            // This producer marker is before the held response, not acceptance.
            compose.onNodeWithText("Mix imported").assertDoesNotExist()
            releaseReadback.countDown()
            compose.waitUntil(10000){compose.onAllNodesWithText("Mix imported").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Mix JSON").assertDoesNotExist()
            reveal(hasText("Mix name") and hasSetTextAction()).assertTextContains(importedName)
            assertEquals(listOf(rawInput,rawInput),bodies.toList())
            assertEquals(1,calls.count {it=="GET /api/v1/mix-plans/$seedId/export"})
            assertEquals(1,calls.count {it=="GET /api/v1/mix-plans/$importedId"})
            assertEquals(2,calls.count {it=="POST /api/v1/mix-plans/import"})
            assertFalse(calls.any {it.startsWith("PUT ")})
            val after=model.playback.value
            assertEquals(before.queue,after.queue);assertEquals(before.selectedOccurrence,after.selectedOccurrence)
            assertEquals(before.selectionIncarnation,after.selectionIncarnation);assertEquals(before.positionMs,after.positionMs)
            assertEquals(before.isPlaying,after.isPlaying)
            assertFalse(ProductTransportFixture.requests.drop(requestsBefore).any {it.contains("playback/urls")||it.contains("/media/")||it.contains("/downloads")})
        } finally {
            releaseReadback.countDown()
            ProductTransportFixture.server.dispatcher=original
            graph.session.retire()
        }
    }
}
