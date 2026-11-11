package com.soundq.android.playback.mix

import com.soundq.android.data.*
import com.soundq.android.data.mix.*
import kotlinx.serialization.json.*
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Assume.assumeNotNull
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

class StemPreparationTest {
    @Test fun realHttpsVerifiedBytesNativeProbeAndSavedAutomationShareOneConsumer() {
        val fixture=System.getProperty("soundq.mix.fixture");assumeNotNull(fixture)
        HttpsFixture().use {f ->
            val bytes=File(fixture!!,"0.opus").readBytes();val digest=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(""){"%02x".format(it)}
            var raw=StemPublicationTest().fixture().toString()
            for(i in 0..3)raw=raw.replace(i.toString().repeat(64),digest)
            raw=raw.replace("\"bytes\":10","\"bytes\":${bytes.size}").replace("https://media.invalid/member",f.server.url("/media/member").toString())
            val status=Json.parseToJsonElement(raw).jsonObject
            val edits=JsonObject(StemPublicationTest().edits+("events" to Json.parseToJsonElement("""[{"channel":"vocals","atMs":150,"gain":0.2,"rampMs":10}]""")))
            val c=MixJson.clip(buildJsonObject {put("clipId","a");put("queueItemId","occ-a");put("trackId",7);put("sourceStartMs",50);put("sourceEndMs",300);put("timelineStartMs",0);put("stemEdits",edits)})
            val plan=SavedMix("00000000-0000-4000-8000-000000000001",1,"Generated",listOf(c))
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!
            val dir=Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"stem-prepare-").toFile()
            try {
                f.reply(status.toString());f.server.enqueue(MockResponse.Builder().body(Buffer().write(bytes)).build())
                var reserved=0L
                StemPreparation(dir,api,scope,f.client,{session.current(scope)},{reserved+=it}).use {prep ->
                    val prepared=prep.prepare(plan)
                    assertEquals(bytes.size.toLong(),reserved);assertEquals(1,dir.listFiles()!!.size)
                    NativeMixStream(plan,emptyMap(),prepared).use {stream ->assertEquals(8192,stream.read(44,ByteArray(8192),0,8192))}
                    assertEquals("GET",f.server.takeRequest()!!.method)
                    assertNull(f.server.takeRequest()!!.headers["Authorization"])
                    assertEquals(2,f.server.requestCount)
                }
                assertTrue(dir.listFiles()!!.isEmpty())
                // Correct size but wrong encoded digest cannot be admitted, even if Opus would decode.
                f.reply(status.toString());f.server.enqueue(MockResponse.Builder().body(Buffer().write(bytes.clone().also {it[50]=(it[50].toInt() xor 1).toByte()})).build())
                StemPreparation(dir,api,scope,f.client,{true},{}).use {assertTrue(runCatching {it.prepare(plan)}.isFailure)}
                assertTrue(dir.listFiles()!!.isEmpty())
            }finally {dir.deleteRecursively()}
        }
    }
}
