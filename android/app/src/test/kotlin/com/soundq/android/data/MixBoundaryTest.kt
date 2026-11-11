package com.soundq.android.data

import com.soundq.android.data.mix.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class MixBoundaryTest {
    private val id="00000000-0000-4000-8000-000000000001"
    private val clip=MixJson.clip(Json.parseToJsonElement("""{"clipId":"clip-a","queueItemId":"occurrence-a","trackId":7,"sourceStartMs":100,"sourceEndMs":600,"timelineStartMs":250,"gainDb":-6,"pitchMode":"preserve","tempoPolicy":"volumeOnly"}""").jsonObject)
    private fun response(version:Int=1,name:String="Fixture")="""{"id":"$id","schemaVersion":1,"name":"$name","clips":[${clip.json}],"version":$version,"summary":{"clipCount":1,"trackIds":[7],"durationMs":750},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"""
    @Test fun savedMixCreateIsVersionedAndReadBackWithoutChangingOccurrenceOrTrim() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!
            f.reply(response(),201);f.reply(response())
            val saved=api.saveMix(scope,null,"Fixture",listOf(clip)){true}
            assertEquals(clip,saved.clips.single())
            val post=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("POST",post.method);assertEquals("/api/v1/mix-plans",post.url.encodedPath)
            assertEquals(MixJson.draft("Fixture",listOf(clip)),Json.parseToJsonElement(post.body!!.utf8()))
            assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
            f.reply(response(2,"Renamed"));f.reply(response(2,"Renamed"))
            assertEquals(2L,api.saveMix(scope,saved,"Renamed",saved.clips){true}.version)
            val put=f.server.takeRequest(2,TimeUnit.SECONDS)!!;assertEquals("PUT",put.method)
            assertEquals(1,Json.parseToJsonElement(put.body!!.utf8()).jsonObject.getValue("version").jsonPrimitive.int)
            assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
        }
    }
    @Test fun uncertainSaveDoesNotRetryAndRetiredRouteCannotDispatch() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!
            f.reply("{}",503)
            assertEquals(SafeFailure.Reason.Uncertain,(runCatching {api.saveMix(scope,null,"Fixture",listOf(clip)){true}}.exceptionOrNull() as SafeFailure).reason)
            assertEquals(1,f.server.requestCount)
            assertTrue(runCatching {api.saveMix(scope,null,"Fixture",listOf(clip)){false}}.isFailure)
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun savedSourceTimeStemDocumentIsAdmittedToTheCapableNativeConsumer() {
        val stem=Json.parseToJsonElement("""{"schemaVersion":1,"channelSet":"stems4-demucs-v1","stemModelVersion":"audio-separator-htdemucs-ft-4s-v1","sourceFileHash":"sha256:${"a".repeat(64)}","events":[{"channel":"vocals","atMs":125,"gain":0.25,"rampMs":10}]}""")
        val c=MixJson.clip(JsonObject(clip.json+("stemEdits" to stem)))
        assertTrue("Supported source-time edits must reach preparation, not a permanent replay refusal",SavedMix(id,1,"Fixture",listOf(c)).playable())
    }
    @Test fun stringGainsAreRejectedBeforeAuthenticatedSaveCanDispatch() {
        assertTrue("Numeric strings must not become accepted mix gains",runCatching {MixJson.clip(JsonObject(clip.json+("gainDb" to JsonPrimitive("-6"))))}.isFailure)
    }
    @Test fun unknownClipFieldsFifthOverlapAndMalformedStemGainsRefuseWithoutCoercion() {
        assertTrue(runCatching {MixJson.clip(JsonObject(clip.json+("rate" to JsonPrimitive(1.2))))}.isFailure)
        val five=(1..5).map {MixJson.clip(JsonObject(clip.json+("clipId" to JsonPrimitive("clip-$it"))))}
        assertTrue(runCatching {MixJson.draft("Fixture",five)}.isFailure)
        val stem=Json.parseToJsonElement("""{"schemaVersion":1,"channelSet":"stems4-demucs-v1","stemModelVersion":"audio-separator-htdemucs-ft-4s-v1","sourceFileHash":"sha256:${"a".repeat(64)}","events":[{"channel":"vocals","atMs":125,"gain":0.25,"rampMs":10}]}""")
        val supported=MixJson.clip(JsonObject(clip.json+("stemEdits" to stem)))
        assertEquals(stem,MixJson.draft("Fixture",listOf(supported))["clips"]!!.jsonArray.single().jsonObject["stemEdits"])
        assertTrue(runCatching {MixJson.clip(JsonObject(clip.json+("stemEdits" to Json.parseToJsonElement(stem.toString().replace("0.25","1.25")))))}.isFailure)
    }
}
