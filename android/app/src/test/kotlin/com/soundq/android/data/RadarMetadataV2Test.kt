package com.soundq.android.data

import com.soundq.android.data.discovery.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class RadarMetadataV2Test {
 private fun fixture():JsonObject {
  val path=System.getProperty("soundq.radar.wire")
  return Json.parseToJsonElement(if(path==null)javaClass.getResource("/release-radar-wire.json")!!.readText() else File(path).readText()).jsonObject
 }
 private fun page(version:String,reverse:Boolean=false):JsonObject {
  val base=fixture();val one=base.getValue("items").jsonArray.single().jsonObject
  val two=JsonObject(one+mapOf("recordingMbid" to JsonPrimitive("44444444-4444-4444-8444-444444444444")))
  val rows=listOf(one,two).let {if(reverse)it.reversed()else it}
  val coverage=base.getValue("coverage").jsonObject+mapOf("returned" to JsonPrimitive(2),"retrieved" to JsonPrimitive(2),"deduped" to JsonPrimitive(2),"knownTotal" to JsonPrimitive(2))
  return JsonObject(base+mapOf("policyVersion" to JsonPrimitive(version),"items" to JsonArray(rows),"coverage" to JsonObject(coverage)))
 }
 @Test fun v2MaintainsServerOrderWhileV1RemainsStrict() {
  val v2=RadarJson.page(page("recording-radar-v2",true))
  assertEquals("44444444-4444-4444-8444-444444444444",v2.songs.first().recording.value)
  assertEquals(2,RadarJson.page(page("recording-radar-v1")).songs.size)
  try {RadarJson.page(page("recording-radar-v1",true));fail("reordered v1 admitted")}catch(_:SafeFailure){}
 }
 @Test fun optionalAssociationMetadataNeverRemovesAnEligibleSong() {
  val group="48140466-cff6-3222-bd55-63c27e43190d";val edition="76df3287-6cda-33eb-8e9a-044b5e15ffdd"
  for(version in listOf("recording-radar-v1","recording-radar-v2")) {
   val base=page(version);val rows=base.getValue("items").jsonArray
   fun song(g:JsonElement?,e:JsonElement?):RadarSong {
    val row=JsonObject(rows[0].jsonObject+buildMap<String,JsonElement>{g?.let {put("releaseGroupMbid",it)};e?.let {put("releaseMbid",it)}})
    return RadarJson.page(JsonObject(base+mapOf("items" to JsonArray(listOf(row,rows[1]))))).songs.first()
   }
   assertEquals("https://coverartarchive.org/release-group/$group/front-250",song(JsonPrimitive(group),JsonPrimitive(edition)).artwork!!.entryUrl)
   assertEquals("https://coverartarchive.org/release/$edition/front-250",song(null,JsonPrimitive(edition)).artwork!!.entryUrl)
   assertNull(song(null,null).artwork)
   for(bad in listOf(JsonNull,JsonPrimitive(1),JsonObject(emptyMap()),JsonPrimitive("00000000-0000-0000-0000-000000000000"),JsonPrimitive(group.uppercase()),JsonPrimitive("https://evil.test/image"))) {
    val s=song(bad,bad);assertNull(s.artwork);assertEquals(rows[0].jsonObject.getValue("recordingMbid").jsonPrimitive.content,s.recording.value)
    assertTrue(song(bad,JsonPrimitive(edition)).artwork is CaaArtworkRef.Edition)
   }
  }
 }
 @Test fun v2DoesNotRelaxIdentityCoverageOrBounds() {
  val v2=page("recording-radar-v2");val rows=v2.getValue("items").jsonArray
  for(bad in listOf(JsonObject(v2+mapOf("items" to JsonArray(listOf(rows[0],rows[0])))),JsonObject(v2+mapOf("coverage" to JsonObject(v2.getValue("coverage").jsonObject+mapOf("returned" to JsonPrimitive(1))))))) {
   try {RadarJson.page(bad);fail("malformed v2 admitted")}catch(_:SafeFailure){}
  }
 }
}
