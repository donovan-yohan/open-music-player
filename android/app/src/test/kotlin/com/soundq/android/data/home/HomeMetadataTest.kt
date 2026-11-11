package com.soundq.android.data.home

import com.soundq.android.data.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/** Scalar policy is the Go wire contract, exercised through the mounted feature's real repository. */
class HomeMetadataTest {
    private val json=Json
    private val track=json.parseToJsonElement("""{"id":7,"title":"夜の音 🎵","inLibrary":true}""").jsonObject
    private val event=json.parseToJsonElement("""{"id":21,"playedAt":"2026-10-28T00:00:00.123456789Z","contextType":"queue","contextId":"音楽-1","skipped":true}""").jsonObject
    private fun changed(base:JsonObject,key:String,value:JsonElement?)=JsonObject(base.toMutableMap().apply {if(value==null)remove(key) else put(key,value)})
    private fun response(section:HomeSection,row:JsonObject,metadata:JsonObject=event):String =
        if(section==HomeSection.History) buildJsonObject {
            put("plays",buildJsonArray {add(JsonObject(metadata+mapOf("track" to row))) });put("limit",50);put("offset",0)
        }.toString() else buildJsonObject {put("tracks",buildJsonArray {add(row)})}.toString()
    private fun invalid(cases:List<Pair<String,JsonObject>>,history:Boolean=false) {
        val failures=mutableListOf<String>()
        val sections=if(history)listOf(HomeSection.History) else HomeSection.entries
        for(section in sections) HttpsFixture().use { f ->
            val s=AccountSession(f.endpoint,MemoryStore());assertTrue(s.accept(s.beginIntent(),SecretTokens("a","r","fixture")))
            val repo=HomeFeedRepository(s,SoundQApi(s,f.client))
            val route=HomeRouteLifetime().enter(if(section==HomeSection.History)HomeDestination.History else HomeDestination.Home)
            f.reply(response(section,track));repo.load(route,section)
            fun rows():Any=when(section){HomeSection.Recent->repo.recent.value.rows;HomeSection.Top->repo.top.value.rows;HomeSection.History->repo.history.value.rows}
            for((name,bad) in cases) {
                // Re-seed every case so one accepted malformed response cannot taint the next control.
                f.reply(response(section,track));repo.load(route,section)
                val acknowledged=rows()
                val acceptedTracks=if(section==HomeSection.History)repo.history.value.rows.map {it.entry.track}
                    else (if(section==HomeSection.Recent)repo.recent.value.rows else repo.top.value.rows).map {it.track}
                f.reply(if(history)response(section,track,bad) else response(section,bad));repo.load(route,section)
                val error=when(section){HomeSection.Recent->repo.recent.value.error;HomeSection.Top->repo.top.value.error;HomeSection.History->repo.history.value.error}
                if(error!=SafeFailure.Reason.InvalidResponse || rows()!==acknowledged) failures.add("$section/$name error=$error retained=${rows()===acknowledged}")
                val playable=if(section==HomeSection.History)repo.history.value.rows.map {it.entry to it.id}
                    else (if(section==HomeSection.Recent)repo.recent.value.rows else repo.top.value.rows).map {it to null}
                for((entry,eventId) in playable)repo.playAction(route,section,rows(),entry,eventId,play={tracks,_->
                    if(tracks.any {t->acceptedTracks.none {it===t}})failures.add("$section/$name newly accepted malformed playback")
                })()
            }
            assertEquals(1+2*cases.size,f.server.requestCount)
        }
        assertTrue("Malformed responses accepted: $failures",failures.isEmpty())
    }
    private val nonStrings=listOf(JsonNull,JsonPrimitive(true),JsonPrimitive(7),JsonObject(emptyMap()),JsonArray(emptyList()))
    @Test fun requiredTitleNeverStringifiesOtherScalarKinds() = invalid(nonStrings.map {"title=$it" to changed(track,"title",it)}+listOf("missing title" to changed(track,"title",null)))
    @Test fun presentOptionalTextCannotSilentlyBecomeEmptyOrCoerced() = invalid(listOf("artist","album","artworkUrl","coverArtUrl").flatMap {key->nonStrings.map {"$key=$it" to changed(track,key,it)}}+
        listOf("invalid fallback even when primary present" to JsonObject(track+mapOf("artworkUrl" to JsonPrimitive("https://media.invalid/art"),"coverArtUrl" to JsonPrimitive(false)))))
    @Test fun presentDurationMustBeNonnegativeNumericInteger() = invalid(listOf(JsonNull,JsonPrimitive("12000"),JsonPrimitive(true),JsonPrimitive(1.5),JsonPrimitive(-1),JsonPrimitive("bad"),JsonObject(emptyMap()),json.parseToJsonElement("9223372036854775808")).map {"duration=$it" to changed(track,"durationMs",it)})
    @Test fun trackIdentityMustBeNumericNotQuoted() = invalid(listOf(JsonPrimitive("7"),JsonNull,JsonPrimitive(true),JsonPrimitive(0),JsonPrimitive(1.5)).map {"id=$it" to changed(track,"id",it)})
    @Test fun historyEventMetadataRetainsActualGoKinds() = invalid(
        listOf("contextType","contextId").flatMap {key->nonStrings.map {"$key=$it" to changed(event,key,it)}}+
            listOf("id" to JsonPrimitive("21"),"playedAt" to JsonNull,"playedAt" to JsonPrimitive(7),"playedAt" to JsonPrimitive("not-time"),"skipped" to JsonPrimitive("true"),"skipped" to JsonNull).map {(key,value)->"$key=$value" to changed(event,key,value)},history=true)
    @Test fun historyPagingNumbersCannotBeQuoted() {
        HttpsFixture().use { f ->
            val s=AccountSession(f.endpoint,MemoryStore());s.accept(s.beginIntent(),SecretTokens("a","r","fixture"))
            val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.History)
            f.reply(response(HomeSection.History,track));repo.load(route,HomeSection.History);val rows=repo.history.value.rows
            val failures=mutableListOf<String>()
            for(key in listOf("limit","offset")) {
                val body=json.parseToJsonElement(response(HomeSection.History,track)).jsonObject
                f.reply(changed(body,key,JsonPrimitive(if(key=="limit")"50" else "0")).toString());repo.load(route,HomeSection.History)
                if(repo.history.value.error!=SafeFailure.Reason.InvalidResponse || repo.history.value.rows!==rows)failures.add(key)
            }
            assertTrue("Quoted paging accepted: $failures",failures.isEmpty())
        }
    }
    @Test fun validUnicodeOmittedOptionalsAndAbsentEligibilityRemainPlayable() {
        for(section in HomeSection.entries) HttpsFixture().use { f ->
            val s=AccountSession(f.endpoint,MemoryStore());s.accept(s.beginIntent(),SecretTokens("a","r","fixture"))
            val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(if(section==HomeSection.History)HomeDestination.History else HomeDestination.Home)
            for(row in listOf(changed(track,"inLibrary",null),JsonObject(track+mapOf("artist" to JsonPrimitive("芸術家"),"album" to JsonPrimitive("夏"),"durationMs" to JsonPrimitive(12000),"artworkUrl" to JsonPrimitive("https://media.invalid/art"))))) {
                f.reply(response(section,row));repo.load(route,section)
                val entries=when(section){HomeSection.Recent->repo.recent.value.rows;HomeSection.Top->repo.top.value.rows;HomeSection.History->repo.history.value.rows.map {it.entry}}
                val accepted=entries.single();assertEquals("夜の音 🎵",accepted.track.title);assertTrue(accepted.eligible)
                assertEquals(if(row.containsKey("durationMs"))12000L else 0L,accepted.track.durationMs)
                val expected:Any=if(section==HomeSection.History)repo.history.value.rows else entries
                var played=false;repo.playAction(route,section,expected,accepted,21,play={t,i->assertEquals(listOf(7L),t.map {it.id.value});assertEquals(0,i);played=true})();assertTrue(played)
                if(section==HomeSection.History){val e=repo.history.value.rows.single();assertEquals(21L,e.id);assertEquals(Instant.parse("2026-10-28T00:00:00.123456789Z"),e.playedAt);assertEquals("queue",e.contextType);assertEquals("音楽-1",e.contextId);assertTrue(e.skipped)}
            }
        }
    }
}
