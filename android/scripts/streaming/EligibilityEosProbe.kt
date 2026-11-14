package com.soundq.android.playback.nativeengine

import android.media.MediaCodec
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Declared Android codec facade, not a real Android codec/sample acceptance. */
fun main(args:Array<String>) {
    val mode=args.single()
    MediaCodec.scenario=mode
    val source=OriginalAudioReadLease()
    val reader=AndroidPlatformWindowReader(source)
    if(mode.startsWith("failure-")) {
        val failure=runCatching {reader.open()}.exceptionOrNull()
        check(failure!=null) {"Witness failure must propagate, not become short-source admission"}
        val expected=when(mode) {
            "failure-read" -> "fixture source read budget exceeded"
            "failure-cancel" -> "fixture source revoked"
            "failure-decoded-budget" -> "Platform decoded-window budget exceeded"
            else -> error(mode)
        }
        check(failure.message==expected) {"Expected $expected, got $failure"}
        check(reader.endFrames()==0L && !reader.longFormConfirmed())
        check(source.closed && MediaCodec.releases==1)
        println("PASS $mode: exact original failure propagated; no endpoint/eligibility; owned close")
        return
    }
    try {
        check(reader.open()==8000) {"Valid short source must open after no-output witness EOS"}
        check(!reader.longFormConfirmed())
        check(reader.endFrames()==0L) {"Out-of-range eligibility EOS must not invent an endpoint"}
        val pcm=ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder())
        check(reader.read(0,2,pcm)==2)
        check(pcm.getFloat(0)==.25f && pcm.getFloat(4)==.25f && pcm.getFloat(8)==.5f && pcm.getFloat(12)==.5f)
        if(mode=="short-unmapped-seek") {
            val failure=runCatching {reader.read(8000L*1000,1,pcm)}.exceptionOrNull()
            check(failure?.message=="EOS after an unmapped seek is not an exact source endpoint") {"Arbitrary seek must still refuse unmapped EOS: $failure"}
            check(reader.endFrames()==0L)
            check(reader.read(0,2,pcm)==2) // refused seek cannot poison ordinary playback
        }
        check(reader.read(2,1,pcm)==0)
        check(reader.endFrames()==2L) {"Only mapped decoded EOS may establish exact end"}
        check(reader.read(100,1,pcm)==0 && reader.endFrames()==2L)
        check(!reader.longFormConfirmed())
        println("PASS $mode: witness-only empty EOS, exact sample recovery, qualified end=2, no eligibility")
    } finally {
        check(reader.closeReader() && source.closed && MediaCodec.releases==1)
    }
}
