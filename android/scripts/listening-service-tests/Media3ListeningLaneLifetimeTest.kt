package com.soundq.android.playback.listening

import android.content.Context
import android.net.Uri
import androidx.media3.datasource.DataSource
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/** Real lane + Media3 loader/extractor lifetime, stopped before a codec can be needed.
 * The held IO facade is NOT decoder/output acceptance. Actual decode is androidTest only.
 */
@RunWith(RobolectricTestRunner::class)
@LooperMode(LooperMode.Mode.PAUSED)
@Config(manifest = Config.NONE, sdk = [28], application = android.app.Application::class)
class Media3ListeningLaneLifetimeTest {
    @Test fun heldReadKeepsCustodyUntilActualLoaderAndExtractorRelease() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val closed = AtomicBoolean(false); val valid = AtomicBoolean(true)
        val source = object : DataSource {
            override fun addTransferListener(listener: androidx.media3.datasource.TransferListener) = Unit
            override fun open(spec: androidx.media3.datasource.DataSpec): Long = C_LENGTH
            override fun getUri(): Uri = Uri.parse("soundqfixture:///held.mp3")
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                entered.countDown()
                // Loader interrupts cancellation. Keep the explicit underlying-read custody gate held.
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
                while (release.count != 0L) {
                    check(System.nanoTime() < deadline) { "Held source release deadline" }
                    try { release.await(20, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { }
                }
                throw IOException("Controlled held-source retirement")
            }
            override fun close() { closed.set(true) }
        }
        val lane = Media3ListeningLane(RuntimeEnvironment.getApplication(),
            Uri.parse("soundqfixture:///held.mp3"), DataSource.Factory { source }, valid::get, 8)
        try {
            val read = lane.next(1)
            val reached = entered.await(10, TimeUnit.SECONDS)
            if (!reached && read.isDone) read.get(1, TimeUnit.SECONDS) // Surface actual preparation failure.
            assertTrue("Actual progressive loader entered read", reached)
            assertThrows(IllegalStateException::class.java) { lane.next(1) }
            valid.set(false)
            val drain = lane.retireAndDrain()
            assertSame(drain, lane.retireAndDrain())
            assertFalse(drain.isDone); assertFalse(closed.get())
            assertThrows(IllegalStateException::class.java) { lane.next(1) }
            release.countDown()
            assertThrows(java.util.concurrent.ExecutionException::class.java) { read.get(10, TimeUnit.SECONDS) }
            val d = drain.get(15, TimeUnit.SECONDS)
            assertEquals(1, d.extractorReleases)
            assertEquals(0, d.openSources); assertEquals(0, d.readsInFlight); assertTrue(closed.get())
            valid.set(true)
            assertThrows(IllegalStateException::class.java) { lane.next(1) }
        } finally {
            release.countDown(); lane.retireAndDrain().get(15, TimeUnit.SECONDS)
        }
    }
    companion object { private const val C_LENGTH = 73394L }
}
