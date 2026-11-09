package com.soundq.designsystem

/** A read-only visual snapshot. No transport, clock or media dependency. */
sealed interface CompactSongSource {
    data class Server(val track:Long):CompactSongSource
    data class Device(val id:String,val sha256:String,val bytes:Long,val incarnation:Long):CompactSongSource
}
data class CompactSongIdentity(val account:Long,val session:String,val queue:String,val incarnation:Long,val occurrence:String,val source:CompactSongSource)
enum class CompactPlaybackState { None,Preparing,Playing,Paused,Ended,Failed }
data class CompactSongTiming(val identity:CompactSongIdentity?=null,val elapsedMs:Long?=null,val totalMs:Long?=null,val state:CompactPlaybackState=CompactPlaybackState.None,val selected:Boolean=identity!=null) {
    val total:Long? get()=totalMs?.takeIf {it>0}
    val elapsed:Long? get()=elapsedMs?.coerceAtLeast(0)?.let {value->total?.let {value.coerceAtMost(it)} ?: value}
    val fraction:Float? get()=elapsed?.let {position->total?.let {(position.toDouble()/it).toFloat().coerceIn(0f,1f)}}
    val clockText:String get()="${formatSongTime(elapsed)} / ${formatSongTime(total)}"
    val clockDescription:String get()="${elapsed?.let {"Elapsed ${formatSongTime(it)}"} ?: "Elapsed unavailable"}, ${total?.let {"Duration ${formatSongTime(it)}"} ?: "Duration unavailable"}"
}
fun formatSongTime(ms:Long?):String {
    if(ms==null)return "—:—"
    val seconds=ms.coerceAtLeast(0)/1000
    val tail=(seconds%60).toString().padStart(2,'0')
    return if(seconds>=3600)"${seconds/3600}:${(seconds/60%60).toString().padStart(2,'0')}:$tail" else "${seconds/60}:$tail"
}
