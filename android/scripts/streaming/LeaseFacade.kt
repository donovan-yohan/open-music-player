package com.soundq.android.playback.nativeengine
internal class OriginalAudioReadLease(private val onBegin: () -> Unit = {}):OriginalMetadataReader {
    override fun <T> metadataScan(scan:(OriginalMetadataBatch)->T):T=error("No MP3 metadata in this facade")
    val length=0L
    fun readAt(position:Long,buffer:ByteArray,offset:Int,size:Int):Int=error("No encoded original in this facade")
    var closed=false
    private var revoked=false
    val active get()=!closed && !revoked
    fun checkCurrent(){check(!closed);check(!revoked) {"fixture source revoked"}}
    fun beginOperation(){checkCurrent();onBegin()}
    fun revoke(){revoked=true}
    fun close(){closed=true}
}
