package com.soundq.android.playback

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class QueueModesSnapshotTest {
    private val endpoint="https://fixture.invalid/api/v1"
    private val snapshot=QueueSnapshot(endpoint,"A",listOf(
        SavedOccurrence("context",7,"Context","Fixture",false,false,1000,QueueOrigin.Context),
        SavedOccurrence("manual",7,"Manual","Fixture",true,true,2000,QueueOrigin.Manual),
        SavedOccurrence("continuation",8,"Continuation","Fixture",false,false,3000,QueueOrigin.Continuation)
    ),1,2300)
    private fun wire(vararg fields:Pair<String,JsonElement?>):String=buildJsonObject {
        Json.parseToJsonElement(snapshot.encode()).jsonObject.forEach {(k,v)->if(k !in fields.map {it.first})put(k,v)}
        fields.forEach {(k,v)->if(v!=null)put(k,v)}
    }.toString()
    @Test fun enabledShuffleAndEveryStableRepeatTokenRoundTripWithOccurrenceMetadata() {
        for((mode,token) in listOf(SavedRepeatMode.Off to "off",SavedRepeatMode.One to "one",SavedRepeatMode.All to "all")) {
            val value=snapshot.copy(shuffleEnabled=true,loopMode=mode)
            val raw=value.encode();assertEquals(value,QueueSnapshot.decode(raw,endpoint,"A"))
            assertEquals(token,Json.parseToJsonElement(raw).jsonObject["loopMode"]!!.jsonPrimitive.content)
            assertFalse(raw.contains("playWhenReady"));assertFalse(raw.contains("signature"));assertFalse(raw.contains("soundq://"))
        }
    }
    @Test fun legacyModesDefaultDisabledAndUnknownStringRepeatDefaultsOff() {
        val legacy=QueueSnapshot.decode(wire("shuffleEnabled" to null,"loopMode" to null),endpoint,"A")!!
        assertFalse(legacy.shuffleEnabled);assertEquals(SavedRepeatMode.Off,legacy.loopMode);assertEquals(snapshot.items,legacy.items)
        assertEquals(SavedRepeatMode.Off,QueueSnapshot.decode(wire("loopMode" to JsonPrimitive("future")),endpoint,"A")!!.loopMode)
    }
    @Test fun explicitMalformedModeTypesRejectInsteadOfCoercingOrRewriting() {
        for(v in listOf(JsonPrimitive("true"),JsonPrimitive(1),JsonNull,buildJsonObject {},buildJsonArray {}))assertNull(QueueSnapshot.decode(wire("shuffleEnabled" to v),endpoint,"A"))
        for(v in listOf(JsonPrimitive(true),JsonPrimitive(2),JsonNull,buildJsonObject {},buildJsonArray {}))assertNull(QueueSnapshot.decode(wire("loopMode" to v),endpoint,"A"))
    }
    @Test fun modesDoNotRelaxScopeFutureVersionOrBodyAndOccurrenceBounds() {
        val raw=snapshot.copy(shuffleEnabled=true,loopMode=SavedRepeatMode.All).encode()
        assertNull(QueueSnapshot.decode(raw,endpoint,"B"));assertNull(QueueSnapshot.decode(raw,"https://other.invalid/api/v1","A"))
        assertNull(QueueSnapshot.decode(wire("version" to JsonPrimitive(2)),endpoint,"A"))
        assertNull(QueueSnapshot.decode(raw+" ".repeat(500_001),endpoint,"A"))
        assertNull(QueueSnapshot.decode(snapshot.copy(items=List(501){snapshot.items[0].copy(occurrence="o$it")}).encode(),endpoint,"A"))
        assertNull(QueueSnapshot.decode(snapshot.copy(items=listOf(snapshot.items[0],snapshot.items[0])).encode(),endpoint,"A"))
    }
}
