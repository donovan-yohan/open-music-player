package com.soundq.android.playback.nativeengine
class OriginalAudioReadLease {
    val length=0L
    fun readAt(position:Long,buffer:ByteArray,offset:Int,size:Int):Int=error("No encoded original in this facade")
    var closed=false
    private var revoked=false
    val active get()=!closed && !revoked
    fun checkCurrent(){check(!closed);check(!revoked) {"fixture source revoked"}}
    fun beginOperation(){checkCurrent()}
    fun revoke(){revoked=true}
    fun close(){closed=true}
}
