package com.soundq.android.playback

import kotlinx.serialization.json.*
import com.soundq.android.data.jam.JamOccurrence

data class SavedOccurrence(val occurrence:String,val track:Long,val title:String,val artist:String,val manual:Boolean,val localOnly:Boolean=false,val durationMs:Long=0,val origin:QueueOrigin=if(manual)QueueOrigin.Manual else QueueOrigin.Context,val jam:JamOccurrence?=null)
enum class SavedRepeatMode(val wireValue:String) { Off("off"), One("one"), All("all");
    companion object {fun fromWire(value:String)=entries.firstOrNull {it.wireValue==value} ?: Off}
}
/** Durable paused observation, never a command journal or second live playlist. */
data class QueueSnapshot(val endpoint:String,val account:String,val items:List<SavedOccurrence>,val selected:Int,val position:Long,val shuffleEnabled:Boolean=false,val loopMode:SavedRepeatMode=SavedRepeatMode.Off) {
    fun encode():String=buildJsonObject {
        put("version",1);put("endpoint",endpoint);put("account",account);put("selected",selected);put("position",position)
        put("shuffleEnabled",shuffleEnabled);put("loopMode",loopMode.wireValue)
        put("items",buildJsonArray {items.forEach {i ->add(buildJsonObject {put("occurrence",i.occurrence);put("track",i.track);put("title",i.title);put("artist",i.artist);put("manual",i.manual);put("localOnly",i.localOnly);put("durationMs",i.durationMs);put("origin",i.origin.name);i.jam?.let {put("jam",it.json())}})}})
    }.toString()
    companion object {
        fun decode(raw:String,endpoint:String,account:String):QueueSnapshot?=try {
            require(raw.length<=500_000 && raw.toByteArray(Charsets.UTF_8).size<=500_000)
            val b=Json.parseToJsonElement(raw).jsonObject
            require(b.getValue("version").jsonPrimitive.int==1&&b.getValue("endpoint").jsonPrimitive.content==endpoint&&b.getValue("account").jsonPrimitive.content==account)
            val items=b.getValue("items").jsonArray.map {e ->val i=e.jsonObject;SavedOccurrence(i.getValue("occurrence").jsonPrimitive.content,i.getValue("track").jsonPrimitive.long,i.getValue("title").jsonPrimitive.content,i.getValue("artist").jsonPrimitive.content,i.getValue("manual").jsonPrimitive.boolean,i["localOnly"]?.jsonPrimitive?.let {require(!it.isString);it.boolean} ?: false,i["durationMs"]?.jsonPrimitive?.let {require(!it.isString);it.long.also {n ->require(n in 0..604800000L)}} ?: 0,QueueOrigin.saved(i["origin"]?.jsonPrimitive?.let {require(it.isString);it.content},i.getValue("manual").jsonPrimitive.boolean),i["jam"]?.let {JamOccurrence.parse(it.jsonObject)})}
            val selected=b.getValue("selected").jsonPrimitive.int;val position=b.getValue("position").jsonPrimitive.long
            require(items.size<=500&&items.all {it.occurrence.isNotBlank()&&it.track>0}&&items.map {it.occurrence}.toSet().size==items.size&&position>=0&&(items.isEmpty()||selected in items.indices))
            val jamKeys=items.mapNotNull {it.jam?.admissionKey};require(jamKeys.distinct().size==jamKeys.size)
            val shuffle=b["shuffleEnabled"]?.jsonPrimitive?.let {require(!it.isString);it.boolean} ?: false
            val repeat=b["loopMode"]?.jsonPrimitive?.let {require(it.isString);SavedRepeatMode.fromWire(it.content)} ?: SavedRepeatMode.Off
            QueueSnapshot(endpoint,account,items,selected,position,shuffle,repeat)
        }catch(_:Exception){null}
    }
}
