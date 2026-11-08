package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Compiled platform journey. Execution is reserved for the parent runtime owner. */
class MixJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun mountedMixRouteLoadsRenamesAndReadsBackTheSameOccurrenceDocument() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val original=ProductTransportFixture.server.dispatcher
        val methods=CopyOnWriteArrayList<String>()
        var name="Generated mix";var version=1
        val id="00000000-0000-4000-8000-000000000001"
        fun saved()="""{"id":"$id","schemaVersion":1,"name":"$name","version":$version,"clips":[{"clipId":"clip-a","queueItemId":"occ-a","trackId":1,"sourceStartMs":50,"sourceEndMs":1000,"timelineStartMs":100,"gainDb":0,"pitchMode":"preserve","tempoPolicy":"volumeOnly"}],"summary":{"clipCount":1,"trackIds":[1],"durationMs":1050},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"""
        ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            if(!request.url.encodedPath.startsWith("/api/v1/mix-plans"))return original.dispatch(request)
            methods+=request.method+" "+request.url.encodedPath
            if(request.method=="PUT") {
                val body=request.body!!.utf8();assertTrue(body.contains("\"queueItemId\":\"occ-a\""));assertTrue(body.contains("\"version\":1"))
                name="Renamed mix";version=2
            }
            val body=if(request.url.encodedPath=="/api/v1/mix-plans")"""{"data":[${saved()}],"total":1,"limit":20,"offset":0}"""else saved()
            return MockResponse.Builder().code(200).body(body).build()
        }}
        try {
            app.graph.session.retire()
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("mix@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Mixes").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Mixes").performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Generated mix").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Generated mix").performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Mix name").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Mix name").performTextReplacement("Renamed mix")
            compose.onNodeWithText("Save mix").performScrollTo().performClick()
            compose.waitUntil(10000){methods.size==4}
            compose.waitForIdle()
            assertEquals(listOf("GET /api/v1/mix-plans","GET /api/v1/mix-plans/$id","PUT /api/v1/mix-plans/$id","GET /api/v1/mix-plans/$id"),methods.toList())
        }finally {ProductTransportFixture.server.dispatcher=original;app.graph.session.retire()}
    }
}
