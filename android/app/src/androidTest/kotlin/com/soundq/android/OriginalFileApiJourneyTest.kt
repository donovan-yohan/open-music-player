package com.soundq.android

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaScannerConnection
import android.os.Build
import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.data.device.FileDeleteOutcome
import com.soundq.android.data.device.OriginalFileStamp
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** ProductFixtureRunner. API26 needs the manifest's existing READ_EXTERNAL_STORAGE grant.
 * The read-only ACTION_VIEW is intercepted: this tests handoff, not another app's navigation.
 * Only a newly generated file under this test app's external-media directory is touched. */
class OriginalFileApiJourneyTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    @Test fun actualPlatformStampCapturesOn26AndRetainsSubsecondFieldsOn27() {
        val original = File(context.cacheDir, "stamp-${UUID.randomUUID()}.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        try {
            val stat = Os.stat(original.path)
            val stamp = OriginalFileStamp.of(stat)
            assertEquals(stat.st_ino, stamp.inode); assertEquals(3L, stamp.bytes)
            if (Build.VERSION.SDK_INT >= 27) assertNanoseconds(stat, stamp) else {
                assertNull(stamp.modifiedNs); assertNull(stamp.changedNs); assertFalse(stamp.deletionSafe)
            }
        } finally { assertTrue(original.delete()) }
    }
    @Test fun actualReadLeaseCapturesAndReadsOnSupportedApiFloor() {
        val bytes=ByteArray(257) {it.toByte()}
        val original=File(context.cacheDir,"lease-${UUID.randomUUID()}.bin").apply {writeBytes(bytes)}
        try {
            android.os.ParcelFileDescriptor.open(original,android.os.ParcelFileDescriptor.MODE_READ_ONLY).use {fd->
                com.soundq.android.playback.nativeengine.OriginalAudioReadLease.borrow(fd.fileDescriptor,0,bytes.size.toLong(),original.path,{true}).use {lease->
                    val actual=ByteArray(bytes.size);lease.beginOperation()
                    assertEquals(bytes.size,lease.readAt(0,actual,0,actual.size));assertArrayEquals(bytes,actual)
                }
            }
        } finally {assertTrue(original.delete())}
    }
    @androidx.annotation.RequiresApi(27)
    private fun assertNanoseconds(stat: android.system.StructStat, stamp: OriginalFileStamp) {
        assertEquals(stat.st_mtim.tv_nsec, requireNotNull(stamp.modifiedNs)); assertEquals(stat.st_ctim.tv_nsec, requireNotNull(stamp.changedNs))
        assertTrue(stamp.deletionSafe)
        assertNotEquals(stamp, stamp.copy(modifiedNs = (stamp.modifiedNs!! + 1) % 1_000_000_000))
    }
    @Test fun originalCaptureAndReadOnlyFolderHandoffWorkAnd26RefusesDeleteBeforeRetirement() = runBlocking {
        val graph = (context.applicationContext as FixtureApplication).graph
        instrumentation.runOnMainSync { graph.session.retire() }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        while (System.nanoTime() < deadline && (graph.session.state.value !is AuthState.SignedOut || !graph.phoneAudio.state.value.ready)) Thread.sleep(20)
        assertTrue("Runner must grant existing legacy read/all-files access", graph.phoneAudio.platform.storageAllowed())
        val directory = checkNotNull(context.externalMediaDirs.firstOrNull()).apply { mkdirs() }
        val file = File(directory, "soundq-api-${UUID.randomUUID()}.wav")
        val frames = 8000
        val bytes = ByteBuffer.allocate(44 + frames * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(36 + frames * 2).put("WAVEfmt ".toByteArray()).putInt(16)
            putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16).put("data".toByteArray()).putInt(frames * 2)
            repeat(frames) { putShort((it % 256).toShort()) }
        }.array()
        val scanned = CountDownLatch(1); var uri: android.net.Uri? = null
        val filter = IntentFilter(Intent.ACTION_VIEW).apply { addDataScheme("content"); addDataType("vnd.android.document/directory") }
        val monitor = instrumentation.addMonitor(filter, Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null), true)
        try {
            file.writeBytes(bytes)
            MediaScannerConnection.scanFile(context, arrayOf(file.path), arrayOf("audio/wav")) { _, found -> uri = found; scanned.countDown() }
            assertTrue("Scanner indexed generated source", scanned.await(20, TimeUnit.SECONDS))
            // Diagnostic admission: only this test's generated original is observed.
            // Keep the failing production proof immediately below, unchanged.
            context.contentResolver.openAssetFileDescriptor(checkNotNull(uri), "r").use { asset ->
                val descriptor = checkNotNull(asset)
                android.os.ParcelFileDescriptor.open(file, android.os.ParcelFileDescriptor.MODE_READ_ONLY).use { direct ->
                    repeat(2) { sample ->
                        android.util.Log.i("SoundQOriginalProof", "sample=$sample provider=" + OriginalFileStamp.of(Os.fstat(descriptor.fileDescriptor)) +
                            " named=" + OriginalFileStamp.of(Os.stat(file.path)) +
                            " direct=" + OriginalFileStamp.of(Os.fstat(direct.fileDescriptor)) +
                            " offset=${descriptor.startOffset} length=${descriptor.declaredLength}")
                    }
                }
            }
            val proof=graph.phoneAudio.platform.proof(checkNotNull(uri).toString()) {true}
            assertEquals(bytes.size.toLong(),proof.bytes)
            assertEquals(java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {"%02x".format(it)},proof.sha256)
            val row = graph.phoneAudio.awaitIndexed(checkNotNull(uri))
            val target = checkNotNull(graph.phoneFiles.capture(graph.phoneAudio.reference(row)) { true })
            assertEquals(file.canonicalPath, target.path); assertNotNull(target.folder)
            assertTrue("Read-only file-manager handoff accepted", graph.phoneFiles.open(target) { true })
            assertEquals(1, monitor.hits)
            if (Build.VERSION.SDK_INT == 26) {
                assertEquals("Delete file needs Android 8.1 or later.", graph.phoneFiles.deleteUnavailableReason)
                var retired = false
                assertEquals(FileDeleteOutcome.Refused, graph.phoneFiles.delete(target, { true }) { retired = true; true })
                assertFalse(retired)
            } else { assertNull(graph.phoneFiles.deleteUnavailableReason); assertTrue(target.stamp.deletionSafe) }
            assertArrayEquals(bytes, file.readBytes())
        } finally {
            instrumentation.removeMonitor(monitor)
            file.delete() // exact generated original; never a provider/catalog-driven cleanup
            uri?.let { runCatching { context.contentResolver.delete(it, null, null) } }
        }
    }
}
