package com.soundq.android.playback.nativeengine
import java.nio.ByteBuffer
interface NativePcmReader {fun open():Int;fun read(first:Long,count:Int,destination:ByteBuffer):Int;fun endFrames():Long;fun longFormConfirmed():Boolean;fun revoke();fun closeReader():Boolean}
class OriginalAudioReadLease {
    val length=1L
    var checks=0;var valid=true;var retired=false;var closed=false
    val active get()=!retired && !closed
    fun checkCurrent(){checks++;check(valid && active) {"original changed or retired"}}
    fun beginOperation(){checkCurrent()}
    fun readAt(p:Long,b:ByteArray,o:Int,n:Int):Int=error("No encoded reads in raw-codec fence fixture")
    fun revoke(){retired=true}
    fun close(){closed=true;retired=true}
}
