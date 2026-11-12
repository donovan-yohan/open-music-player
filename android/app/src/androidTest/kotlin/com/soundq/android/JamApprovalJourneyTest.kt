package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.playback.PlaybackProjection
import com.soundq.android.product.ProductViewModel
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Ordinary host UI -> repository -> MediaController -> sole service -> request receipt. */
class JamApprovalJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    @Test fun approvalWaitsForServiceReceiptAndReadbackWithoutAutoplayOrReinsertion() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val fallback=ProductTransportFixture.server.dispatcher
        val calls=CopyOnWriteArrayList<String>()
        val decisions=AtomicInteger()
        val hostReads=AtomicInteger()
        val version=AtomicInteger(1)
        val status=AtomicReference("pending")
        val receipt=AtomicReference<JsonObject?>(null)
        val decisionEntered=CountDownLatch(1)
        val releaseDecision=CountDownLatch(1)
        val catalog="123e4567-e89b-42d3-a456-426614174002"
        val requestId="123e4567-e89b-42d3-a456-426614174001"
        val lease="123e4567-e89b-42d3-a456-426614174003"
        var device=""
        var jam=""
        fun requestJson(private:Boolean)=buildJsonObject {
            put("requestId",requestId);put("catalogItemId",catalog);put("displayName","Guest");put("status",status.get())
            if(private){put("trackId",1);receipt.get()?.takeIf {status.get()=="queued"}?.let {put("receipt",it)}}
        }
        fun snapshot(private:Boolean)=buildJsonObject {
            put("jamId",jam);put("version",version.get());put("state","open")
            put("serverTime","2026-10-29T00:00:00Z");put("expiresAt","2030-01-01T00:00:00Z")
            put("hostSeenAt","2026-10-29T00:00:00Z");put("nowPlaying",JsonNull)
            put("catalog",buildJsonArray {add(buildJsonObject {
                put("catalogItemId",catalog);put("title","Fixture 1");put("artist","Synthetic ensemble");put("durationMs",12000)
            })})
            put("requests",buildJsonArray {add(requestJson(false))})
            if(private){put("hostRequests",buildJsonArray {add(requestJson(true))});put("memberCount",1)}
        }.toString()
        fun deviceJson(sequence:Long)="""{"deviceId":"$device","leaseId":"$lease","label":"Fixture Android","platform":"android","sequence":$sequence,"lastSeenAt":"2026-10-29T00:00:00Z","leaseExpiresAt":"2030-01-01T00:00:00Z","playback":null}"""
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                calls.add(request.method+" "+path)
                fun response(body:String,status:Int=200)=MockResponse.Builder().code(status).apply {if(status!=204)body(body)}.build()
                if(path=="/api/v1/me/devices"&&request.method=="POST") {
                    device=Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("deviceId").jsonPrimitive.content
                    return response("""{"device":${deviceJson(0)}}""",201)
                }
                if(path=="/api/v1/me/devices/$device"&&request.method=="PUT") {
                    val sequence=Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("sequence").jsonPrimitive.long
                    return response("""{"device":${deviceJson(sequence)}}""")
                }
                if(path=="/api/v1/me/devices"&&request.method=="GET")return response("""{"devices":[],"serverTime":"2026-10-29T00:00:00Z"}""")
                if(path=="/api/v1/jams"&&request.method=="POST") {
                    val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                    assertEquals(listOf(1L),body.getValue("trackIds").jsonArray.map {it.jsonPrimitive.long})
                    jam=body.getValue("jamId").jsonPrimitive.content
                    return response(snapshot(false),201)
                }
                if(path=="/api/v1/jams/$jam/host"&&request.method=="PUT")return response(snapshot(false))
                if(path=="/api/v1/jams/$jam"&&request.method=="GET"){hostReads.incrementAndGet();return response(snapshot(true))}
                if(path=="/api/v1/jams/$jam/requests/$requestId"&&request.method=="PUT") {
                    decisions.incrementAndGet()
                    val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                    assertEquals(1L,body.getValue("expectedVersion").jsonPrimitive.long)
                    assertEquals("queued",body.getValue("status").jsonPrimitive.content)
                    val admitted=body.getValue("receipt").jsonObject
                    assertEquals(requestId,admitted.getValue("requestId").jsonPrimitive.content)
                    assertTrue(admitted.getValue("sessionId").jsonPrimitive.content.isNotBlank())
                    assertTrue(admitted.getValue("occurrenceId").jsonPrimitive.content.isNotBlank())
                    receipt.set(admitted);decisionEntered.countDown()
                    check(releaseDecision.await(20,TimeUnit.SECONDS)){"Decision fixture was not released"}
                    status.set("queued");version.incrementAndGet()
                    return response(requestJson(false).toString())
                }
                return fallback.dispatch(request)
            }
        }
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("jam-approval@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            val model=compose.runOnIdle {androidx.lifecycle.ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(10000){app.graph.library.state.value.rows.size==3&&app.graph.presence.capture()!=null&&model.playback.value.connection==PlaybackProjection.Connection.Connected&&app.graph.jamAdmission.incarnation!=null}
            compose.waitUntil(10000){compose.runOnIdle {acknowledgedQueueObservation(model).readback.acknowledged(0,null)}}
            compose.runOnIdle {
                val initial=acknowledgedQueueObservation(model).readback
                assertTrue(initial.acknowledged(0,null))
            }
            compose.onNodeWithContentDescription("Settings").assertIsDisplayed().performClick()
            compose.onNodeWithText("Music tools").performScrollTo().performClick()
            compose.onNodeWithText("Connected devices").performScrollTo().assertIsDisplayed().performClick()
            compose.onNodeWithText("Host a Jam").performScrollTo().assertIsDisplayed().performClick()
            val offered=hasText("Fixture 1")and hasClickAction()and hasAnyAncestor(isDialog())
            compose.onNode(offered).performScrollTo().assertIsDisplayed().assertIsNotSelected().performClick().assertIsSelected()
            compose.onNodeWithText("Create Jam").performScrollTo().assertIsEnabled().performClick()
            compose.waitUntil(10000){app.graph.jam.state.value.snapshot!=null&&!app.graph.jam.state.value.busy}
            compose.onNodeWithText("Refresh requests").performScrollTo().assertIsEnabled().performClick()
            compose.waitUntil(10000){app.graph.jam.state.value.snapshot?.requests?.singleOrNull()?.trackId?.value==1L&&!app.graph.jam.state.value.busy}
            compose.onNode(hasContentDescription("More for Fixture 1") and hasAnyAncestor(isDialog())).performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
            compose.onNodeWithText("Approve Fixture 1").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
            compose.waitUntil(10000){decisionEntered.count==0L}
            val admitted=checkNotNull(receipt.get())
            val occurrence=admitted.getValue("occurrenceId").jsonPrimitive.content
            compose.waitUntil(10000){compose.runOnIdle {acknowledgedQueueObservation(model).readback.acknowledged(1,occurrence)}}
            compose.runOnIdle {
                val current=acknowledgedQueueObservation(model)
                val item=current.projection.queue.single()
                assertEquals(occurrence,item.occurrenceId);assertEquals(1L,item.trackId)
                assertTrue(item.manual);assertEquals("Manual",item.origin.name)
                assertFalse(current.projection.isPlaying);assertFalse(current.projection.preparing)
                assertTrue(app.graph.jam.state.value.busy)
                assertEquals("pending",app.graph.jam.state.value.snapshot!!.requests.single().status)
                assertNotEquals("Decision saved.",app.graph.jam.state.value.message)
            }
            assertEquals(1,decisions.get())
            assertTrue(calls.none {it=="POST /api/v1/playback/urls"||it.startsWith("GET /media/")})
            releaseDecision.countDown()
            compose.waitUntil(10000){app.graph.jam.state.value.snapshot?.requests?.singleOrNull()?.status=="queued"&&!app.graph.jam.state.value.busy}
            val accepted=app.graph.jam.state.value.snapshot!!.requests.single().receipt!!
            assertEquals(requestId,accepted.requestId);assertEquals(occurrence,accepted.occurrenceId)
            assertEquals(admitted.getValue("sessionId").jsonPrimitive.content,accepted.sessionId)
            compose.onNodeWithText("Decision saved.").performScrollTo().assertIsDisplayed()
            val beforeRefresh=hostReads.get()
            compose.onNodeWithText("Refresh requests").performScrollTo().assertIsEnabled().performClick()
            compose.waitUntil(10000){hostReads.get()>beforeRefresh&&app.graph.jam.state.value.snapshot?.version==2L&&!app.graph.jam.state.value.busy}
            compose.runOnIdle {assertTrue(acknowledgedQueueObservation(model).readback.acknowledged(1,occurrence))}
            assertEquals(1,decisions.get())
            assertEquals(1,calls.count {it=="POST /api/v1/jams"})
            assertTrue(calls.none {it=="POST /api/v1/playback/urls"||it.startsWith("GET /media/")})
        } finally {
            releaseDecision.countDown();ProductTransportFixture.server.dispatcher=fallback
            app.graph.jam.retire();app.graph.session.retire()
        }
    }
}
