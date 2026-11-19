package com.soundq.android.playback.nativeengine

import android.media.MediaCodec
import android.media.OnsetCodecFixture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Fresh JVM/reader per mode. Real JNI, Host, WorkerDeck and Engine; no device. */
fun main(args: Array<String>) {
    val startMs = when (args.single()) {
        "deep" -> 10_800_123L
        "zero" -> 0L
        else -> error("Expected deep or zero")
    }
    val codec = OnsetCodecFixture().also { MediaCodec.onset = it }
    val finalPageEntered = CountDownLatch(1)
    val releasePage = CountDownLatch(1)
    var operations = 0
    val caller = Thread.currentThread()
    val lease = OriginalAudioReadLease {
        check(Thread.currentThread() !== caller)
        codec.events.add("operation:${++operations}")
        // Reader open + eligibility witness, then four native page operations.
        if (operations == 6) {
            finalPageEntered.countDown()
            check(releasePage.await(5, TimeUnit.SECONDS)) { "Fixture did not release final page" }
        }
    }
    val reader = AndroidPlatformWindowReader(lease)
    val bridge = NativeCallbackBridge
    val handle = bridge.open()
    check(handle > 0)
    fun deck(): String = bridge.state(handle).substringAfter("\"decks\":[").substringBefore('}')
    fun value(snapshot: String, key: String): String = snapshot.substringAfter("\"$key\":", "").substringBefore(',')
    fun awaitReady(frame: Long): String {
        val deadline = System.nanoTime() + 15_000_000_000L
        do {
            check(CrossfadeDriver.render(1).all { it == 0f })
            val d = deck()
            check(value(d, "error") == "0") { d }
            if (value(d, "ready") == "true" && value(d, "sourceFrame").toLong() == frame) return d
            Thread.sleep(1)
        } while (System.nanoTime() < deadline)
        error("Worker/assign/seek did not become ready: ${deck()}, ${codec.events}")
    }
    fun checkOwner(d: String) {
        check(value(d, "identity") == "7" && value(d, "generation") == "1") { d }
        check(value(d, "sourceRate") == "48000" && value(d, "openDecoders") == "1") { d }
        check(value(d, "missingPcmFrames") == "0" && value(d, "naturalEndCount") == "0") { d }
    }
    fun renderFirst(frame: Long, traversal: String): Int {
        check(bridge.control(handle, 1, 0, 0.0, 0))
        val pcm = CrossfadeDriver.render(256)
        check(pcm.size == 512)
        for (i in 0 until 256) {
            val expected = ((frame + i) % 251 + 4096).toFloat() / 32768f
            check(pcm[2 * i] == expected && pcm[2 * i + 1] == expected) {
                "Bad PCM at $frame + $i: ${pcm[2 * i]}/${pcm[2 * i + 1]} != $expected"
            }
        }
        val d = deck()
        checkOwner(d)
        check(value(d, "playing") == "true" && value(d, "traversalRevision") == traversal) { d }
        check(value(d, "sourceFrame").toLong() == frame + 256) { d }
        return pcm.contentHashCode()
    }

    try {
        check(bridge.loadReader(handle, 0, reader, 7, 1, startMs, 1.0))
        check(finalPageEntered.await(5, TimeUnit.SECONDS)) { "Worker did not reach fourth page: ${deck()}, ${codec.events}" }
        check(CrossfadeDriver.render(1).all { it == 0f })
        val priming = deck()
        check(value(priming, "ready") == "false" && value(priming, "preparing") == "true") { priming }
        check(value(priming, "traversalRevision") == "0" && value(priming, "playing") == "false") { priming }
        releasePage.countDown()
        val frame = startMs * 48
        val ready = awaitReady(frame)
        checkOwner(ready)
        check(value(ready, "preparing") == "false" && value(ready, "sourceFrames") == "0") { ready }
        val traversal = value(ready, "traversalRevision")
        check(traversal.toLong() > 0 && reader.longFormConfirmed())
        val digest = renderFirst(frame, traversal)
        val startup = codec.events.toList()
        val seeks = startup.filter { it.startsWith("seek:") }
        val seekUs = 10_799_000_000L // Actual bookmarked page, minus one-second preroll.
        check(seeks == listOf("seek:599000979", "seek:0") + if (startMs != 0L) listOf("seek:$seekUs") else emptyList()) { seeks }
        check(startup.filter { it.startsWith("operation:") }.size == 6) { startup }
        val firstPageStart = startup.indexOf("operation:3")
        val firstPcm = (firstPageStart until startup.size).first { startup[it].startsWith("pcm:") }
        check(firstPageStart > 0 && firstPcm > firstPageStart) { startup }
        val resetTrace = startup.subList(startup.indexOf("seek:0"), firstPcm + 1)
        val targetFrame = if (startMs == 0L) 0L else 10_799L * 48000
        // Verify the same decode volume: origin + 5 witness chunks + four
        // full page reads, with four additional chunks of deep-seek preroll.
        val chunks = startup.count { it.startsWith("pcm:") }
        check(chunks == if (startMs == 0L) 22 else 26) { startup }
        println("onset ${args.single()} identity=7 generation=1 traversal=$traversal frame=$frame pcmHash=$digest chunks=$chunks reset=$resetTrace")

        if (startMs != 0L) {
            val backwardMs = 3_600_123L
            check(bridge.control(handle, 2, 0, 0.0, 0))
            check(bridge.control(handle, 3, 0, backwardMs.toDouble(), 0))
            val sought = awaitReady(backwardMs * 48)
            checkOwner(sought)
            val nextTraversal = value(sought, "traversalRevision")
            check(nextTraversal.toLong() > traversal.toLong())
            val seekDigest = renderFirst(backwardMs * 48, nextTraversal)
            val laterResets = codec.events.toList().drop(startup.size).filter { it.startsWith("flush:") || it.startsWith("seek:") }
            check(laterResets == listOf("seek:3599000000", "flush:3599000000")) { laterResets }
            println("backward identity=7 generation=1 traversal=$nextTraversal pcmHash=$seekDigest reset=$laterResets")
        }
        val expected = if (startMs == 0L) listOf("seek:0", "operation:3", "flush:0", "pcm:0")
            else listOf("seek:0", "operation:3", "seek:$seekUs", "flush:$seekUs", "pcm:$targetFrame")
        // Zero's existing eager reset is correct too, provided the one flush
        // is before PCM. Deep's redundant reset must fail on the predecessor.
        val eagerZero = listOf("seek:0", "flush:0", "operation:3", "pcm:0")
        check(resetTrace == expected || startMs == 0L && resetTrace == eagerZero) {
            "Redundant startup codec flush before first native published/consumed PCM: $resetTrace; expected $expected"
        }
        val startupFlushes = startup.filter { it.startsWith("flush:") }
        check(startupFlushes == listOf("flush:599000979", "flush:${if (startMs == 0L) 0L else seekUs}")) {
            "Unexpected codec flushes through first callback consumption: $startupFlushes"
        }
    } finally {
        releasePage.countDown()
        check(bridge.close(handle))
        check(lease.closed && MediaCodec.releases == 1)
        println("concrete close: one codec released and borrowed lease closed")
    }
}
