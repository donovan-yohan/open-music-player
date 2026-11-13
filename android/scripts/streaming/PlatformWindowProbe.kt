package com.soundq.android.playback.nativeengine
import java.nio.ByteBuffer
import java.nio.ByteOrder
import android.media.MediaCodec
fun main() {
    val source=OriginalAudioReadLease()
    val reader=AndroidPlatformWindowReader(source)
    check(reader.open()==8000)
    val pcm=ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder())
    check(reader.read(0,2,pcm)==2) { "Initial PCM must return without requesting tail/EOS" }
    check(pcm.getFloat(0)==.25f && pcm.getFloat(4)==.25f && pcm.getFloat(8)==.5f)
    check(reader.endFrames()==0L && !MediaCodec.tailRequested)
    check(reader.read(8000L*10800,2,pcm)==2)
    check(MediaCodec.lastSeekUs==10800000000L && !MediaCodec.tailRequested)
    check(pcm.getFloat(0)==.25f)
    reader.revoke();check(runCatching{reader.read(0,1,pcm)}.isFailure)
    check(reader.closeReader() && source.closed && MediaCodec.releases==1)
    println("PASS first PCM before tail/EOS, direct 3h target, mono sample oracle, revoked read and concrete release (platform facade)")
}
