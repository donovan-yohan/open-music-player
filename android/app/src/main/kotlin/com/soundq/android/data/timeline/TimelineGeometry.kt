package com.soundq.android.data.timeline

import kotlin.math.*
data class TimelineViewport(val durationMs:Long,val widthPx:Float,val pixelsPerSecond:Double=10.0,val offsetMs:Long=0) {
    val visibleMs:Long get()=(widthPx/pixelsPerSecond*1000).roundToLong()
    fun x(ms:Long):Float=((ms-offsetMs)*pixelsPerSecond/1000).toFloat()
    fun time(x:Float):Long=offsetMs+(x/pixelsPerSecond*1000).roundToLong()
    fun pan(deltaPx:Float):TimelineViewport=copy(offsetMs=(offsetMs+(deltaPx/pixelsPerSecond*1000).roundToLong()).coerceIn(0,maxOf(0,durationMs-visibleMs)))
    fun zoom(factor:Float,focalPx:Float):TimelineViewport {
        require(factor.isFinite()&&factor>0&&focalPx.isFinite())
        val scale=(pixelsPerSecond*factor).coerceIn(1.0,2400.0)
        val next=copy(pixelsPerSecond=scale,offsetMs=time(focalPx)-(focalPx/scale*1000).roundToLong())
        return next.copy(offsetMs=next.offsetMs.coerceIn(0,maxOf(0,durationMs-next.visibleMs)))
    }
}
fun snapEditValue(clip:TimelineClip,kind:EditKind,value:Long,mode:SnapMode,wave:TrackWaveform?):Long {
    if(mode==SnapMode.Free||wave==null)return value
    val markers=if(mode==SnapMode.Bar)wave.downbeats else wave.beats
    if(markers.isEmpty())return value
    if(kind!=EditKind.Placement)return markers.minBy {abs(it-value)}
    // Align the selected source's first actual marker to the nearest global projected marker.
    val anchor=markers.firstOrNull {it>=clip.sourceInMs&&it<clip.sourceOutMs} ?: return value
    val relative=clip.globalAt(anchor)-clip.globalStartMs
    val globalMarkers=markers.map(clip::globalAt)
    return globalMarkers.minBy {abs(it-(value+relative))}-relative
}
fun TimelineDocument.matchesOccurrences(occurrences:List<Pair<String,Long>>):Boolean=clips.map {it.occurrence to it.track}==occurrences
data class PhaseTick(val sourceMs:Long,val globalMs:Long,val group:Int,val downbeat:Boolean=false)
/** Preparation only. Called on viewport/source changes, never from draw. */
fun phaseTicks(clip:TimelineClip,viewport:TimelineViewport,grid:PhaseGrid?,wave:TrackWaveform?):List<PhaseTick> {
    val first=clip.sourceAt(maxOf(clip.globalStartMs,viewport.offsetMs)).coerceIn(clip.sourceInMs,clip.sourceOutMs)
    val last=clip.sourceAt(minOf(clip.globalEndMs,viewport.offsetMs+viewport.visibleMs)).coerceIn(clip.sourceInMs,clip.sourceOutMs)
    if(last<first)return emptyList()
    val sources=if(grid==null)wave?.beats.orEmpty().filter {it in first..last} else {
        val start=grid.anchorMs+Math.floorDiv(first-grid.anchorMs+grid.periodMs-1,grid.periodMs)*grid.periodMs
        if(last<start)emptyList() else (0..(last-start)/grid.periodMs).map {start+it*grid.periodMs}
    }
    val beats=sources.map {source ->
        val ordinal=grid?.ordinal(source)
        val group=when {ordinal==null->1;ordinal%32==0L->32;ordinal%16==0L->16;ordinal%4==0L->4;else->1}
        PhaseTick(source,clip.globalAt(source),group)
    }
    return beats+wave?.downbeats.orEmpty().filter {it in first..last}.map {PhaseTick(it,clip.globalAt(it),1,true)}
}
/** Immutable compiler seam. Native-mix binding must ACK revision before claiming audibility. */
data class RenderedClip(val occurrence:String,val track:Long,val sourceInMs:Long,val sourceOutMs:Long,val globalStartMs:Long,val globalEndMs:Long,val rates:RateAutomation,val fadeInMs:Long=0,val fadeOutMs:Long=0,val tempoMap:ClipTempoMap?=null)
data class RenderedSchedule(val revision:Long,val clips:List<RenderedClip>)
/** Durable law lookup for JNI V2. Absent occurrence means eight exact zero payload fields. */
fun tempoMapsByOccurrence(document:TimelineDocument):Map<String,ClipTempoMap> = projectTempoDocument(document).clips.mapNotNull {c->c.tempoMap?.let {c.occurrence to it}}.toMap()
/** V2 compatibility only. Not a native readiness, prepared-output or audible ACK. */
fun validateNativeTempoPlan(document:TimelineDocument):String? {
    val projected=try {projectTempoDocument(document)}catch(e:Exception){return e.message ?: "Tempo fit is invalid."}
    val shape=validateTimeline(projected.clips) ?: validatePhase(projected)
    if(shape!=null)return shape
    for(c in projected.clips) {
        val map=c.tempoMap ?: continue
        if(map.intent.gainLaw!=TempoGainLaw.EqualPower)return "Native tempo preview supports Equal power gain only. Choose it explicitly; Linear intent was not changed."
        if(c.rates.segments.isNotEmpty())return "Native tempo V2 cannot preserve prior rate automation. Saved intent was not changed."
        val expected=map.law.startBpm/map.sourceBpm
        // Incoming begins at the ramp. Outgoing must match V2's held-start prefix exactly.
        if(c.globalStartMs<map.intent.overlapStartMs&&kotlin.math.abs(c.rates.baseRate-expected)>1e-9)return "Native tempo prefix differs from the captured source map."
    }
    return null
}
fun compileSchedule(document:TimelineDocument):RenderedSchedule {
    val projected=projectTempoDocument(document)
    require(validateTimeline(projected.clips)==null && validatePhase(projected)==null)
    return RenderedSchedule(projected.revision,projected.clips.map {RenderedClip(it.occurrence,it.track,it.sourceInMs,it.sourceOutMs,it.globalStartMs,it.globalEndMs,it.rates,it.fadeInMs,it.fadeOutMs,it.tempoMap)})
}
