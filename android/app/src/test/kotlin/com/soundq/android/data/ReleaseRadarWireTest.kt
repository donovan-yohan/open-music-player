package com.soundq.android.data

import com.soundq.android.data.discovery.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class ReleaseRadarWireTest {
 @Test fun actualGoWireAndMalformedControls() {
  val path=System.getProperty("soundq.radar.wire")
  val body=Json.parseToJsonElement(if(path==null)javaClass.getResource("/release-radar-wire.json")!!.readText() else File(path).readText()).jsonObject
  val page=RadarJson.page(body)
  assertEquals("Synthetic newest song",page.songs.single().title)
  assertEquals("2026-11-12",page.songs.single().firstRelease.raw)
  assertFalse(page.coverage.partial)
  for ((key,value) in listOf("policyVersion" to JsonPrimitive("old"),"calendarZone" to JsonPrimitive("local"),"items" to JsonArray(List(21){body.getValue("items").jsonArray.single()}))) {
   try {RadarJson.page(JsonObject(body+mapOf(key to value)));fail("malformed $key admitted")}catch(_:SafeFailure){}
  }
 }
}
