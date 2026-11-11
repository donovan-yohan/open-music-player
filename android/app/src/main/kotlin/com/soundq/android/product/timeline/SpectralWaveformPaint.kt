package com.soundq.android.product.timeline

import androidx.compose.ui.graphics.Color
import com.soundq.android.data.timeline.*
import soundq.design.generated.SoundQSpectralTokens as S
import kotlin.math.*

/** Immutable lane-local projection, outside the shared 16 MiB source/window LRU.
 * At most 8192 columns; conservative retained estimate includes objects/list references.
 * Heights remain signed source extrema. Color never depends on height, theme or selection.
 */
internal data class SpectralPaintColumn(val left:Float,val right:Float,val minimum:Float,val maximum:Float,val color:Color)
internal data class SpectralWaveformPaint(val columns:List<SpectralPaintColumn>) {
    val estimatedBytes:Long get()=128L+columns.size*80L
}

/** Width is already in physical pixels from onSizeChanged, not dp. */
internal fun spectralWindowColumns(clip:TimelineClip,v:TimelineViewport):Int =
    ceil((minOf(v.widthPx,v.x(clip.globalEndMs))-maxOf(0f,v.x(clip.globalStartMs))).coerceAtLeast(0f).toDouble()).toInt().coerceIn(1,8192)

internal fun spectralSampleColor(low:Float,mid:Float,high:Float):Color {
    // Producer already applied shared normalization and band weights. Do not apply twice.
    val red=S.W10_SPECTRUM_LOW.red*low+S.W10_SPECTRUM_MID.red*mid+S.W10_SPECTRUM_HIGH.red*high
    val green=S.W10_SPECTRUM_LOW.green*low+S.W10_SPECTRUM_MID.green*mid+S.W10_SPECTRUM_HIGH.green*high
    val blue=S.W10_SPECTRUM_LOW.blue*low+S.W10_SPECTRUM_MID.blue*mid+S.W10_SPECTRUM_HIGH.blue*high
    val maximum=maxOf(red,green,blue)
    return if(maximum<=0f)S.W10_SPECTRUM_UNAVAILABLE else Color(red/maximum*0.94f,green/maximum*0.94f,blue/maximum*0.94f)
}

internal fun projectSpectralWaveform(peaks:PeakWindow?,clip:TimelineClip,v:TimelineViewport):SpectralWaveformPaint {
    val coverage=peaks?.coverage ?: return SpectralWaveformPaint(emptyList())
    val count=peaks.minima.size
    if(count==0||count>8192||peaks.maxima.size!=count||coverage.sourceBinCount<=0||coverage.endBin<=coverage.firstBin)return SpectralWaveformPaint(emptyList())
    // Freeze the bounded rate geometry once, not once per column/inverse probe.
    val geometry=SpectralRateProjection(clip)
    val visibleStart=maxOf(clip.globalStartMs,v.offsetMs)
    val visibleEnd=minOf(geometry.globalEndMs,v.offsetMs+v.visibleMs)
    if(visibleEnd<=visibleStart)return SpectralWaveformPaint(emptyList())
    val sourceStart=maxOf(clip.sourceInMs,peaks.sourceStartMs,geometry.sourceAt(visibleStart))
    val sourceEnd=minOf(clip.sourceOutMs,peaks.sourceEndMs,geometry.sourceAt(visibleEnd))
    val bands=peaks.spectral?.takeIf {it.low.size==count&&it.mid.size==count&&it.high.size==count}
    val span=coverage.endBin-coverage.firstBin
    val columns=ArrayList<SpectralPaintColumn>(count)
    for(i in 0 until count) {
        // Exactly the reducer's floor/ceil grouping, not a stretched requested-time index.
        val a=coverage.firstBin+i*span/count
        val b=coverage.firstBin+ceil((i+1).toDouble()*span/count).toInt()
        val start=maxOf(sourceStart,floor(a.toDouble()*coverage.sourceDurationMs/coverage.sourceBinCount).toLong())
        val end=minOf(sourceEnd,ceil(b.toDouble()*coverage.sourceDurationMs/coverage.sourceBinCount).toLong())
        if(end<=start)continue
        val left=maxOf(0f,v.x(visibleStart),floor(v.x(geometry.globalAt(start))))
        val right=minOf(v.widthPx,v.x(visibleEnd),ceil(v.x(geometry.globalAt(end))))
        if(right<=left)continue
        val color=if(bands==null)S.W10_SPECTRUM_UNAVAILABLE else spectralSampleColor(bands.low[i],bands.mid[i],bands.high[i])
        columns+=SpectralPaintColumn(left,right,peaks.minima[i],peaks.maxima[i],color)
    }
    return SpectralWaveformPaint(columns)
}
