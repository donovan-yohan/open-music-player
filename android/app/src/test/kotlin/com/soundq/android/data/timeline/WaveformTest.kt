package com.soundq.android.data.timeline

import com.soundq.android.data.TrackId
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class WaveformTest {
    @Test fun realGoAnalysisResponsePreservesPublishedSpectrum() {
        val body=Json.parseToJsonElement(javaClass.getResource("/waveform/backend_analysis_response.json")!!.readText()).jsonObject
        assertEquals("analyzed",body.getValue("status").jsonPrimitive.content)
        val wave=AnalysisWaveformJson.parse(body,TrackId(7),197500)
        assertEquals("analyzed",wave.status)
        assertEquals(listOf("overview","detail"),wave.tiers.map {it.name})
        assertNotNull(wave.tiers.last().spectral)
        assertEquals(.62f,wave.tiers.last().spectral!!.low[6],0f)
    }
    @Test fun backendLifecycleStatusesRemainExactAndUnknownStatusesRefuse() {
        val body=Json.parseToJsonElement(javaClass.getResource("/waveform/backend_analysis_response.json")!!.readText()).jsonObject
        for(status in listOf("pending","analyzing","analyzed","failed","stale","unsupported","queued","running","processing","completed")) {
            val wave=AnalysisWaveformJson.parse(JsonObject(body+("status" to JsonPrimitive(status))),TrackId(7),197500)
            assertEquals(status,wave.status)
        }
        for(status in listOf(JsonPrimitive("ready"),JsonPrimitive("Analyzed"),JsonPrimitive(""),JsonPrimitive(1),JsonNull)) {
            assertThrows(Exception::class.java){AnalysisWaveformJson.parse(JsonObject(body+("status" to status)),TrackId(7),197500)}
        }
    }
    private fun producerBody():JsonObject {
        val fixture=javaClass.getResource("/waveform/synthetic_analysis.json")!!.readText()
        return JsonObject(Json.parseToJsonElement(fixture).jsonObject + mapOf("track_id" to JsonPrimitive(7),"status" to JsonPrimitive("completed")))
    }
    private fun changedChannel(body:JsonObject,tier:String,band:String,value:JsonElement):JsonObject {
        val artifacts=body.getValue("artifacts").jsonObject
        val channels=artifacts.getValue("channels").jsonObject
        val values=channels.getValue(tier).jsonObject
        return JsonObject(body+ ("artifacts" to JsonObject(artifacts+ ("channels" to JsonObject(channels+ (tier to JsonObject(values+ (band to value))))))))
    }
    @Test fun producerSpectralSamplesMustBeIncludedInSourceByteBudget() {
        val wave=AnalysisWaveformJson.parse(producerBody(),TrackId(7),197500)
        // Six overview + twelve detail bins, five floats per bin, actual beat/downbeat lists.
        assertTrue("source cache must account for admitted low/mid/high",wave.bytes>=18*5*4L+10*8L+256)
    }
    @Test fun malformedNamedChannelsCannotSilentlyFallBackToValidLegacyDualWrite() {
        val body=changedChannel(producerBody(),"detail","high",buildJsonArray {repeat(12){add(-0.1)}})
        assertThrows(IllegalArgumentException::class.java){AnalysisWaveformJson.parse(body,TrackId(7),197500)}
    }
    @Test fun producerBandsSurviveTierSelectionAndIndependentPeakReduction() {
        val wave=AnalysisWaveformJson.parse(producerBody(),TrackId(7),197500)
        val detail=wave.tiers.last().spectral!!
        assertEquals("bands3-v1",detail.metadata.channelSet)
        assertEquals(2.8,detail.metadata.normalization!!.scalar,0.0)
        assertEquals(SpectralWeights(1.0,1.6,2.8),detail.metadata.weights)
        assertEquals(SpectralCrossovers(200.0,2000.0),detail.metadata.crossovers)
        assertEquals("fixture:librosa-mel-bands-v2",detail.metadata.provenance)
        assertArrayEquals(floatArrayOf(0f,.08f,.17f,.31f,.55f,.59f,.62f,.58f,.49f,.35f,.18f,.05f),detail.low,0f)
        val cache=WaveformCache();cache.put(wave)
        val window=cache.window(wave,0,197500,7)
        assertArrayEquals(floatArrayOf(.08f,.31f,.59f,.62f,.62f,.49f,.18f),window.spectral!!.low,0f)
        assertArrayEquals(floatArrayOf(.11f,.38f,.67f,.71f,.71f,.52f,.19f),window.spectral.mid,0f)
        assertArrayEquals(floatArrayOf(.04f,.16f,.29f,.35f,.35f,.31f,.08f),window.spectral.high,0f)
        assertArrayEquals(floatArrayOf(-.10f,-.36f,-.69f,-.78f,-.78f,-.49f,-.19f),window.minima,0f)
        assertSame(detail.metadata,window.spectral.metadata)
        assertEquals("detail",window.coverage!!.tierName)
        assertSame(window,cache.window(wave,0,197500,7))
        val overview=cache.window(wave,0,197500,6)
        assertEquals("overview",overview.coverage!!.tierName)
        assertArrayEquals(floatArrayOf(0f,.17f,.55f,.62f,.49f,.18f),overview.spectral!!.low,0f)
        val zoom=cache.window(wave,40000,90000,8192)
        assertEquals(WaveformBinCoverage("detail",12,2,6,197500),zoom.coverage)
        assertEquals(4,zoom.minima.size)
        assertArrayEquals(floatArrayOf(.17f,.31f,.55f,.59f),zoom.spectral!!.low,0f)
        assertEquals(40000L,zoom.sourceStartMs);assertEquals(90000L,zoom.sourceEndMs)
    }
    @Test fun changedSpectralContentWithoutRevisionCannotReuseOldWindow() {
        val first=AnalysisWaveformJson.parse(producerBody(),TrackId(7),197500)
        val revised=AnalysisWaveformJson.parse(changedChannel(producerBody(),"detail","low",buildJsonArray {repeat(12){add(.01)}}),TrackId(7),197500)
        assertNotEquals(first.sourceKey,revised.sourceKey)
        val cache=WaveformCache();cache.put(first);val old=cache.window(first,0,197500,12)
        cache.put(revised)
        val fresh=cache.window(revised,0,197500,12)
        assertNotSame(old,fresh)
        assertArrayEquals(FloatArray(12){.01f},fresh.spectral!!.low,0f)
    }
    private fun replaceAt(body:JsonObject,vararg path:String,value:JsonElement?):JsonObject {
        val key=path.first()
        val next=if(path.size==1)value else replaceAt(body.getValue(key).jsonObject,*path.drop(1).toTypedArray(),value=value)
        return JsonObject(if(next==null)body-key else body+(key to next))
    }
    @Test fun corruptDescriptorsAreRefusedEvenWhenArtifactsContainValidBands() {
        val body=producerBody()
        val corrupt=listOf(
            replaceAt(body,"summary","waveform","channels","sample_count",value=JsonPrimitive(11)),
            replaceAt(body,"summary","waveform","channels","values","low","artifact_ref",value=JsonPrimitive("channels.other.low")),
            replaceAt(body,"summary","waveform","channels","values","mid",value=null),
            replaceAt(body,"summary","waveform","channels","values","low","sample_count",value=JsonPrimitive(11)),
            replaceAt(body,"summary","waveform","channels","channel_set",value=JsonPrimitive("stems-v1")),
            replaceAt(body,"summary","waveform","channels","normalization","scalar",value=JsonPrimitive(0)),
        )
        corrupt.forEachIndexed {i,c ->assertThrows("corrupt descriptor $i",Exception::class.java){AnalysisWaveformJson.parse(c,TrackId(7),197500)}}
    }
    @Test fun inlineNamedDescriptorAndLegacyFallbackKeepRealZerosAndNoInventedMetadata() {
        val inline=Json.parseToJsonElement("""{"track_id":7,"schema_version":1,"status":"completed","summary":{"waveform":{"minima":[0,-0.9,0,0],"maxima":[0,0.2,0,0],"channels":{"channel_set":"bands3-v1","sample_count":4,"normalization":{"kind":"shared_peak","scalar":1},"values":{"low":{"values":[0,0.8,0,0]},"mid":{"values":[0,0.2,0,0]},"high":{"values":[0,0.1,0,0]}}}}}}""").jsonObject
        val wave=AnalysisWaveformJson.parse(inline,TrackId(7),4000)
        val window=WaveformCache().window(wave,0,4000,4)
        assertArrayEquals(floatArrayOf(0f,.8f,0f,0f),window.spectral!!.low,0f)
        assertArrayEquals(floatArrayOf(0f,.2f,0f,0f),window.spectral.mid,0f)
        assertArrayEquals(floatArrayOf(0f,.1f,0f,0f),window.spectral.high,0f)
        val body=producerBody()
        val legacy=replaceAt(replaceAt(body,"summary","waveform","channels",value=null),"artifacts","channels",value=null)
        val bands=AnalysisWaveformJson.parse(legacy,TrackId(7),197500).tiers.last().spectral!!
        assertNull(bands.metadata.channelSet);assertNull(bands.metadata.normalization);assertNull(bands.metadata.provenance)
        assertEquals(.62f,bands.low[6],0f)
    }
    @Test fun absentSparseMalformedAndMismatchedChannelsNeverInventSamples() {
        val body=producerBody()
        for(bad in listOf(JsonArray(emptyList()),JsonArray(List(11){JsonPrimitive(.2)}),JsonArray(List(12){JsonPrimitive(".2")}),JsonArray(List(12){JsonPrimitive(1.1)}))) {
            assertThrows(Exception::class.java){AnalysisWaveformJson.parse(changedChannel(body,"detail","low",bad),TrackId(7),197500)}
        }
        val missing=replaceAt(body,"artifacts","channels","detail","high",value=null)
        assertThrows(Exception::class.java){AnalysisWaveformJson.parse(missing,TrackId(7),197500)}
        var zero=body
        for(tier in listOf("overview","detail"))for(band in listOf("low","mid","high")) {
            zero=changedChannel(zero,tier,band,JsonArray(List(if(tier=="overview")6 else 12){JsonPrimitive(0)}))
        }
        val window=WaveformCache().window(AnalysisWaveformJson.parse(zero,TrackId(7),197500),0,197500,12)
        assertArrayEquals(FloatArray(12),window.spectral!!.low,0f)
        assertArrayEquals(FloatArray(12),window.spectral.mid,0f)
        assertArrayEquals(FloatArray(12),window.spectral.high,0f)
        val scalar=Json.parseToJsonElement("""{"track_id":7,"schema_version":1,"status":"completed","summary":{"waveform":{"peaks":[0,0.3]}}}""").jsonObject
        val scalarWave=AnalysisWaveformJson.parse(scalar,TrackId(7),1000)
        assertNull(scalarWave.tiers.single().spectral)
        assertNull(WaveformCache().window(scalarWave,0,1000,8192).spectral)
    }
    @Test fun spectralSourcesAndWindowsStayWithinOneByteBoundedCache() {
        val wave=AnalysisWaveformJson.parse(producerBody(),TrackId(7),197500)
        val probe=WaveformCache().window(wave,0,197500,12)
        assertTrue(probe.bytes>=12*5*4L+64)
        val limit=wave.bytes+probe.bytes*2
        val cache=WaveformCache(limit);cache.put(wave)
        val first=cache.window(wave,0,197500,12)
        val second=cache.window(wave,1000,190000,12)
        assertSame(first,cache.window(wave,0,197500,12))
        cache.window(wave,2000,180000,12)
        assertSame(first,cache.window(wave,0,197500,12))
        assertNotSame(second,cache.window(wave,1000,190000,12))
        repeat(100){i->cache.window(wave,i*100L,197500-i*100L,1+i%13);assertTrue(cache.bytes<=limit)}
        val small=WaveformCache(64);small.put(wave);assertNull(small.get(wave.track))
        assertNotSame(small.window(wave,0,197500,12),small.window(wave,0,197500,12));assertEquals(0L,small.bytes)
        cache.clear();assertEquals(0L,cache.bytes)
    }
    @Test fun spectralAdmissionHonorsPerArrayAndAggregateSampleBounds() {
        val body=producerBody()
        val tooLarge=JsonArray(List(131073){JsonPrimitive(.2)})
        assertThrows(Exception::class.java){AnalysisWaveformJson.parse(changedChannel(body,"detail","low",tooLarge),TrackId(7),197500)}
        val values=JsonArray(List(131072){JsonPrimitive(.2)})
        fun many(tierCount:Int):JsonObject = buildJsonObject {
            put("track_id",7);put("schema_version",1);put("status","completed")
            put("summary",buildJsonObject {put("waveform",buildJsonObject {
                put("resolutions",buildJsonArray {repeat(tierCount){i->add(buildJsonObject {
                    put("name","tier$i");put("peaks",values)
                    put("spectral_bands",buildJsonObject {for(band in listOf("low","mid","high"))put(band,values)})
                })}})
            })})
        }
        assertEquals(2,AnalysisWaveformJson.parse(many(2),TrackId(7),197500).tiers.size)
        assertThrows(Exception::class.java){AnalysisWaveformJson.parse(many(3),TrackId(7),197500)}
    }
    @Test fun producerTransientPositionsRemainSourceRelativeAndByteAccounted() {
        val wave=AnalysisWaveformJson.parse(producerBody(),TrackId(7),197500)
        val getter=wave.javaClass.methods.singleOrNull {it.name=="getTransients"}
        assertNotNull("producer transient markers must survive admission",getter)
        assertEquals(listOf(10120L,20180L,30240L),getter!!.invoke(wave))
        val body=replaceAt(producerBody(),"summary","transients","strongest_ms",value=JsonArray(emptyList()))
        assertEquals(24L,wave.bytes-AnalysisWaveformJson.parse(body,TrackId(7),197500).bytes)
        WaveformCache().window(wave,15000,40000,100)
        assertEquals(listOf(10120L,20180L,30240L),getter.invoke(wave))
    }
    @Test fun namedChannelsBeatConflictingLegacyAndKeepSharedRatios() {
        val body=replaceAt(producerBody(),"artifacts","spectral_bands","detail","low",value=JsonArray(List(12){JsonPrimitive(1)}))
        val wave=AnalysisWaveformJson.parse(body,TrackId(7),197500)
        val bands=WaveformCache().window(wave,0,197500,12).spectral!!
        assertEquals(.08f,bands.low[1],0f);assertEquals(.11f,bands.mid[1],0f);assertEquals(.04f,bands.high[1],0f)
    }
    @Test fun sourceIdentityChangesWithNormalizationProvenanceAndSourceFingerprint() {
        val body=producerBody();val wave=AnalysisWaveformJson.parse(body,TrackId(7),197500)
        val revised=replaceAt(body,"artifacts","source","fingerprint",value=JsonPrimitive("fixture-new"))
        assertNotEquals(wave.sourceKey,AnalysisWaveformJson.parse(revised,TrackId(7),197500).sourceKey)
        val normalized=replaceAt(body,"summary","waveform","channels","normalization","scalar",value=JsonPrimitive(3.0))
        val normalizedArtifacts=replaceAt(normalized,"artifacts","channels","normalization","scalar",value=JsonPrimitive(3.0))
        var both=normalizedArtifacts
        for(band in listOf("low","mid","high"))both=replaceAt(both,"summary","waveform","channels","values",band,"normalization","scalar",value=JsonPrimitive(3.0))
        assertNotEquals(wave.sourceKey,AnalysisWaveformJson.parse(both,TrackId(7),197500).sourceKey)
        var provenance=replaceAt(body,"summary","waveform","channels","provenance",value=JsonPrimitive("fixture:next"))
        provenance=replaceAt(provenance,"artifacts","channels","provenance",value=JsonPrimitive("fixture:next"))
        for(band in listOf("low","mid","high"))provenance=replaceAt(provenance,"summary","waveform","channels","values",band,"provenance",value=JsonPrimitive("fixture:next"))
        assertNotEquals(wave.sourceKey,AnalysisWaveformJson.parse(provenance,TrackId(7),197500).sourceKey)
        assertEquals(wave.sourceKey,AnalysisWaveformJson.parse(body,TrackId(7),197500).sourceKey)
    }
    @Test fun malformedNamedInlineValuesAndOrphanTiersCannotHideBehindArtifacts() {
        val body=producerBody()
        val raw=replaceAt(body,"summary","waveform","channels","values","low",value=JsonArray(List(12){JsonPrimitive(-.1)}))
        assertThrows(Exception::class.java){AnalysisWaveformJson.parse(raw,TrackId(7),197500)}
        val orphan=replaceAt(body,"artifacts","channels","ghost",value=buildJsonObject {put("low",JsonArray(emptyList()))})
        assertThrows(Exception::class.java){AnalysisWaveformJson.parse(orphan,TrackId(7),197500)}
        val inline=replaceAt(body,"summary","waveform","channels","values","low","values",value=JsonArray(List(12){JsonPrimitive(.1)}))
        val hidden=changedChannel(inline,"detail","low",JsonArray(List(12){JsonPrimitive(-.1)}))
        assertThrows(Exception::class.java){AnalysisWaveformJson.parse(hidden,TrackId(7),197500)}
    }
    @Test fun originalScalarConstructorsAndEmptyPendingDataRemainUsable() {
        val scalar=TrackWaveform(TrackId(7),"scalar",1000,listOf(PeakTier("scalar",floatArrayOf(-.7f),floatArrayOf(.1f))))
        val window=WaveformCache().window(scalar,333,334,8192)
        assertEquals(1,window.minima.size);assertNull(window.spectral)
        assertArrayEquals(floatArrayOf(-.7f),window.minima,0f)
        val pending=AnalysisWaveformJson.parse(buildJsonObject {put("track_id",7);put("schema_version",1);put("status","pending")},TrackId(7),1000)
        val empty=WaveformCache().window(pending,0,1000,10)
        assertTrue(empty.minima.isEmpty());assertNull(empty.spectral);assertNull(empty.coverage)
    }
    @Test fun nonAlignedViewportColumnsUseIdenticalSourceBinsForAllFiveArrays() {
        val wave=AnalysisWaveformJson.parse(producerBody(),TrackId(7),197500)
        val tier=wave.tiers.last();val source=tier.spectral!!;val cache=WaveformCache()
        for(start in listOf(1L,16458L,40000L,170000L))for(columns in listOf(1,3,11,8192)) {
            val end=minOf(197500L,start+50000)
            val window=cache.window(wave,start,end,columns)
            val coverage=window.coverage!!
            val original=wave.tiers.single {it.name==coverage.tierName}
            val bands=original.spectral!!
            for(i in window.minima.indices) {
                val a=coverage.firstBin+i*(coverage.endBin-coverage.firstBin)/window.minima.size
                val b=coverage.firstBin+kotlin.math.ceil((i+1).toDouble()*(coverage.endBin-coverage.firstBin)/window.minima.size).toInt()
                assertEquals(original.minima.sliceArray(a until b).min(),window.minima[i],0f)
                assertEquals(original.maxima.sliceArray(a until b).max(),window.maxima[i],0f)
                assertEquals(bands.low.sliceArray(a until b).max(),window.spectral!!.low[i],0f)
                assertEquals(bands.mid.sliceArray(a until b).max(),window.spectral.mid[i],0f)
                assertEquals(bands.high.sliceArray(a until b).max(),window.spectral.high[i],0f)
            }
        }
        assertEquals(12,source.low.size)
    }
    @Test fun tierLocalNamedChannelsWithoutAnIdentityAreNotIgnoredAsScalarData() {
        val body=buildJsonObject {
            put("track_id",7);put("schema_version",1);put("status","completed")
            put("summary",buildJsonObject {put("waveform",buildJsonObject {put("resolutions",buildJsonArray {add(buildJsonObject {
                put("name","detail");put("peaks",buildJsonArray {add(.2)})
                put("channels",buildJsonObject {for(band in listOf("low","mid","high"))put(band,buildJsonArray {add(.1)})})
            })})})})
        }
        assertThrows(Exception::class.java){AnalysisWaveformJson.parse(body,TrackId(7),1000)}
    }
    @Test fun actualServerBeatGridProjectionWinsOverRawBpmMarkers() {
        val body=Json.parseToJsonElement("""{"track_id":7,"schema_version":1,"status":"completed","summary":{"bpm":{"beats_ms":[0,500]},"downbeats":{"positions_ms":[0]}},"effective_timing":{"beat_grid":{"beats_ms":[100,600]},"downbeats":{"positions_ms":[100]}}}""").jsonObject
        val wave=AnalysisWaveformJson.parse(body,TrackId(7),1000)
        assertEquals(listOf(100L,600L),wave.beats);assertEquals(listOf(100L),wave.downbeats)
    }
    @Test fun actualArtifactsHydrateSignedPeaksAndMarkersWithoutInterpolation() {
        val body=Json.parseToJsonElement("""{"track_id":7,"schema_version":1,"status":"completed","updated_at":"r1","summary":{"downbeats":{"positions_ms":[0,2000]},"bpm":{"beats_ms":[0,500,1000]}},"artifacts":{"waveforms":{"detail":{"min_peaks":[-0.1,-0.9,-0.2,-0.8],"max_peaks":[0.2,0.3,0.7,0.4]}}}}""").jsonObject
        val wave=AnalysisWaveformJson.parse(body,TrackId(7),4000)
        assertEquals(listOf(0L,2000L),wave.downbeats)
        assertEquals(listOf(0L,500L,1000L),wave.beats)
        val cache=WaveformCache()
        val window=cache.window(wave,0,4000,2)
        assertArrayEquals(floatArrayOf(-0.9f,-0.8f),window.minima,0f)
        assertArrayEquals(floatArrayOf(0.3f,0.7f),window.maxima,0f)
        assertSame(window,cache.window(wave,0,4000,2))
        assertEquals(4,cache.window(wave,0,4000,100).minima.size)
    }
    @Test fun byteBudgetEvictsLeastRecentlyUsedAndSourceRevisionInvalidatesWindow() {
        val cache=WaveformCache(1400)
        fun wave(id:Long,key:String)=TrackWaveform(TrackId(id),key,10000,listOf(PeakTier("detail",FloatArray(64){-0.5f},FloatArray(64){0.5f})))
        val first=wave(1,"v1");cache.put(first);cache.put(wave(2,"v1"))
        assertNull(cache.get(TrackId(1)));assertNotNull(cache.get(TrackId(2)));assertTrue(cache.bytes<=1400)
        cache.put(first);val old=cache.window(first,0,10000,4)
        val revised=wave(1,"v2");cache.put(revised)
        assertNotSame(old,cache.window(revised,0,10000,4));assertTrue(cache.bytes<=1400)
    }
    @Test fun mismatchedTrackOrMalformedSignedArraysAreRefused() {
        val body=Json.parseToJsonElement("""{"track_id":8,"schema_version":1,"status":"completed","summary":{"waveform":{"min_peaks":[-0.2],"max_peaks":[0.5]}}}""").jsonObject
        assertThrows(Exception::class.java){AnalysisWaveformJson.parse(body,TrackId(7),1000)}
    }
}
