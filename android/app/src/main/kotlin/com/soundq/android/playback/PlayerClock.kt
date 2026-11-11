package com.soundq.android.playback

import kotlinx.serialization.Serializable

/** View choice only. It never changes the transport's selection or play intent. */
enum class PlayerClockMode { Song, Queue }
internal const val CLOCK_SEEK="soundq.clock.seek.v1"
@Serializable data class ClockOwner(val service:String,val account:Long,val queue:String,val revision:Long,val selected:String)
@Serializable data class ClockSpan(val occurrence:String,val durationMs:Long?)
/** The complete service-accepted finite traversal. Null is not a loaded-page total. */
@Serializable data class PlaybackClockAuthority(val owner:ClockOwner,val spans:List<ClockSpan>?)
@Serializable data class ClockDestination(val occurrence:String,val positionMs:Long)
@Serializable data class ClockSeek(val authority:PlaybackClockAuthority,val mode:PlayerClockMode,val positionMs:Long,val destination:ClockDestination)

/** Immutable presentation and inverse map. A null clock is deliberately not zero. */
class PlayerClock internal constructor(
    val elapsedMs:Long?,val totalMs:Long?,val authority:PlaybackClockAuthority?,
    private val inverse:(Long)->ClockDestination?={null},
) {
    val fraction:Float? get()=totalMs?.takeIf {it>0}?.let {total->elapsedMs?.let {(it.toDouble()/total).coerceIn(0.0,1.0).toFloat()}}
    fun destination(positionMs:Long):ClockDestination?=totalMs?.takeIf {it>0&&positionMs in 0..it}?.let {inverse(positionMs)}
}

fun projectPlayerClock(p:PlaybackProjection,mode:PlayerClockMode):PlayerClock {
    fun missing()=PlayerClock(null,null,null)
    if(p.connection!=PlaybackProjection.Connection.Connected||p.selectedOccurrence==null||p.source!=PlaybackSource.Queue)return missing()
    // Arrangement/tempo/overlap clocks are separate owners. This ordinary queue
    // projection cannot manufacture a single-source clock from their artwork or clips.
    val authority=p.clockAuthority?.takeIf {it.owner.service==p.arrangementService&&it.owner.account==p.accountEpoch&&
        it.owner.queue==p.sourceQueueIncarnation&&it.owner.selected==p.selectedOccurrence}
    if(mode==PlayerClockMode.Song) {
        val total=p.durationMs.takeIf {it>0}
        return PlayerClock(p.positionMs.coerceAtLeast(0).let {if(total==null)it else minOf(it,total)},total,authority) {target->authority?.let {ClockDestination(it.owner.selected,target)}}
    }
    val spans=authority?.spans ?: return missing()
    if(spans.isEmpty()||spans.map {it.occurrence}.distinct().size!=spans.size)return missing()
    val index=spans.indexOfFirst {it.occurrence==p.selectedOccurrence}.takeIf {it>=0} ?: return missing()
    fun sum(rows:List<ClockSpan>):Long? {
        var value=0L
        for(row in rows){val duration=row.durationMs?.takeIf {it>0} ?: return null;if(duration>Long.MAX_VALUE-value)return null;value+=duration}
        return value
    }
    val prefix=sum(spans.take(index))
    val local=p.positionMs.coerceAtLeast(0).let {cursor->spans[index].durationMs?.takeIf {it>0}?.let {minOf(cursor,it)} ?: cursor}
    val elapsed=prefix?.let {start->if(local>Long.MAX_VALUE-start)null else start+local}
    val total=sum(spans)
    return PlayerClock(elapsed?.let {if(total==null)it else minOf(it,total)},total,authority) {target->
        if(total==null)null else {
            var offset=0L
            val span=spans.firstOrNull {row->val end=offset+requireNotNull(row.durationMs);if(target<end)true else {offset=end;false}}
            if(span!=null)ClockDestination(span.occurrence,target-offset)
            else ClockDestination(spans.last().occurrence,requireNotNull(spans.last().durationMs))
        }
    }
}
