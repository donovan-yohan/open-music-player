package com.soundq.android.product.timeline

import androidx.compose.ui.graphics.Color
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import kotlinx.serialization.json.*
import soundq.design.generated.SoundQSpectralTokens as S
import java.io.File
import java.util.zip.GZIPInputStream
import kotlin.math.*

/** Retains the original production projection as a compatibility oracle. */
private fun originalProjection(peaks:PeakWindow?,clip:TimelineClip,v:TimelineViewport):SpectralWaveformPaint {
    val coverage=peaks?.coverage ?: return SpectralWaveformPaint(emptyList())
    val count=peaks.minima.size
    if(count==0||count>8192||peaks.maxima.size!=count||coverage.sourceBinCount<=0||coverage.endBin<=coverage.firstBin)return SpectralWaveformPaint(emptyList())
    val visibleStart=maxOf(clip.globalStartMs,v.offsetMs)
    val visibleEnd=minOf(clip.globalEndMs,v.offsetMs+v.visibleMs)
    if(visibleEnd<=visibleStart)return SpectralWaveformPaint(emptyList())
    val sourceStart=maxOf(clip.sourceInMs,peaks.sourceStartMs,clip.sourceAt(visibleStart))
    val sourceEnd=minOf(clip.sourceOutMs,peaks.sourceEndMs,clip.sourceAt(visibleEnd))
    val bands=peaks.spectral?.takeIf {it.low.size==count&&it.mid.size==count&&it.high.size==count}
    val span=coverage.endBin-coverage.firstBin
    val columns=ArrayList<SpectralPaintColumn>(count)
    for(i in 0 until count) {
        val a=coverage.firstBin+i*span/count
        val b=coverage.firstBin+ceil((i+1).toDouble()*span/count).toInt()
        val start=maxOf(sourceStart,floor(a.toDouble()*coverage.sourceDurationMs/coverage.sourceBinCount).toLong())
        val end=minOf(sourceEnd,ceil(b.toDouble()*coverage.sourceDurationMs/coverage.sourceBinCount).toLong())
        if(end<=start)continue
        val left=maxOf(0f,v.x(visibleStart),floor(v.x(clip.globalAt(start))))
        val right=minOf(v.widthPx,v.x(visibleEnd),ceil(v.x(clip.globalAt(end))))
        if(right<=left)continue
        val color=if(bands==null)S.W10_SPECTRUM_UNAVAILABLE else spectralSampleColor(bands.low[i],bands.mid[i],bands.high[i])
        columns+=SpectralPaintColumn(left,right,peaks.minima[i],peaks.maxima[i],color)
    }
    return SpectralWaveformPaint(columns)
}
private class CountedList<T>(private val values:List<T>):AbstractList<T>() {
    var reads=0L
    var sizeReads=0L
    override val size:Int get(){sizeReads++;return values.size}
    override fun get(index:Int):T {reads++;return values[index]}
}
private fun window(w:TrackWaveform,c:TimelineClip,v:TimelineViewport,cache:WaveformCache=WaveformCache()):PeakWindow? {
    val start=c.sourceAt(maxOf(c.globalStartMs,v.offsetMs)).coerceIn(c.sourceInMs,c.sourceOutMs)
    val end=c.sourceAt(minOf(c.globalEndMs,v.offsetMs+v.visibleMs)).coerceIn(c.sourceInMs,c.sourceOutMs)
    return if(end>start)cache.window(w,start,end,spectralWindowColumns(c,v)) else null
}
private fun compatibility(w:TrackWaveform) {
    var cases=0
    val rates=listOf(RateAutomation(),RateAutomation(.25),RateAutomation(4.0),RateAutomation(1.125),
        RateAutomation(1.0,listOf(RateSegment(1700,83001,.25,4.0),RateSegment(40000,160000,3.9,.3),RateSegment(80101,90103,1.2,2.3))),
        RateAutomation(.375,listOf(RateSegment(20,40000,4.0,.25),RateSegment(40000,160000,.25,4.0))))
    for(rate in rates)for(offset in listOf(0L,13007L,87013L,170000L,900000L))for(scale in listOf(2.0,33.25,2400.0)) {
        val c=TimelineClip("real",7,"six-minute producer",360000,1317,351113,1700,QueueSegment.Manual,rate)
        val v=TimelineViewport(1500000,360f,scale,offset)
        val p=window(w,c,v)
        val expected=originalProjection(p,c,v)
        val actual=projectSpectralWaveform(p,c,v)
        check(expected==actual) {"projection mismatch rate=$rate offset=$offset scale=$scale expected=${expected.columns.take(3)} actual=${actual.columns.take(3)}"}
        cases++
    }
    // Deterministic interval-precedence/rounding coverage, including unsorted overlap
    // and the admitted 256-segment cap. Small real tier keeps this a focused oracle.
    val random=java.util.Random(731)
    val tiny=w.copy(tiers=listOf(w.tiers.first()))
    for(n in listOf(1,32,256))repeat(4) {
        val segments=List(n) {
            val a=1700+random.nextInt(320000).toLong()
            RateSegment(a,a+1+random.nextInt(60000),.25+random.nextDouble()*3.75,.25+random.nextDouble()*3.75)
        }
        val c=TimelineClip("overlaps",7,"producer overview",360000,1317,351113,1700,QueueSegment.Manual,RateAutomation(.25+random.nextDouble()*3.75,segments))
        val v=TimelineViewport(1500000,24f,.125+random.nextDouble()*2,random.nextInt(160000).toLong())
        val p=window(tiny,c,v)
        check(projectSpectralWaveform(p,c,v)==originalProjection(p,c,v)) {"overlap precedence mismatch n=$n"}
        cases++
    }
    val c=TimelineClip("edges",7,"bins",1000,0,1000,0,QueueSegment.Manual)
    val v=TimelineViewport(1000,100f,100.0)
    val nonaligned=PeakWindow(155,845,floatArrayOf(-.3f,-.5f,-.7f),FloatArray(3){.9f},coverage=WaveformBinCoverage("eight",8,1,7,1000))
    val columns=projectSpectralWaveform(nonaligned,c,v).columns
    check(columns.map {it.left}==listOf(15f,37f,62f))
    check(columns.map {it.right}==listOf(38f,63f,85f))
    check(columns.map {it.minimum}==listOf(-.3f,-.5f,-.7f))
    check(columns.all {it.color==S.W10_SPECTRUM_UNAVAILABLE})
    check(projectSpectralWaveform(null,c,v).columns.isEmpty())
    for(bad in listOf(nonaligned.copy(minima=FloatArray(0)),nonaligned.copy(maxima=FloatArray(2)),nonaligned.copy(coverage=nonaligned.coverage!!.copy(sourceBinCount=0))))check(projectSpectralWaveform(bad,c,v).columns.isEmpty())
    check(spectralSampleColor(0f,0f,0f)==S.W10_SPECTRUM_UNAVAILABLE)
    check(spectralSampleColor(1f,.5f,.25f)==spectralSampleColor(.01f,.005f,.0025f))
    val cache=WaveformCache(w.bytes+30000)
    cache.put(w)
    repeat(40) {i->cache.window(w,1000+i*101L,300000+i*101L,360);check(cache.bytes<=cache.maxBytes)}
    val hit=cache.window(w,0,10000,100);check(hit===cache.window(w,0,10000,100))
    cache.clear();check(cache.bytes==0L)
    println("PASS compatibility: $cases exact predecessor projections, nonaligned floor/ceil, signed extrema, real packed Color, clipping/invalid/empty, cache cap/hit/clear")
}
private fun performance(w:TrackWaveform) {
    val failures=mutableListOf<String>()
    for(segmentCount in listOf(0,32)) {
        val segments=CountedList(List(segmentCount){i->RateSegment(1700+i*10000L,1700+(i+1)*10000L,.75+(i%3)*.125,1.25)})
        val c=TimelineClip("perf",7,"six-minute producer",360000,1317,351113,1700,QueueSegment.Manual,RateAutomation(1.0,segments))
        val v=TimelineViewport(500000,720f,2.0,13007)
        val p=window(w,c,v)!!
        segments.reads=0;segments.sizeReads=0
        val start=System.nanoTime()
        val paint=projectSpectralWaveform(p,c,v)
        val elapsed=(System.nanoTime()-start)/1000000.0
        val sourceReads=segments.reads;val sizeReads=segments.sizeReads
        println("OBSERVED production projection: producerBins=${w.tiers.last().minima.size} windowColumns=${p.minima.size} paintColumns=${paint.columns.size} rateSegments=$segmentCount acceptedRateListReads=$sourceReads rateListSizeReads=$sizeReads elapsedMs=$elapsed")
        check(paint.columns.size>=600)
        check(paint==originalProjection(p,c,v)) {"long producer $segmentCount-segment geometry/color mismatch"}
        // One immutable rate snapshot per projection, not a rebuilt integral per pixel/inverse step.
        if(sourceReads>256||sizeReads>1024)failures+="$segmentCount segments: $sourceReads elements / $sizeReads sizes for ${paint.columns.size} columns"
    }
    // Discriminate cache-accounting scans at the same real-size seam. These are
    // observations, not a latency gate or permission to change cache semantics.
    val tiers=CountedList(w.tiers)
    val counted=w.copy(tiers=tiers)
    val cache=WaveformCache()
    cache.put(counted)
    repeat(120) {i->cache.window(counted,1000+i*101L,300000+i*101L,720)}
    tiers.reads=0;tiers.sizeReads=0
    val cacheStart=System.nanoTime()
    val reduced=cache.window(counted,17013,310117,720)
    val cacheMs=(System.nanoTime()-cacheStart)/1000000.0
    println("OBSERVED cache miss after 120 zoom windows: columns=${reduced.minima.size} sourceTierReads=${tiers.reads} sourceTierSizeReads=${tiers.sizeReads} elapsedMs=$cacheMs retainedBytes=${cache.bytes}")
    check(cache.bytes<=cache.maxBytes)
    check(failures.isEmpty()) {"ZOOM REGRESSION: $failures; budgets 256 element/1024 size reads"}
    println("PASS zoom operation budget")
}
fun main(args:Array<String>) {
    val raw=GZIPInputStream(File(args[0]).inputStream()).use {it.readBytes()}
    check(raw.size==2400029)
    val hash=java.security.MessageDigest.getInstance("SHA-256").digest(raw).joinToString(""){"%02x".format(it)}
    check(hash=="e4bd539faf7a9ad933d7b900764d7ca6f3ccd392dc3f7281e56fced83af4cfba")
    val wave=AnalysisWaveformJson.parse(Json.parseToJsonElement(raw.toString(Charsets.UTF_8)).jsonObject,TrackId(7),360000)
    check(wave.tiers.map {it.minima.size}==listOf(512,28800))
    println("PRODUCER bytes=${raw.size} sha256=$hash tiers=${wave.tiers.map {it.name to it.minima.size}} retainedBytes=${wave.bytes}")
    if(args[1]!="performance")compatibility(wave)
    if(args[1]!="compatibility")performance(wave)
}
