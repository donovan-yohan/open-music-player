package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.datasource.DataSource
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/** Real lane/extractor/loader custody only. No codec, Android output or JNI in this JVM. */
@RunWith(RobolectricTestRunner::class)
@LooperMode(LooperMode.Mode.PAUSED)
@Config(manifest = Config.NONE, sdk = [28], application = android.app.Application::class)
class SequentialPcmCursorLaneTest {
    @Test fun cursorTimeoutKeepsBorrowedSourceUntilConcreteLaneActuallyDrains() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closed = AtomicBoolean(false)
        val source = object : DataSource {
            override fun addTransferListener(listener: androidx.media3.datasource.TransferListener) = Unit
            override fun open(spec: androidx.media3.datasource.DataSpec): Long = 73394
            override fun getUri(): Uri = Uri.parse("soundqfixture:///cursor-held.mp3")
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                entered.countDown()
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
                while (release.count != 0L) {
                    check(System.nanoTime() < deadline) { "Held source release deadline" }
                    try { release.await(20, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { }
                }
                throw IOException("Controlled source retirement")
            }
            override fun close() { closed.set(true) }
        }
        val lane = Media3ListeningLane(RuntimeEnvironment.getApplication(),
            Uri.parse("soundqfixture:///cursor-held.mp3"), DataSource.Factory { source }, { true }, 2048)
        val cursor = SequentialPcmCursor(lane, 10000, 250)
        val pool = Executors.newSingleThreadExecutor()
        try {
            val read = pool.submit<FloatArray> { cursor.read(0, 1) }
            assertTrue("Real progressive loader entered source read", entered.await(10, TimeUnit.SECONDS))
            assertThrows(TimeoutException::class.java) { cursor.close() }
            assertFalse(cursor.retiredSuccessfully)
            assertFalse(cursor.completeExtent)
            assertFalse(closed.get())
            assertThrows(IllegalStateException::class.java) { cursor.read(0, 1) }
            val retained = lane.retireAndDrain()
            assertSame(retained, lane.retireAndDrain())
            assertFalse(retained.isDone)
            release.countDown()
            val receipt = retained.get(15, TimeUnit.SECONDS)
            assertEquals(1, receipt.extractorReleases)
            assertEquals(0, receipt.openSources)
            assertEquals(0, receipt.readsInFlight)
            assertTrue(closed.get())
            assertThrows(java.util.concurrent.ExecutionException::class.java) { read.get(2, TimeUnit.SECONDS) }
            cursor.close()
            assertTrue(cursor.retiredSuccessfully)
            assertFalse(cursor.completeExtent)
            assertThrows(IllegalStateException::class.java) { cursor.read(0, 1) }
        } finally {
            release.countDown()
            lane.retireAndDrain().get(15, TimeUnit.SECONDS)
            pool.shutdownNow()
            assertTrue(pool.awaitTermination(2, TimeUnit.SECONDS))
        }
    }
}
