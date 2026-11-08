package com.soundq.android.playback.mix

import com.soundq.android.data.*
import com.soundq.android.data.mix.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class StemPublicationTest {
    private val hash="sha256:"+"a".repeat(64)
    private val model="audio-separator-htdemucs-ft-4s-v1"
    private val roles=listOf("vocals","drums","bass","other")
    internal val edits=Json.parseToJsonElement("""{"schemaVersion":1,"channelSet":"stems4-demucs-v1","stemModelVersion":"$model","sourceFileHash":"$hash","events":[]}""").jsonObject
    internal fun fixture():JsonObject {
        val objects=roles.mapIndexed {i,role ->buildJsonObject {
            put("channel",role);put("key","stems/7/$model/${hash.substring(7)}/g1/$role/${i.toString().repeat(64)}.opus");put("sha256",i.toString().repeat(64));put("bytes",10)
            put("derivation","separator");put("sample_frames",24000);put("sample_rate_hz",48000);put("channels",2);put("duration_ms",500);put("origin_frame",0);put("delay_frames",0);put("encoder_delay_frames",312);put("delay_provenance","ffmpeg-ogg-opus-preskip-end-trim-v1")
        }}
        return buildJsonObject {
            put("schemaVersion",1);put("trackId",7);put("status","ready");put("channelSet","stems4-demucs-v1");put("stemModelVersion",model);put("sourceFileHash",hash);put("generation",1)
            put("publishedManifest",buildJsonObject {
                put("source_storage_key","fixture/source.opus");put("schema_version",1);put("track_id",7);put("channel_set","stems4-demucs-v1");put("stem_model_version",model);put("source_file_hash",hash);put("generation",1);put("duration_ms",500)
                put("provenance",buildJsonObject {put("worker","stemsep-worker");put("worker_version","2026-08-30-1")})
                put("artifacts",buildJsonObject {put("codec",buildJsonObject {put("name","libopus");put("sample_rate_hz",48000);put("channels",2)});put("objects",JsonArray(objects));put("energy",buildJsonObject {put("frame_hz",80);put("frame_count",40);put("encoding","uint8-linear");put("channels",buildJsonObject {roles.forEach {put(it,java.util.Base64.getEncoder().encodeToString(ByteArray(40)))}})})})
            })
            put("memberDownloads",JsonArray(objects.reversed().map {o ->buildJsonObject {
                put("channel",o.getValue("channel"));put("key",o.getValue("key"));put("sha256",o.getValue("sha256"));put("bytes",10);put("url","https://media.invalid/member");put("expiresAt","2030-01-01T00:00:00Z")
            }}))
        }
    }
    @Test fun exactPublicationRetainsCanonicalDisjointOrderAndRejectsIdentityDrift() {
        val f=fixture();assertEquals(roles,StemPublication.parse(f,7,edits).channels)
        val bad=listOf(f.toString().replace("\"generation\":1","\"generation\":2"),f.toString().replace("\"sample_frames\":24000","\"sample_frames\":24001"),f.toString().replace("\"origin_frame\":0","\"origin_frame\":1"),f.toString().replace("https://media.invalid/member","http://media.invalid/member"),f.toString().replace("2030-01-01","2020-01-01"))
        // A one-frame PCM difference can satisfy rounded duration, but native probe enforces exact declared extent.
        bad.filterIndexed {index,_->index!=1}.forEach {assertTrue(runCatching {StemPublication.parse(Json.parseToJsonElement(it).jsonObject,7,edits)}.isFailure)}
    }
    @Test fun authenticatedStatusReadsOnlyAndHasNoAutomaticSeparationWrite() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val api=SoundQApi(session,f.client);f.reply(fixture().toString())
            StemPublication.parse(api.mixStemStatus(session.capture()!!,7,"stems4-demucs-v1"){true},7,edits)
            val request=f.server.takeRequest()!!;assertEquals("GET",request.method);assertEquals("1",request.url.queryParameter("includeUrls"));assertEquals("stems4-demucs-v1",request.url.queryParameter("channelSet"));assertEquals(1,f.server.requestCount)
        }
    }
}
