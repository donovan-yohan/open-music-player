package com.soundq.android.playback

import kotlinx.serialization.json.*
import com.soundq.android.data.jam.JamOccurrence

data class SavedOccurrence(val occurrence:String,val track:Long,val title:String,val artist:String,val manual:Boolean,val localOnly:Boolean=false,val durationMs:Long=0,val origin:QueueOrigin=if(manual)QueueOrigin.Manual else QueueOrigin.Context,val jam:JamOccurrence?=null,val ref:PlaybackRef?=null)
enum class SavedRepeatMode(val wireValue:String) { Off("off"), One("one"), All("all");
    companion object {fun fromWire(value:String)=entries.firstOrNull {it.wireValue==value} ?: Off}
}
/** Durable paused observation, never a command journal or second live playlist. */
data class QueueSnapshot(val endpoint:String,val account:String,val items:List<SavedOccurrence>,val selected:Int,val position:Long,val shuffleEnabled:Boolean=false,val loopMode:SavedRepeatMode=SavedRepeatMode.Off) {
    fun reference(item:SavedOccurrence):PlaybackRef=item.ref ?: PlaybackRef.Server(endpoint,account,item.track)
    fun encode():String=buildJsonObject {
        put("version",3);put("endpoint",endpoint);put("account",account);put("selected",selected);put("position",position)
        put("shuffleEnabled",shuffleEnabled);put("loopMode",loopMode.wireValue)
        put("items",buildJsonArray {items.forEach {i ->add(buildJsonObject {put("occurrence",i.occurrence);put("track",i.track);put("title",i.title);put("artist",i.artist);put("manual",i.manual);put("localOnly",i.localOnly);put("durationMs",i.durationMs);put("origin",i.origin.name);i.jam?.let {put("jam",it.json())};put("ref",(i.ref ?: PlaybackRef.Server(endpoint,account,i.track)).json())})}})
    }.toString()
    companion object {
        fun decode(raw:String,endpoint:String,account:String):QueueSnapshot?=try {
            require(raw.length<=500_000 && raw.toByteArray(Charsets.UTF_8).size<=500_000)
            val b=Json.parseToJsonElement(raw).jsonObject
            val version=b.getValue("version").jsonPrimitive.int;require(version in setOf(1,3)&&b.getValue("endpoint").jsonPrimitive.content==endpoint&&b.getValue("account").jsonPrimitive.content==account)
            val items=b.getValue("items").jsonArray.map {e ->val i=e.jsonObject;SavedOccurrence(i.getValue("occurrence").jsonPrimitive.content,i.getValue("track").jsonPrimitive.long,i.getValue("title").jsonPrimitive.content,i.getValue("artist").jsonPrimitive.content,i.getValue("manual").jsonPrimitive.boolean,i["localOnly"]?.jsonPrimitive?.let {require(!it.isString);it.boolean} ?: false,i["durationMs"]?.jsonPrimitive?.let {require(!it.isString);it.long.also {n ->require(n in 0..604800000L)}} ?: 0,QueueOrigin.saved(i["origin"]?.jsonPrimitive?.let {require(it.isString);it.content},i.getValue("manual").jsonPrimitive.boolean),i["jam"]?.let {JamOccurrence.parse(it.jsonObject)},if(version==3)PlaybackRef.parse(i.getValue("ref").jsonObject)else PlaybackRef.Server(endpoint,account,i.getValue("track").jsonPrimitive.long))}
            val selected=b.getValue("selected").jsonPrimitive.int;val position=b.getValue("position").jsonPrimitive.long
            require(items.size<=500&&items.all {it.occurrence.isNotBlank()&&when(val r=it.ref){is PlaybackRef.Device->it.track==0L&&it.localOnly&&it.jam==null;is PlaybackRef.Server->it.track==r.id&&r.endpoint==endpoint&&r.account==account;null->false}}&&items.map {it.occurrence}.toSet().size==items.size&&position>=0&&(items.isEmpty()||selected in items.indices))
            val jamKeys=items.mapNotNull {it.jam?.admissionKey};require(jamKeys.distinct().size==jamKeys.size)
            val shuffle=b["shuffleEnabled"]?.jsonPrimitive?.let {require(!it.isString);it.boolean} ?: false
            val repeat=b["loopMode"]?.jsonPrimitive?.let {require(it.isString);SavedRepeatMode.fromWire(it.content)} ?: SavedRepeatMode.Off
            QueueSnapshot(endpoint,account,items.map {if(it.ref is PlaybackRef.Server)it.copy(ref=null)else it},selected,position,shuffle,repeat)
        }catch(_:Exception){null}
    }
}
