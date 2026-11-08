package com.soundq.android.data.cache

import com.soundq.android.data.*
import mockwebserver3.*
import okhttp3.Request
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class TemporaryCacheTlsTest {
    @Test fun trustedDescriptorAndFullMediaTransferProduceReconstructedExactBytesWithoutDeletingDeviceCopies() {
        HttpsFixture().use {tls ->
            val dir=Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"cache-tls").toFile().canonicalFile
            try {
                val session=AccountSession(tls.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
                val scope=session.capture()!!;val api=SoundQApi(session,tls.client)
                val cache=TemporaryAudioCache(dir.resolve("temporary"),session)
                val explicit=dir.resolve("device-downloads/explicit.audio").apply {parentFile!!.mkdirs();writeText("device copy")}
                val bytes=ByteArray(1024){(it%127).toByte()}
                tls.reply("""{"urls":[{"trackId":7,"url":"${tls.server.url("/media/audio.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":1024}]}""")
                tls.server.enqueue(MockResponse.Builder().body(Buffer().write(bytes)).build())
                val descriptor=api.descriptor(scope,TrackId(7));val write=cache.begin(scope,TrackId(7),descriptor.sizeBytes!!)!!
                tls.client.newCall(Request.Builder().url(descriptor.url).build()).execute().use {response->
                    assertEquals(200,response.code);assertEquals(1024L,response.body.contentLength())
                    response.body.byteStream().use {input->val buffer=ByteArray(79);while(true){val n=input.read(buffer);if(n<0)break;write.append(buffer,0,n)}}
                }
                assertTrue(write.finish())
                val auth=tls.server.takeRequest();assertEquals("/api/v1/playback/urls",auth.url.encodedPath);assertNotNull(auth.headers["Authorization"])
                assertNull(tls.server.takeRequest().headers["Authorization"])
                val reconstructed=TemporaryAudioCache(dir.resolve("temporary"),session)
                val lease=reconstructed.acquire(scope,TrackId(7))!!;val actual=ByteArray(1024);assertEquals(1024,lease.read(actual,0,1024));assertArrayEquals(bytes,actual)
                assertEquals(1,reconstructed.clear().deferredFiles);assertEquals("device copy",explicit.readText());lease.close()
                assertEquals(0L,reconstructed.status().bytes);assertEquals(2,tls.server.requestCount)
            }finally {dir.deleteRecursively()}
        }
    }
}
