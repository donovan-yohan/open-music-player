package com.soundq.android.data.timeline

import com.soundq.android.data.TrackId
import kotlinx.serialization.json.*
import kotlin.math.*

/** Values are producer-normalized energies, not stem channels or display colors. */
data class SharedPeakNormalization(val scalar:Double)
data class SpectralWeights(val low:Double,val mid:Double,val high:Double)
data class SpectralCrossovers(val lowMidHz:Double,val midHighHz:Double)
data class SpectralMetadata(
    val channelSet:String?,
    val normalization:SharedPeakNormalization?=null,
    val weights:SpectralWeights?=null,
    val crossovers:SpectralCrossovers?=null,
    val provenance:String?=null,
) {
    val bytes:Long get()=192L+(channelSet?.length ?: 0)*2L+(provenance?.length ?: 0)*2L
}
/** Arrays are immutable by convention and never mutated after admission. */
data class SpectralBands(val low:FloatArray,val mid:FloatArray,val high:FloatArray,val metadata:SpectralMetadata) {
    val bytes:Long get()=(low.size+mid.size+high.size)*4L+metadata.bytes+96
}
data class PeakTier(val name:String,val minima:FloatArray,val maxima:FloatArray,val spectral:SpectralBands?=null)
data class TrackWaveform(val track:TrackId,val sourceKey:String,val durationMs:Long,val tiers:List<PeakTier>,val beats:List<Long> = emptyList(),val downbeats:List<Long> = emptyList(),val status:String="completed",val transients:List<Long> = emptyList(),val phaseTiming:PhaseGrid?=null,val tempoTiming:TempoSourceTiming?=null,val suggestedBpm:Double?=null) {
    /** Generated BPM grants a rate reference, never a beat position or phase grid. */
    fun analysisTempo():TempoSourceTiming? = suggestedBpm?.takeIf {status in setOf("analyzed","completed")&&it.isFinite()&&it in 10.0..600.0}?.let {
        TempoSourceTiming(sourceKey,"analysis:$sourceKey","analysis_bpm",it,0.0,beatAnchorKnown=false)
    }
    val bytes:Long get()=tiers.sumOf {(it.minima.size+it.maxima.size)*4L+(it.spectral?.bytes ?: 0)+128+it.name.length*2L}+(beats.size+downbeats.size+transients.size)*8L+256+(sourceKey.length+status.length)*2L+(phaseTiming?.let {256L+(it.sourceKey.length+it.revision.length+it.provenance.length)*2L} ?: 0)
}
/** Half-open producer bin coverage. Every column uses floor/ceil over this same interval. */
data class WaveformBinCoverage(val tierName:String,val sourceBinCount:Int,val firstBin:Int,val endBin:Int,val sourceDurationMs:Long)
data class PeakWindow(val sourceStartMs:Long,val sourceEndMs:Long,val minima:FloatArray,val maxima:FloatArray,val spectral:SpectralBands?=null,val coverage:WaveformBinCoverage?=null) {
    val bytes:Long get()=(minima.size+maxima.size)*4L+(spectral?.bytes ?: 0)+64+(if(coverage==null)0 else 64+coverage.tierName.length*2L)
}
object AnalysisWaveformJson {
    fun parse(body:JsonObject,track:TrackId,durationMs:Long):TrackWaveform {
        require(durationMs in 1..604800000L)
        require(body.getValue("track_id").jsonPrimitive.let {!it.isString&&it.long==track.value})
        require(body.getValue("schema_version").jsonPrimitive.let {!it.isString&&it.int in 1..2})
        val status=body.getValue("status").jsonPrimitive.let {require(it.isString);it.content}
        // Go analysis responses use analyzing/analyzed/stale/unsupported; keep existing legacy inputs too.
        require(status in setOf("pending","analyzing","analyzed","failed","stale","unsupported","queued","running","processing","completed"))
        val summary=body["summary"] as? JsonObject
        val waveform=summary?.get("waveform") as? JsonObject
        val artifactBody=body["artifacts"] as? JsonObject
        val artifacts=artifactBody?.get("waveforms") as? JsonObject
        val bandNames=setOf("low","mid","high")
        fun text(value:JsonElement):String = value.jsonPrimitive.let {p ->
            require(p.isString && p.content.isNotBlank() && p.content.length<=512);p.content
        }
        fun positive(value:JsonElement):Double = value.jsonPrimitive.let {p ->
            require(!p.isString);p.double.also {require(it.isFinite() && it>0)}
        }
        fun count(value:JsonElement):Int = value.jsonPrimitive.let {p ->
            require(!p.isString);p.int.also {require(it in 1..131072)}
        }
        fun normalization(value:JsonElement):SharedPeakNormalization {
            val obj=value.jsonObject;require(text(obj.getValue("kind"))=="shared_peak")
            return SharedPeakNormalization(positive(obj.getValue("scalar")))
        }
        fun metadata(obj:JsonObject):SpectralMetadata {
            require(text(obj.getValue("channel_set"))=="bands3-v1")
            require(obj["audio_ref"]==null || obj["audio_ref"]==JsonNull)
            val weights=obj["weights"]?.jsonObject?.let {
                require(it.keys==bandNames)
                SpectralWeights(positive(it.getValue("low")),positive(it.getValue("mid")),positive(it.getValue("high")))
            }
            val crossovers=obj["crossovers_hz"]?.jsonObject?.let {
                val low=positive(it.getValue("low_mid"));val high=positive(it.getValue("mid_high"));require(low<high)
                SpectralCrossovers(low,high)
            }
            return SpectralMetadata("bands3-v1",obj["normalization"]?.let(::normalization),weights,crossovers,obj["provenance"]?.let(::text))
        }
        val channelSummary=waveform?.get("channels")?.jsonObject
        val channelArtifacts=artifactBody?.get("channels")?.jsonObject
        val named=channelSummary!=null || channelArtifacts!=null
        val namedMetadata=if(named)metadata(JsonObject((channelArtifacts ?: emptyMap())+(channelSummary ?: emptyMap()))) else null
        if(channelSummary!=null && channelArtifacts!=null) {
            for(key in listOf("channel_set","audio_ref","normalization","weights","crossovers_hz","provenance")) {
                if(channelSummary.containsKey(key)&&channelArtifacts.containsKey(key))require(channelSummary[key]==channelArtifacts[key])
            }
        }
        channelArtifacts?.let {require(it.size<=22)}
        channelSummary?.get("values")?.jsonObject?.let {require(it.keys==bandNames)}
        var total=0
        fun numbers(value:JsonElement?,signed:Boolean):FloatArray {
            if(value==null)return floatArrayOf()
            val array=value.jsonArray;require(array.size<=131072);total+=array.size;require(total<=1048576)
            return FloatArray(array.size){index -> array[index].jsonPrimitive.let {p ->
                require(!p.isString);p.float.also {require(it.isFinite()&&it in (if(signed)-1f else 0f)..1f)}
            }}
        }
        fun spectral(name:String,n:Int,obj:JsonObject):SpectralBands? {
            require(named || !obj.containsKey("channels"))
            val family=if(named)"channels" else "spectral_bands"
            val artifactFamily=artifactBody?.get(family)?.jsonObject
            val inline=obj[family]?.jsonObject?.let {container ->
                if(named && container.containsKey("channel_set"))container["values"]?.jsonObject else container
            }
            val artifactTier=artifactFamily?.get(name)?.jsonObject
            val descriptors=if(named)channelSummary?.get("values")?.jsonObject else waveform?.get("spectral_bands")?.jsonObject
            val applicable=descriptors?.takeIf {d ->
                name=="analysis" || d.values.any {v -> (v as? JsonObject)?.get("artifact_ref")?.let {text(it).startsWith("$family.$name.")}==true } ||
                    (d.values.none {v -> (v as? JsonObject)?.containsKey("artifact_ref")==true} && channelSummary?.get("sample_count")?.let(::count)==n)
            }
            if(applicable!=null && named)channelSummary?.get("sample_count")?.let {require(count(it)==n)}
            val inlineGlobal=applicable?.takeIf {d -> d.values.any {v -> v is JsonArray || (v as? JsonObject)?.let {it.containsKey("values")||it.containsKey("samples")||it.containsKey("data")}==true}}
            val values=inline ?: inlineGlobal ?: artifactTier ?: applicable ?: return null
            require(values.keys==bandNames)
            // Explicit duplicate payloads remain untrusted even when inline values take precedence.
            if(artifactTier!=null && values!==artifactTier) {
                require(artifactTier.keys==bandNames)
                for(band in bandNames)require(numbers(artifactTier.getValue(band),false).size==n)
            }
            fun band(band:String):FloatArray {
                val value=values.getValue(band)
                val descriptor=value as? JsonObject
                val global=applicable?.get(band) as? JsonObject
                fun validate(d:JsonObject?) {
                    if(d==null)return
                    d["sample_count"]?.let {require(count(it)==n)}
                    d["artifact_ref"]?.let {require(text(it)=="$family.$name.$band")}
                    d["normalization"]?.let {require(normalization(it)==namedMetadata?.normalization)}
                    d["weight"]?.let {
                        val expected=when(band){"low"->namedMetadata?.weights?.low;"mid"->namedMetadata?.weights?.mid;else->namedMetadata?.weights?.high}
                        require(positive(it)==expected)
                    }
                    d["provenance"]?.let {require(text(it)==namedMetadata?.provenance)}
                }
                validate(global);validate(descriptor)
                val data=if(descriptor==null)value else descriptor["values"] ?: descriptor["samples"] ?: descriptor["data"] ?: artifactTier?.get(band)
                return numbers(data,false).also {require(it.size==n)}
            }
            return SpectralBands(band("low"),band("mid"),band("high"),namedMetadata ?: SpectralMetadata(null))
        }
        fun tier(name:String,obj:JsonObject,fallback:JsonObject?=null):PeakTier? {
            require(name.isNotBlank() && name.length<=512)
            fun get(vararg keys:String):JsonElement?=keys.firstNotNullOfOrNull {obj[it]} ?: keys.firstNotNullOfOrNull {fallback?.get(it)}
            val min=numbers(get("min_peaks","minPeaks","minima"),true)
            val max=numbers(get("max_peaks","maxPeaks","maxima"),true)
            val peaks=if(min.isEmpty()&&max.isEmpty())numbers(get("peaks"),false) else floatArrayOf()
            if(min.isEmpty()&&max.isEmpty()&&peaks.isEmpty())return null
            val n=if(peaks.isNotEmpty())peaks.size else min.size
            obj["sample_count"]?.let {require(count(it)==n)}
            val bands=spectral(name,n,obj)
            if(peaks.isNotEmpty())return PeakTier(name,FloatArray(peaks.size){-peaks[it]},peaks,bands)
            require(min.size==max.size && min.isNotEmpty() && min.indices.all {min[it]<=max[it]})
            return PeakTier(name,min,max,bands)
        }
        val tiers=mutableListOf<PeakTier>()
        (waveform?.get("resolutions") as? JsonArray)?.also {require(it.size<=16)}?.forEach {v ->
            val obj=v.jsonObject;val name=obj["name"]?.jsonPrimitive?.content ?: "analysis"
            tier(name,obj,artifacts?.get(name) as? JsonObject)?.let(tiers::add)
        }
        artifacts?.entries?.also {require(it.size<=16)}?.forEach {(name,value) ->
            if(tiers.none {it.name==name})tier(name,value.jsonObject)?.let(tiers::add)
        }
        if(tiers.isEmpty()&&waveform!=null)tier("analysis",waveform)?.let(tiers::add)
        if(named) {
            val descriptors=channelSummary?.get("values")?.jsonObject
            val metadataKeys=setOf("channel_set","audio_ref","normalization","weights","crossovers_hz","provenance")
            channelArtifacts?.keys?.filterNot {it in metadataKeys}?.forEach {name ->
                require(tiers.any {it.name==name && it.spectral!=null})
            }
            descriptors?.forEach {(band,value) ->
                val descriptor=value as? JsonObject
                val ref=descriptor?.get("artifact_ref")?.let(::text)
                val matched=if(ref==null)tiers.singleOrNull {it.name=="analysis" || channelSummary["sample_count"]?.let(::count)==it.minima.size} else tiers.singleOrNull {ref=="channels.${it.name}.$band"}
                require(matched?.spectral!=null)
            }
            channelSummary?.get("sample_count")?.let {declared ->
                val n=count(declared)
                require(tiers.any {it.minima.size==n && it.spectral!=null})
            }
        }
        fun markers(value:JsonElement?):List<Long> {
            if(value==null)return emptyList()
            val a=value.jsonArray;require(a.size<=100000)
            return a.map {it.jsonPrimitive.let {p ->require(!p.isString);p.long.also {v ->require(v in 0..durationMs)}}}.also {require(it.zipWithNext().all {(a,b)->a<b})}
        }
        // effective_timing is the server's projected override authority, not raw analysis guesses.
        val effective=body["effective_timing"] as? JsonObject
        val projection=effective ?: summary
        val grid=projection?.get("beat_grid") as? JsonObject
        val bpm=projection?.get("bpm") as? JsonObject
        val down=projection?.get("downbeats") as? JsonObject
        val beats=markers(grid?.get("beats_ms") ?: bpm?.get("beats_ms"))
        val downbeats=markers(down?.get("positions_ms"))
        val transients=markers((summary?.get("transients") as? JsonObject)?.get("strongest_ms"))
        val revision=listOf(body["schema_version"],body["updated_at"],body["override_revision"],body["override_updated_at"]).joinToString("|")+"|"+durationMs
        // Admission-time identity, never a frame-path JSON/hash operation. Revisions can be absent.
        val digest=java.security.MessageDigest.getInstance("SHA-256")
        fun identity(value:String){digest.update(value.toByteArray(Charsets.UTF_8));digest.update(0.toByte())}
        fun samples(values:FloatArray){for(value in values){val bits=value.toRawBits();for(shift in 0..24 step 8)digest.update((bits ushr shift).toByte())}}
        identity(revision);identity(status);if(effective==null&&(body["overrides"] as? JsonObject)?.get("manual_timing_v2")==null)identity(summary?.get("bpm").toString());identity(artifactBody?.get("source").toString());identity(effective.toString());identity(body["overrides"].toString());identity(beats.toString());identity(downbeats.toString())
        for(t in tiers){identity(t.name);samples(t.minima);samples(t.maxima);t.spectral?.let {identity(it.metadata.toString());samples(it.low);samples(it.mid);samples(it.high)}}
        val key=digest.digest().joinToString(""){"%02x".format(it)}
        val manual=(body["overrides"] as? JsonObject)?.get("manual_timing_v2") as? JsonObject
        val qualified=runCatching {
            require(manual!=null && manual["schema_version"]?.jsonPrimitive?.int==2 && manual["provenance"]?.jsonPrimitive?.content=="manual_override")
            val rev=manual["revision"]?.jsonPrimitive?.long ?: body.getValue("override_revision").jsonPrimitive.long
            require(rev>=0)
            val bpmValue=manual.getValue("bpm").jsonPrimitive;require(!bpmValue.isString)
            val anchor=manual.getValue("beat_anchor_ms").jsonPrimitive;require(!anchor.isString && anchor.long<=durationMs)
            TempoSourceTiming(key,"server:$rev","manual_timing_v2",bpmValue.double,anchor.long.toDouble())
        }.getOrNull()
        val phase=qualified?.let {timing->runCatching {
            PhaseGrid.manual(key,timing.revision,timing.sourceBpm.toString(),timing.beatAnchorMs.toLong(),null).copy(provenance=timing.provenance)
        }.getOrNull()}
        val suggested=(summary?.get("bpm") as? JsonObject)?.get("value")?.let {it as? JsonPrimitive}?.takeIf {!it.isString}?.doubleOrNull?.takeIf {it.isFinite()&&it in 10.0..600.0}
        return TrackWaveform(track,key,durationMs,tiers.sortedBy {it.minima.size},beats,downbeats,status,transients,phase,qualified,suggested)
    }
}
/** One byte-bounded LRU for source tiers and viewport min/max windows. No per-frame parsing. */
class WaveformCache(val maxBytes:Long=16L*1024*1024) {
    private val sources=LinkedHashMap<TrackId,TrackWaveform>(16,0.75f,true)
    private data class WindowKey(val track:TrackId,val source:String,val start:Long,val end:Long,val columns:Int)
    private val windows=LinkedHashMap<WindowKey,PeakWindow>(16,0.75f,true)
    @get:Synchronized val bytes:Long get()=sources.values.sumOf {it.bytes}+windows.values.sumOf {it.bytes}
    @Synchronized fun clear(){sources.clear();windows.clear()}
    @Synchronized fun put(waveform:TrackWaveform) {
        val old=sources.remove(waveform.track)
        if(old?.sourceKey!=waveform.sourceKey)windows.keys.removeAll {it.track==waveform.track}
        if(waveform.bytes<=maxBytes)sources[waveform.track]=waveform
        trim()
    }
    @Synchronized fun get(track:TrackId):TrackWaveform? = sources[track]
    private fun trim() {
        while(bytes>maxBytes&&windows.isNotEmpty())windows.remove(windows.keys.first())
        while(bytes>maxBytes&&sources.isNotEmpty()) {
            val track=sources.keys.first();sources.remove(track);windows.keys.removeAll {it.track==track}
        }
    }
    @Synchronized fun window(waveform:TrackWaveform,startMs:Long,endMs:Long,columns:Int):PeakWindow {
        require(startMs>=0&&endMs>startMs&&endMs<=waveform.durationMs&&columns in 1..8192)
        val key=WindowKey(waveform.track,waveform.sourceKey,startMs,endMs,columns)
        windows[key]?.let {return it}
        val target=ceil(columns.toDouble()*waveform.durationMs/(endMs-startMs)).toInt()
        val tier=waveform.tiers.firstOrNull {it.minima.size>=target} ?: waveform.tiers.lastOrNull()
        if(tier==null)return PeakWindow(startMs,endMs,floatArrayOf(),floatArrayOf())
        val n=tier.minima.size
        val first=floor(startMs.toDouble()*n/waveform.durationMs).toInt().coerceIn(0,n-1)
        val last=ceil(endMs.toDouble()*n/waveform.durationMs).toInt().coerceIn(first+1,n)
        val count=minOf(columns,last-first)
        val minima=FloatArray(count);val maxima=FloatArray(count)
        val bands=tier.spectral?.let {SpectralBands(FloatArray(count),FloatArray(count),FloatArray(count),it.metadata)}
        for(i in 0 until count) {
            val a=first+i*(last-first)/count
            val b=first+ceil((i+1).toDouble()*(last-first)/count).toInt()
            var lo=1f;var hi=-1f
            for(j in a until b){
                lo=minOf(lo,tier.minima[j]);hi=maxOf(hi,tier.maxima[j])
                if(bands!=null){
                    val source=tier.spectral
                    bands.low[i]=maxOf(bands.low[i],source.low[j])
                    bands.mid[i]=maxOf(bands.mid[i],source.mid[j])
                    bands.high[i]=maxOf(bands.high[i],source.high[j])
                }
            }
            minima[i]=lo;maxima[i]=hi
        }
        val coverage=WaveformBinCoverage(tier.name,n,first,last,waveform.durationMs)
        return PeakWindow(startMs,endMs,minima,maxima,bands,coverage).also {if(it.bytes<=maxBytes){windows[key]=it;trim()}}
    }
}
