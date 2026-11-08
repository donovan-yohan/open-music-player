package com.soundq.android.data.mix

import kotlinx.serialization.json.*
import java.util.UUID

/** Original JSON is retained. Unsupported authoring fields are refused, never normalized away. */
@ConsistentCopyVisibility
data class MixClip internal constructor(val json:JsonObject) {
    val id get()=MixJson.text(json,"clipId")
    val occurrence get()=MixJson.text(json,"queueItemId")
    val track get()=MixJson.number(json,"trackId")
    val sourceStart get()=MixJson.number(json,"sourceStartMs")
    val sourceEnd get()=MixJson.number(json,"sourceEndMs")
    val start get()=MixJson.number(json,"timelineStartMs")
    val end get()=Math.addExact(start,sourceEnd-sourceStart)
    val gain get()=json["gainDb"]?.jsonPrimitive?.double ?: 0.0
    val fadeIn get()=json["fadeInMs"]?.let {MixJson.number(json,"fadeInMs")} ?: 0L
    val fadeOut get()=json["fadeOutMs"]?.let {MixJson.number(json,"fadeOutMs")} ?: 0L
    val stems get()=json["stemEdits"] as? JsonObject
}
data class SavedMix(val id:String,val version:Long,val name:String,val clips:List<MixClip>) {
    init {require(UUID.fromString(id).toString()==id && version>0)}
    val duration get()=clips.maxOfOrNull {it.end} ?: 0L
    fun draft(name:String=this.name)=MixJson.draft(name,clips)
    /** Populated only from a successful root/clip decode, never from edited text. */
    internal fun verifyForNative() {draft();clips.forEach {MixJson.clip(it.json)}}
    fun playable()=clips.isNotEmpty() && clips.all {it.gain<=0 && (it.json["tempoPolicy"]?.jsonPrimitive?.content ?: "volumeOnly")=="volumeOnly"}
}
data class MixPage(val rows:List<SavedMix>,val total:Int,val offset:Int)
object MixJson {
    fun text(o:JsonObject,k:String)=o.getValue(k).jsonPrimitive.let {require(it.isString && it.content.isNotBlank() && it.content.length<=4096);it.content}
    fun number(o:JsonObject,k:String)=o.getValue(k).jsonPrimitive.let {require(!it.isString);it.long.also {v->require(v in 0..1_000_000_000_000L)}}
    private fun fields(o:JsonObject,allowed:Set<String>,required:Set<String>) {require(o.keys.all {it in allowed} && o.keys.containsAll(required) && o.values.none {it===JsonNull})}
    fun clip(o:JsonObject,response:Boolean=false):MixClip {
        val required=setOf("clipId","queueItemId","trackId","sourceStartMs","sourceEndMs","timelineStartMs")
        fields(o,required+setOf("gainDb","fadeInMs","fadeOutMs","pitchMode","tempoPolicy","stemEdits")+(if(response)setOf("timelineEndMs")else emptySet()),required)
        o["gainDb"]?.let {require(!it.jsonPrimitive.isString)}
        val c=MixClip(JsonObject(o.filterKeys {it!="timelineEndMs"}))
        require(c.id==c.id.trim() && c.occurrence==c.occurrence.trim() && c.track>0 && c.sourceEnd>c.sourceStart && c.gain.isFinite())
        require(c.fadeIn<=c.sourceEnd-c.sourceStart && c.fadeOut<=c.sourceEnd-c.sourceStart-c.fadeIn)
        if("timelineEndMs" in o)require(number(o,"timelineEndMs")==c.end)
        o["pitchMode"]?.let {require(it.jsonPrimitive.isString && it.jsonPrimitive.content in setOf("preserve","followTempo"))}
        o["tempoPolicy"]?.let {require(it.jsonPrimitive.isString && it.jsonPrimitive.content in setOf("volumeOnly","constantTempoLock"))}
        c.stems?.let(::stems)
        require("stemEdits" !in o || c.stems!=null)
        return c
    }
    private fun stems(o:JsonObject) {
        fields(o,setOf("schemaVersion","channelSet","stemModelVersion","sourceFileHash","beatGridRef","events"),setOf("schemaVersion","channelSet","stemModelVersion","sourceFileHash","events"))
        require(number(o,"schemaVersion")==1L)
        val hybrid=text(o,"channelSet")=="stems5-hybrid-v1"
        require(text(o,"channelSet") in setOf("stems5-hybrid-v1","stems4-demucs-v1"))
        require(text(o,"stemModelVersion")=="audio-separator-htdemucs-ft-4s-v1"+(if(hybrid)"+lr4-180" else ""))
        require(Regex("sha256:[0-9a-f]{64}").matches(text(o,"sourceFileHash")))
        o["beatGridRef"]?.jsonObject?.let {fields(it,setOf("analysisRef","analysisVersion"),setOf("analysisRef","analysisVersion"));text(it,"analysisRef");text(it,"analysisVersion")}
        val channels=if(hybrid)setOf("vocals","melody","bass","kick","perc")else setOf("vocals","drums","bass","other")
        val events=o.getValue("events").jsonArray;require(events.size<=2048)
        var previous:Pair<Long,String>?=null
        events.forEach {value ->
            val e=value.jsonObject
            fields(e,setOf("channel","atMs","gain","rampMs","beatIndex"),setOf("channel","atMs","gain","rampMs"))
            val at=number(e,"atMs");val ch=text(e,"channel");require(ch in channels)
            val g=e.getValue("gain").jsonPrimitive;require(!g.isString && g.double.isFinite() && g.double in 0.0..1.0)
            require(number(e,"rampMs") in 1..250);if("beatIndex" in e)number(e,"beatIndex")
            previous?.let {require(at>it.first || at==it.first && ch>it.second)};previous=at to ch
        }
    }
    fun draft(name:String,clips:List<MixClip>):JsonObject {
        require(name.isNotBlank() && name==name.trim() && name.toByteArray().size<=200 && clips.size<=1000)
        require(clips.map {it.id}.distinct().size==clips.size)
        require(clips.sumOf {it.stems?.getValue("events")?.jsonArray?.size ?: 0}<=4096)
        var depth=0
        clips.flatMap {listOf(it.start to 1,it.end to -1)}.sortedWith(compareBy<Pair<Long,Int>> {it.first}.thenBy {it.second}).forEach {depth+=it.second;require(depth<=4)}
        return buildJsonObject {put("schemaVersion",1);put("name",name);put("clips",JsonArray(clips.map {clip(it.json).json}))}.also {require(it.toString().toByteArray().size<=256*1024)}
    }
    fun saved(o:JsonObject):SavedMix {
        fields(o,setOf("id","schemaVersion","name","clips","summary","version","createdAt","updatedAt"),setOf("id","schemaVersion","name","clips","version","summary","createdAt","updatedAt"))
        require(number(o,"schemaVersion")==1L)
        val clips=o.getValue("clips").jsonArray.map {clip(it.jsonObject,true)}
        val result=SavedMix(text(o,"id"),number(o,"version"),text(o,"name"),clips)
        result.draft()
        val summary=o.getValue("summary").jsonObject
        fields(summary,setOf("clipCount","trackIds","durationMs"),setOf("clipCount","trackIds","durationMs"))
        require(number(summary,"clipCount")==clips.size.toLong() && number(summary,"durationMs")==result.duration)
        require(summary.getValue("trackIds").jsonArray.map {it.jsonPrimitive.long}.toSet()==clips.map {it.track}.toSet())
        java.time.Instant.parse(text(o,"createdAt"));java.time.Instant.parse(text(o,"updatedAt"))
        return result
    }
    fun page(o:JsonObject,offset:Int):MixPage {
        fields(o,setOf("data","total","limit","offset"),setOf("data","total","limit","offset"))
        require(number(o,"limit")==20L && number(o,"offset")==offset.toLong())
        val rows=o.getValue("data").jsonArray.map {saved(it.jsonObject)}
        val total=number(o,"total").toInt()
        require(rows.size<=20 && rows.map {it.id}.distinct().size==rows.size && total>=offset+rows.size)
        return MixPage(rows,total,offset)
    }
}
