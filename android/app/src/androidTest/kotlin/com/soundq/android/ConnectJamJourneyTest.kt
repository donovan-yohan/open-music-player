package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import mockwebserver3.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Ordinary production root journey. Compile-only in this lane; no emulator/device authority. */
class ConnectJamJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun accountOpensPrivateDevicesThenCreatesInvitesAndEndsJamWithoutPlayback() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val fallback=ProductTransportFixture.server.dispatcher
        val calls=CopyOnWriteArrayList<String>()
        val requests=CopyOnWriteArrayList<String>()
        fun diagnostic(stage:String):String {
            val title=app.graph.library.state.value.rows.firstOrNull()?.title.orEmpty()
            val rows=compose.onAllNodes(hasText(title) and hasClickAction()).fetchSemanticsNodes().mapIndexed {index,node ->
                val dialog=generateSequence(node.parent){it.parent}.any {isDialog().matches(it)}
                "row[$index]:dialog=$dialog,selected=${isSelected().matches(node)},enabled=${isEnabled().matches(node)}"
            }
            val create=compose.onAllNodesWithText("Create Jam").fetchSemanticsNodes().map {"enabled=${isEnabled().matches(it)}"}
            val state=app.graph.jam.state.value
            return "$stage rows=$rows create=$create snapshot=${state.snapshot!=null} busy=${state.busy} uncertain=${state.uncertain} message=${state.message} presence=${app.graph.presence.capture()!=null} requests=${requests.take(80)}"
        }
        var device=""
        var jam=""
        val lease="123e4567-e89b-42d3-a456-426614174003"
        fun snapshot()="""{"jamId":"$jam","version":1,"state":"open","serverTime":"2026-10-29T00:00:00Z","expiresAt":"2030-01-01T00:00:00Z","hostSeenAt":"2026-10-29T00:00:00Z","nowPlaying":null,"catalog":[{"catalogItemId":"123e4567-e89b-42d3-a456-426614174002","title":"Fixture song","artist":"Fixture","durationMs":1000}],"requests":[]}"""
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                requests.add(request.method+" "+path)
                fun response(body:String,status:Int=200)=MockResponse.Builder().code(status).apply {if(status!=204)body(body)}.build()
                if(path=="/api/v1/me/devices"&&request.method=="POST") {
                    device=Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("deviceId").jsonPrimitive.content
                    return response("""{"device":{"deviceId":"$device","leaseId":"$lease","label":"Fixture Android","platform":"android","sequence":0,"lastSeenAt":"2026-10-29T00:00:00Z","leaseExpiresAt":"2030-01-01T00:00:00Z","playback":null}}""",201)
                }
                if(path=="/api/v1/me/devices/$device"&&request.method=="PUT") {
                    val sequence=Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("sequence").jsonPrimitive.long
                    return response("""{"device":{"deviceId":"$device","leaseId":"$lease","label":"Fixture Android","platform":"android","sequence":$sequence,"lastSeenAt":"2026-10-29T00:00:00Z","leaseExpiresAt":"2030-01-01T00:00:00Z","playback":null}}""")
                }
                if(path=="/api/v1/me/devices"&&request.method=="GET")return response("""{"devices":[],"serverTime":"2026-10-29T00:00:00Z"}""")
                if(path=="/api/v1/jams") {
                    calls.add("create");jam=Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("jamId").jsonPrimitive.content
                    return response(snapshot(),201)
                }
                if(path=="/api/v1/jams/$jam/invites") {calls.add("invite");return response("""{"joinToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","inviteExpiresAt":"2030-01-01T00:00:00Z"}""",201)}
                if(path=="/api/v1/jams/$jam/host")return response(snapshot())
                if(path=="/api/v1/jams/$jam"&&request.method=="DELETE"){calls.add("end");return response("",204)}
                if(path=="/api/v1/jams/$jam"&&request.method=="GET")return response(snapshot().dropLast(1)+",\"hostRequests\":[],\"memberCount\":0}")
                return fallback.dispatch(request)
            }
        }
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("connect@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()&&app.graph.presence.capture()!=null}
            val initial=app.graph.controller.state.value
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithText("Music tools").performScrollTo().performClick()
            compose.onNodeWithText("Connected devices").performScrollTo().performClick()
            compose.onNodeWithText("Host a Jam").performScrollTo().performClick()
            val offeredSong=hasText(app.graph.library.state.value.rows.first().title) and hasClickAction() and hasAnyAncestor(isDialog())
            compose.onNode(offeredSong).assertIsNotSelected().performScrollTo().assertIsDisplayed().performClick().assertIsSelected()
            val create=hasText("Create Jam") and hasAnyAncestor(isDialog())
            compose.onNode(create).performScrollTo().assertIsEnabled()
            println("SERVICES_DIAGNOSTIC "+diagnostic("selected-offered-song-before-create"))
            compose.onNode(create).performClick()
            try {compose.waitUntil(10000){app.graph.jam.state.value.snapshot!=null}}
            catch(failure:Throwable){throw AssertionError(diagnostic("snapshot-failure"),failure)}
            val guestOrigin=hasText("HTTPS guest website origin") and hasSetTextAction() and hasAnyAncestor(isDialog())
            compose.onNode(guestOrigin).performScrollTo().assertIsDisplayed().performTextInput("https://guest.example.test")
            compose.onNode(guestOrigin).assertTextContains("https://guest.example.test")
            compose.onNodeWithText("New invitation").performScrollTo().performClick()
            compose.waitUntil(5000){app.graph.jam.state.value.invite!=null}
            compose.onNodeWithContentDescription("Jam invitation QR code. Guests need access to the configured website.").assertExists()
            compose.onNodeWithText("End Jam").performScrollTo().performClick()
            compose.waitUntil(5000){app.graph.jam.state.value.snapshot==null}
            assertEquals(listOf("create","invite","end"),calls.toList())
            assertEquals(initial.queue,app.graph.controller.state.value.queue)
            assertEquals(initial.selectedOccurrence,app.graph.controller.state.value.selectedOccurrence)
            assertFalse(app.graph.controller.state.value.isPlaying)
            assertTrue(requests.none {it=="POST /api/v1/playback/urls"||it.startsWith("GET /media/")})
            println("SERVICES_DIAGNOSTIC completed create-invite-end requests=${requests.take(80)}")
        }finally {ProductTransportFixture.server.dispatcher=fallback;app.graph.session.retire()}
    }
}
