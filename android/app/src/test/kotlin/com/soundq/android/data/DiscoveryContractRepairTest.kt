package com.soundq.android.data

import com.soundq.android.data.discovery.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class DiscoveryContractRepairTest {
    @Test fun ordinaryDisjointFanoutAccepts25And36RowsThroughTlsRepository() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val repository=DiscoveryRepository(session,SoundQApi(session,f.client));val route=repository.open()!!
            for(count in listOf(25,36)) {
                repository.edit(route,"海 & music");f.reply(fanout(count));repository.search(route,repository.state.value.draft)
                assertEquals("Go limit12 fans out over three surfaces: $count unique rows are valid",DiscoveryPhase.Ready,repository.state.value.phase)
                assertEquals(count,repository.state.value.results!!.rows.size)
                assertNotNull(repository.inspect(route,repository.state.value.results!!.rows.last()))
            }
            assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun excessiveDuplicateAndMalformedFanoutStayRefused() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client)
            for(body in listOf(fanout(37),fanout(51),fanout(36).replace("candidate-35","candidate-34"),fanout(36).replace("\"downloadable\":true","\"downloadable\":\"true\""))) {
                f.reply(body)
                assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {api.discoverySearch(session.capture()!!,"海 & music")}.exceptionOrNull() as SafeFailure).reason)
            }
            assertEquals(4,f.server.requestCount)
        }
    }
    companion object {
        fun fanout(count:Int):String {
            val base=Json.parseToJsonElement(DiscoveryBoundaryTest.search()).jsonObject
            return JsonObject(base+mapOf("providers" to buildJsonArray {
                add(buildJsonObject {put("provider","youtube");put("status","ok");put("resultCount",minOf(count,24));put("elapsedMs",1)})
                add(buildJsonObject {put("provider","soundcloud");put("status","ok");put("resultCount",maxOf(count-24,0));put("elapsedMs",1)})
            },"results" to JsonArray((0 until count).map { i ->
                val provider=if(i<24)"youtube" else "soundcloud"
                val source=if(i<24)"https://youtu.be/fixture$i" else "https://soundcloud.com/fixture/track$i"
                buildJsonObject {put("candidateId","candidate-$i");put("provider",provider);put("sourceUrl",source);put("title","Source $i");put("durationMs",12000);put("downloadable",true)}
            }))).toString()
        }
    }
}
