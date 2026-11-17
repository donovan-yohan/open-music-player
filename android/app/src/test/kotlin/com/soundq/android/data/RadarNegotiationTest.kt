package com.soundq.android.data

import com.soundq.android.data.discovery.RadarJson
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** Exercise negotiation through the actual authorized transport, not a replacement authorized facade. */
class RadarNegotiationTest {
    private fun fixture():JsonObject {
        val path=System.getProperty("soundq.radar.wire")
        return Json.parseToJsonElement(if(path==null)javaClass.getResource("/release-radar-wire.json")!!.readText() else File(path).readText()).jsonObject
    }
    @Test fun policyHeaderTraversesRealTransportAndOldBackendV1StillWorks() {
        HttpsFixture().use {fixture->
            val session=AccountSession(fixture.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,fixture.client)
            val original=fixture()
            fixture.reply(original.toString())
            val page=api.releaseRadar(session.capture()!!){true}
            val request=fixture.server.takeRequest()
            assertEquals("GET",request.method)
            assertEquals("/api/v1/me/discovery/releases",request.url.encodedPath)
            assertEquals(listOf("recording-radar-v2"),request.headers.values("X-SoundQ-Radar-Policy"))
            assertEquals("Bearer a",request.headers["Authorization"])
            assertEquals("recording-radar-v1",original.getValue("policyVersion").jsonPrimitive.content)
            assertEquals(RadarJson.page(original).songs.single().recording,page.songs.single().recording)
            assertNull(page.songs.single().artwork)
        }
    }
    @Test fun explicitV2TraversesRealTransportWithoutPretendingRequestHeaderIsResponsePolicy() {
        HttpsFixture().use {fixture->
            val session=AccountSession(fixture.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,fixture.client)
            val original=fixture()
            val response=JsonObject(original+mapOf("policyVersion" to JsonPrimitive("recording-radar-v2")))
            fixture.reply(response.toString())
            val page=api.releaseRadar(session.capture()!!){true}
            assertEquals("recording-radar-v2",fixture.server.takeRequest().headers["X-SoundQ-Radar-Policy"])
            assertEquals(RadarJson.page(response).songs.single().title,page.songs.single().title)
        }
    }
}
