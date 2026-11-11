package com.soundq.android.product.timeline

import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import soundq.design.generated.SoundQSpectralTokens as S

class SpectralWaveformPaintTest {
    private fun clip(duration:Long=1000,start:Long=0,inside:Long=0,out:Long=duration,rates:RateAutomation=RateAutomation())=TimelineClip("O",7,"Source",duration,inside,out,start,QueueSegment.Context,rates)
    private fun wave(n:Int=1000,spectral:Boolean=true)=TrackWaveform(TrackId(7),"source$n",1000,listOf(PeakTier("detail",FloatArray(n){-0.6f},FloatArray(n){0.8f},if(spectral)SpectralBands(FloatArray(n){1f},FloatArray(n){0.5f},FloatArray(n){0.25f},SpectralMetadata("bands3-v1",SharedPeakNormalization(2.8),SpectralWeights(1.0,1.6,2.8))) else null)))
    private fun paint(w:TrackWaveform=wave(),c:TimelineClip=clip(),v:TimelineViewport=TimelineViewport(2000,100f,100.0)):SpectralWaveformPaint {
        val start=c.sourceAt(maxOf(c.globalStartMs,v.offsetMs)).coerceIn(c.sourceInMs,c.sourceOutMs)
        val end=c.sourceAt(minOf(c.globalEndMs,v.offsetMs+v.visibleMs)).coerceIn(c.sourceInMs,c.sourceOutMs)
        return projectSpectralWaveform(if(end>start)WaveformCache().window(w,start,end,spectralWindowColumns(c,v)) else null,c,v)
    }
    @Test fun mixedEnergiesNormalizeMaximumOnlyOnce(){
        val p=paint().columns.first()
        assertEquals(0.94f,p.color.red,0.004f);assertEquals(0.47f,p.color.green,0.004f);assertEquals(0.235f,p.color.blue,0.004f)
        assertEquals(-0.6f,p.minimum);assertEquals(0.8f,p.maximum)
    }
    @Test fun quietAndLoudSamplesKeepIdenticalInformativeHue(){
        assertEquals(spectralSampleColor(1f,0.5f,0.25f),spectralSampleColor(0.01f,0.005f,0.0025f))
    }
    @Test fun missingBandsKeepMeasuredSignedExtremaInNeutralRole(){
        val p=paint(wave(spectral=false)).columns.first()
        assertEquals(S.W10_SPECTRUM_UNAVAILABLE,p.color);assertEquals(-0.6f,p.minimum);assertEquals(0.8f,p.maximum)
    }
    @Test fun trueZeroEnergyIsNeutralNotBrandOrInventedHue(){assertEquals(S.W10_SPECTRUM_UNAVAILABLE,spectralSampleColor(0f,0f,0f))}
    @Test fun missingWaveformAndOffscreenAreEmpty(){
        assertTrue(projectSpectralWaveform(null,clip(),TimelineViewport(1000,100f)).columns.isEmpty())
        assertTrue(paint(c=clip(start=1500),v=TimelineViewport(2000,100f,100.0)).columns.isEmpty())
    }
    @Test fun physicalPixelDensitySelectsTierAndNeverInventsSourceSamples(){
        val w=wave(1000).copy(tiers=listOf(wave(100).tiers.single().copy(name="overview"),wave(1000).tiers.single()))
        val cache=WaveformCache()
        assertEquals("overview",cache.window(w,0,1000,100).coverage!!.tierName)
        assertEquals("detail",cache.window(w,0,1000,300).coverage!!.tierName)
        assertEquals(100,paint(w,v=TimelineViewport(1000,100f,100.0)).columns.size)
        assertEquals(300,paint(w,v=TimelineViewport(1000,300f,300.0)).columns.size)
        assertEquals(3,paint(wave(3),v=TimelineViewport(1000,300f,300.0)).columns.size)
        assertEquals(20,spectralWindowColumns(clip(out=200),TimelineViewport(1000,100f,100.0)))
    }
    @Test fun nonalignedViewportUsesExactReducerSourceBinsNotRequestedTimeStretch(){
        val minima=floatArrayOf(-0.1f,-0.2f,-0.3f,-0.4f,-0.5f,-0.6f,-0.7f,-0.8f)
        val w=wave(8).copy(tiers=listOf(PeakTier("eight",minima,FloatArray(8){0.9f})))
        val window=WaveformCache().window(w,155,845,3)
        assertEquals(WaveformBinCoverage("eight",8,1,7,1000),window.coverage)
        val p=projectSpectralWaveform(window,clip(),TimelineViewport(1000,100f,100.0)).columns
        assertEquals(listOf(15f,37f,62f),p.map {it.left})
        assertEquals(listOf(38f,63f,85f),p.map {it.right})
        assertEquals(listOf(-0.3f,-0.5f,-0.7f),p.map {it.minimum})
    }
    @Test fun trimsPlacementAndAutomatedRatesUseAuthoritativeSourceGlobalInverse(){
        val c=clip(start=200,inside=200,out=800,rates=RateAutomation(1.0,listOf(RateSegment(200,500,1.0,2.0))))
        val v=TimelineViewport(2000,200f,100.0)
        val columns=paint(wave(6),c,v).columns
        assertEquals(v.x(c.globalStartMs),columns.first().left,0.01f)
        assertEquals(v.x(c.globalEndMs),columns.last().right,0.01f)
        val window=WaveformCache().window(wave(6),200,800,6)
        val p=projectSpectralWaveform(window,c,v).columns
        assertEquals(kotlin.math.floor(v.x(c.globalAt(333))),p[1].left,0.01f)
    }
    @Test fun denseProjectionIsContinuousAndBoundedWithoutLruBudgetClaims(){
        val p=paint(wave(131072),v=TimelineViewport(1000,9000f,9000.0))
        assertEquals(8192,p.columns.size)
        assertTrue(p.columns.zipWithNext().all {(a,b)->a.right>=b.left})
        assertEquals(128L+8192*80L,p.estimatedBytes)
        assertTrue(p.estimatedBytes<700000)
    }
    @Test fun exactProducerFixtureReachesRealPaintWithIndependentBands(){
        val text=javaClass.getResource("/waveform/synthetic_analysis.json")!!.readText()
        val body=Json.parseToJsonElement(text).jsonObject
        val w=AnalysisWaveformJson.parse(JsonObject(body+mapOf("track_id" to JsonPrimitive(7),"status" to JsonPrimitive("completed"))),TrackId(7),197500)
        val p=paint(w,clip(197500),TimelineViewport(197500,120f,120000.0/197500))
        assertEquals(12,p.columns.size)
        assertTrue(p.columns.map {it.color}.distinct().size>1)
        assertTrue(p.columns.any {it.minimum<0&&it.maximum>0})
    }
}
