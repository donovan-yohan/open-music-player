package com.soundq.android.data

import androidx.annotation.Keep
import okhttp3.Call
import okhttp3.Response
import okio.AsyncTimeout
import java.io.InputStream
import java.util.concurrent.TimeUnit

/** Single-use HTTP body, read and closed by the native page worker. Only cancel crosses threads. */
@Keep
internal class DiscoveryPreviewInput(private val createCall: () -> Call, private val refresh: (() -> Boolean)->Boolean, private val current: () -> Boolean) {
    private val ownership = Any()
    private var activeCall: Call? = null
    private var opened = false // worker only
    @Volatile private var retired = false
    @Volatile var failure: SafeFailure.Reason? = null
        private set
    private var response: Response? = null
    private var input: InputStream? = null
    private var remaining = 0

    private fun checkCurrent() {
        if (retired || !current()) throw SafeFailure(SafeFailure.Reason.Retired)
    }
    private inline fun <T> guarded(block: () -> T): T = try {
        checkCurrent()
        block().also { checkCurrent() }
    } catch (e: Exception) {
        val reason = if (retired || !current()) SafeFailure.Reason.Retired
            else (e as? SafeFailure)?.reason ?: SafeFailure.Reason.Network
        failure = reason
        throw SafeFailure(reason)
    }

    private fun execute(): Response {
        checkCurrent()
        val call=createCall()
        // OkHttp's call timer runs until the body closes. Budget for up to 20 s
        // to open, the 30 s demand-driven clip, and 10 s of headroom.
        call.timeout().timeout(60, TimeUnit.SECONDS)
        synchronized(ownership) {
            if(retired)throw SafeFailure(SafeFailure.Reason.Retired)
            check(activeCall==null)
            activeCall=call
        }
        // Keep the original wall-clock deadline to headers, independently of
        // the unchanged socket read timeout and the longer preview call cap.
        val headers = object : AsyncTimeout() {
            override fun timedOut() = call.cancel()
        }.apply { timeout(20, TimeUnit.SECONDS) }
        return headers.withTimeout { call.execute().also { response = it } }
    }

    fun open(): LongArray = guarded {
        check(!opened)
        opened=true
        var reply=execute()
        if(reply.code==401) {
            closeResponse()
            checkCurrent()
            // The shared rotation owns an entered exchange. Retirement denies a
            // not-yet-entered rotation and permanently denies preview reopen.
            if(!refresh { !retired && current() })throw SafeFailure(SafeFailure.Reason.Refused)
            checkCurrent()
            reply=execute()
        }
        when (reply.code) {
            200 -> Unit
            401 -> throw SafeFailure(SafeFailure.Reason.Refused)
            404 -> throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
            in 300..399 -> throw SafeFailure(SafeFailure.Reason.Endpoint)
            429, 503 -> throw SafeFailure(SafeFailure.Reason.ServiceUnavailable)
            else -> throw SafeFailure(SafeFailure.Reason.Network)
        }
        fun number(name: String): Long? = reply.headers.values(name).singleOrNull()
            ?.takeIf { it.isNotEmpty() && it.all { c -> c in '0'..'9' } }?.toLongOrNull()
        val type = reply.body.contentType()
        val length = number("Content-Length") ?: 0
        val rate = number("X-SoundQ-Preview-Sample-Rate") ?: 0
        val frames = number("X-SoundQ-Preview-Frames") ?: 0
        val encodings = reply.headers.values("Content-Encoding")
        if (type?.type != "audio" || type.subtype != "mpeg" || reply.headers.values("Content-Type").size != 1 ||
            length !in 1L..2_097_152L || reply.body.contentLength() != length ||
            (rate != 44_100L && rate != 48_000L) || frames !in 1L..(30 * rate) ||
            (encodings.isNotEmpty() && !encodings.singleOrNull().equals("identity", ignoreCase = true)) ||
            reply.header("Transfer-Encoding") != null || reply.header("Content-Range") != null
        ) throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        input = reply.body.byteStream()
        remaining = length.toInt()
        longArrayOf(length, rate, frames)
    }

    fun readEncoded(bytes: ByteArray): Int = guarded {
        val stream = checkNotNull(input)
        if (remaining == 0) {
            if (stream.read() != -1) throw SafeFailure(SafeFailure.Reason.InvalidResponse)
            -1
        } else {
            val count = stream.read(bytes, 0, minOf(remaining, bytes.size))
            if (count <= 0) throw SafeFailure(SafeFailure.Reason.InvalidResponse)
            remaining -= count
            count
        }
    }

    val canceled get() = retired
    fun cancel() {
        val call=synchronized(ownership) { retired=true;activeCall }
        call?.cancel()
    }

    fun close() { closeResponse() }

    private fun closeResponse() {
        val retiring = response
        response = null
        input = null
        try {retiring?.close()} finally {synchronized(ownership) {activeCall=null}}
    }
}
