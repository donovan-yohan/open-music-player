package com.soundq.android

import androidx.test.platform.app.InstrumentationRegistry
import mockwebserver3.MockResponse
import mockwebserver3.MockResponseBody
import okio.BufferedSink
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Reuses the packaged generated 3s/44.1k stereo fixture. The wire profile starts at Info. */
internal fun previewFixtureBytes(): ByteArray = InstrumentationRegistry.getInstrumentation().context.assets
    .open("listening-mp3/stereo.mp3").use { stream ->
        val asset = stream.readBytes()
        check(asset.copyOfRange(0,3).decodeToString() == "ID3" && asset.size == 73_394)
        asset.copyOfRange(44,asset.size)
    }

internal fun previewFixtureResponse(bytes: ByteArray, held: HeldPreviewTail? = null): MockResponse =
    MockResponse.Builder().addHeader("Content-Type","audio/mpeg").addHeader("Content-Encoding","identity")
        .addHeader("X-SoundQ-Preview-Sample-Rate",44_100).addHeader("X-SoundQ-Preview-Frames",132_300)
        .body(object : MockResponseBody {
            override val contentLength = bytes.size.toLong()
            override fun writeTo(sink: BufferedSink) {
                if (held == null) { sink.write(bytes); return }
                sink.write(bytes,0,held.prefixBytes).flush()
                held.prefixSent.countDown()
                check(held.release.await(15,TimeUnit.SECONDS))
                sink.write(bytes,held.prefixBytes,bytes.size-held.prefixBytes).flush()
                held.tailSent.countDown()
            }
        }).build()

internal class HeldPreviewTail(val prefixBytes: Int = 8192) {
    val prefixSent = CountDownLatch(1)
    val release = CountDownLatch(1)
    val tailSent = CountDownLatch(1)
}
