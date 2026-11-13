package com.soundq.android.playback.nativeengine
import android.media.MediaCodec
import java.nio.ByteBuffer
import java.nio.ByteOrder
fun main() {
    fun reader():Pair<OriginalAudioReadLease,AndroidPlatformWindowReader> {
        MediaCodec.first=0;MediaCodec.onBuffer={};MediaCodec.chunk=96
        val source=OriginalAudioReadLease();val peer=AndroidPlatformWindowReader(source)
        check(peer.open()==8000);source.checks=0;return source to peer
    }
    val (source,peer)=reader();val pcm=ByteBuffer.allocateDirect(48000*8).order(ByteOrder.nativeOrder())
    check(peer.read(0,48000,pcm)==48000)
    repeat(48000*2){check(pcm.getFloat(it*4)==.25f)}
    println("ordinary raw-codec chunk=96 window=48000 fullOriginalChecks=${source.checks}")
    check(source.checks<=4) {"Full original validation must be bounded by operation/IO/publication, not every codec output chunk: ${source.checks}"}
    check(peer.closeReader() && source.closed)
    for(revoke in listOf(false,true)) {
        val (lease,reader)=reader();var output=0
        MediaCodec.onBuffer={if(++output==10) {if(revoke)lease.revoke()else lease.valid=false}}
        val failure=runCatching {reader.read(0,48000,pcm)}.exceptionOrNull()
        check(failure!=null) {"No changed/retired speculative PCM may be returned to native publication"}
        check(reader.endFrames()==0L);check(reader.closeReader())
        println("refused during-output revoke=$revoke failure=$failure checks=${lease.checks}")
    }
    val (invalid,reader)=reader();invalid.valid=false
    check(runCatching {reader.read(0,1,pcm)}.isFailure)
    check(reader.endFrames()==0L);check(reader.closeReader())
    println("PASS bounded full validations, exact samples, entry/version/revocation/publication fences and concrete close")
}
