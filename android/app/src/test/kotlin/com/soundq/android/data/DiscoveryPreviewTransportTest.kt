package com.soundq.android.data

import com.soundq.android.data.imports.ImportSource
import mockwebserver3.MockResponse
import mockwebserver3.MockResponseBody
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okio.Buffer
import okio.BufferedSink
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.NANOSECONDS
import java.util.concurrent.TimeUnit.SECONDS

class DiscoveryPreviewTransportTest {
    private val source = "https://www.youtube.com/watch?v=SQPreview01"
    private val frames = 1_440_000L

    @Test fun fullLengthPreviewReadsThroughOriginalCallDeadline() = HttpsFixture().use { f ->
        val chunk = 4096
        val payload = ByteArray(31 * chunk) { (it / chunk).toByte() }
        f.server.enqueue(audio().body(object : MockResponseBody {
            override val contentLength = payload.size.toLong()
            override fun writeTo(sink: BufferedSink) {
                // Pace payload, not HTTP framing. Use absolute offsets so scheduler
                // oversleep does not accumulate over all 30 intervals.
                val started = System.nanoTime()
                for (offset in payload.indices step chunk) {
                    val wait = (offset / chunk) * SECONDS.toNanos(1) - (System.nanoTime() - started)
                    if (wait > 0) NANOSECONDS.sleep(wait)
                    sink.write(payload, offset, chunk).flush()
                }
            }
        }).build())
        val input = preview(f)
        val started = System.nanoTime()
        val bytes = ByteArray(256) // The forward-only native reader requests this much at a time.
        val received = Buffer()
        try {
            assertArrayEquals(longArrayOf(payload.size.toLong(), 48_000, frames), input.open())
            val request = checkNotNull(f.server.takeRequest(2, SECONDS))
            assertEquals("POST", request.method)
            assertEquals("/api/v1/discovery/preview", request.target)
            assertEquals("""{"url":"$source"}""", request.body!!.utf8())
            assertEquals("Bearer fixture", request.headers["Authorization"])
            assertEquals("identity", request.headers["Accept-Encoding"])
            val first = input.readEncoded(bytes)
            assertTrue(first > 0)
            received.write(bytes, 0, first)
            assertTrue("must expose a prefix before the tail", System.nanoTime() - started < SECONDS.toNanos(10))
            while (true) {
                val n = input.readEncoded(bytes)
                if (n == -1) break
                received.write(bytes, 0, n)
            }
            assertTrue("fixture must span the original call deadline", System.nanoTime() - started >= SECONDS.toNanos(30))
            assertArrayEquals(payload, received.readByteArray())
            assertEquals(1, f.server.requestCount)
        } finally {
            input.close()
        }
    }

    @Test fun retirementCancelsOwnedBodyWhileTailIsHeld() = HttpsFixture().use { f ->
        val prefixRead = CountDownLatch(1)
        val tailHeld = CountDownLatch(1)
        val releaseTail = CountDownLatch(1)
        val socketCanceled = CountDownLatch(1)
        val client = f.client.newBuilder().eventListener(object : EventListener() {
            override fun canceled(call: Call) { socketCanceled.countDown() }
        }).build()
        f.server.enqueue(audio().body(object : MockResponseBody {
            override val contentLength = 2L
            override fun writeTo(sink: BufferedSink) {
                sink.writeByte(42).flush()
                tailHeld.countDown()
                check(releaseTail.await(10, SECONDS))
                sink.writeByte(43)
            }
        }).build())
        val input = preview(f, client)
        val worker = Executors.newSingleThreadExecutor()
        try {
            val result = worker.submit<SafeFailure.Reason> {
                try {
                    input.open()
                    val bytes = ByteArray(1)
                    assertEquals(1, input.readEncoded(bytes))
                    assertEquals(42, bytes[0].toInt())
                    prefixRead.countDown()
                    assertThrows(SafeFailure::class.java) { input.readEncoded(bytes) }.reason
                } finally {
                    input.close()
                }
            }
            assertTrue(tailHeld.await(3, SECONDS))
            assertTrue(prefixRead.await(3, SECONDS))
            input.cancel()
            assertTrue(socketCanceled.await(2, SECONDS))
            assertEquals(SafeFailure.Reason.Retired, result.get(2, SECONDS))
            assertEquals(SafeFailure.Reason.Retired, assertThrows(SafeFailure::class.java) { input.open() }.reason)
            assertEquals(1, f.server.requestCount)
        } finally {
            input.cancel()
            releaseTail.countDown()
            worker.shutdownNow()
            assertTrue(worker.awaitTermination(3, SECONDS))
        }
    }

    @Test fun rejectsBeyondClipBoundsWithoutConsumingBody() = HttpsFixture().use { f ->
        for (response in listOf(
            audio().body("x").setHeader("X-SoundQ-Preview-Frames", frames + 1).build(),
            audio().body("x").setHeader("Content-Length", 2_097_153).build(),
        )) {
            f.server.enqueue(response)
            val input = preview(f)
            try {
                assertEquals(SafeFailure.Reason.InvalidResponse, assertThrows(SafeFailure::class.java) { input.open() }.reason)
            } finally {
                input.close()
            }
        }
        assertEquals(2, f.server.requestCount)
    }

    private fun preview(f: HttpsFixture, client: OkHttpClient = f.client): DiscoveryPreviewInput {
        val session = AccountSession(f.endpoint, MemoryStore())
        check(session.accept(session.beginIntent(), SecretTokens("fixture", "r-fixture", "account")))
        return SoundQApi(session, client).discoveryPreview(checkNotNull(session.capture()), checkNotNull(ImportSource.parse(source)))
    }

    private fun audio() = MockResponse.Builder().addHeader("Content-Type", "audio/mpeg")
        .addHeader("X-SoundQ-Preview-Sample-Rate", 48_000).addHeader("X-SoundQ-Preview-Frames", frames)
}
