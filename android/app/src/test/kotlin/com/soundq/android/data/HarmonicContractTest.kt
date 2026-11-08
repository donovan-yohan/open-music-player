package com.soundq.android.data

import com.soundq.android.data.playlists.*
import com.soundq.android.data.harmonic.*
import com.soundq.android.data.preferences.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class HarmonicContractTest {
    private fun payload(name:String)=javaClass.getResource("/harmonic/$name.json")!!.readText()
    @Test fun realProducerSeedPrefersLaterFullPairAndRoundsOnlyDisplay() {
        val detail=PlaylistJson.detail(Json.parseToJsonElement(payload("playlist-seed")).jsonObject,PlaylistId(17))
        val seed=harmonicSeed(detail)
        assertEquals(TrackId(12),seed.track);assertEquals("125",seed.draft.bpm);assertEquals("8A",seed.draft.camelot)
        assertEquals(TrackId(12),seed.exclude)
        val partial=harmonicSeed(detail.copy(analysisSeeds=mapOf(TrackId(11) to PlaylistAnalysisSeed(124.4,"13Z"))))
        assertEquals("124",partial.draft.bpm);assertNull(partial.exclude);assertNull(partial.draft.query())
        val high=harmonicSeed(detail.copy(analysisSeeds=mapOf(TrackId(11) to PlaylistAnalysisSeed(301.0,"8A"))))
        assertEquals("301",high.draft.bpm);assertNull(high.draft.query())
    }
    @Test fun canonicalTlsGetUsesAbsoluteWindowHistoryChoiceAndActualProducerUnknownDuration() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val scope=api.session.capture()!!
            f.reply(payload("history"))
            val result=api.nearbyTracks(scope,HarmonicDraft("124"," 8a ").query()!!){true}
            assertTrue(result.orderedByHistory);assertEquals(listOf(11L,12L),result.tracks.map {it.id.value})
            assertEquals(214000L,result.tracks.first().durationMs);assertNull(result.tracks.last().durationMs)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("/api/v1/tracks/nearby",request.url.encodedPath);assertEquals("GET",request.method)
            assertEquals("history",request.url.queryParameter("order"));assertEquals("5.0",request.url.queryParameter("tolerance"));assertEquals("8A",request.url.queryParameter("camelot"))
            f.reply(payload("proximity"));assertFalse(api.nearbyTracks(scope,HarmonicDraft("124","8A",history=false).query()!!){true}.orderedByHistory)
            assertNull(f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.queryParameter("order"))
        }
    }
    @Test fun draftLimitsAndMalformedWireIdentityNeverBecomeDifferentValidValues() {
        for(text in listOf("0","-1","301","NaN","Infinity",""))assertNull(HarmonicDraft(text,"8A").query())
        for(text in listOf("-1","51","NaN","Infinity"))assertNull(HarmonicDraft("124","8A",text).query())
        for(text in listOf("0A","13A","01A","8Z","8"))assertNull(HarmonicDraft("124",text).query())
        assertNotNull(HarmonicDraft("300","12b","0").query());assertNotNull(HarmonicDraft(".1","1a","50").query())
        val raw=Json.parseToJsonElement("""{"tracks":[{"id":1.5,"title":"Bad"},{"id":2,"title":"Good","camelot":"13A","duration_ms":0},{"id":2,"title":"Good"}]}""").jsonObject
        val parsed=NearbyJson.parse(raw)
        assertEquals(listOf(2L,2L),parsed.tracks.map {it.id.value});assertNull(parsed.tracks.first().camelot);assertNull(parsed.tracks.first().durationMs)
    }
    @Test fun rejectedDjBytesAndFailedWriteNeverGrantNewGateOrOverwriteAcceptedChoice() {
        val dir=Files.createTempDirectory("harmonic-dj-rejected-").toFile()
        try {
            val file=dir.resolve("choice");val owner=DjModePreferences(file);owner.load()
            owner.setEnabled(owner.capture()!!,false){true}
            for(raw in listOf("broken","{\"version\":1,\"djMode\":\"true\"}","{\"version\":1,\"djMode\":true,\"extra\":0}"," ".repeat(4097))) {
                file.writeText(raw);owner.load();assertFalse(owner.enabled());assertNull(owner.capture());assertEquals(raw,file.readText())
            }
            file.delete();file.mkdir();owner.load();assertNull(owner.capture());assertTrue(file.isDirectory)
            val blocked=dir.resolve("blocked").also {it.writeText("preserve")}
            val failed=DjModePreferences(blocked.resolve("dj"));failed.load()
            assertFalse(failed.setEnabled(failed.capture()!!,false){true});assertTrue(failed.state.value.enabled)
            assertEquals(DjModeError.Write,failed.state.value.error);assertEquals("preserve",blocked.readText())
            blocked.delete();blocked.mkdir();assertTrue(failed.setEnabled(failed.capture()!!,false){true});assertFalse(failed.enabled())
        } finally {dir.deleteRecursively()}
    }
    @Test fun djModeIsStrictAcceptedLocalChoiceWithStaleExternalAndRejectedBytesPreserved() {
        val dir=Files.createTempDirectory("harmonic-dj-").toFile()
        try {
            val file=dir.resolve("dj.json");val prefs=DjModePreferences(file)
            assertFalse(prefs.enabled());prefs.load();assertTrue(prefs.enabled())
            val first=prefs.capture()!!;assertTrue(prefs.setEnabled(first,false){true});assertFalse(prefs.enabled())
            assertFalse(prefs.setEnabled(first,true){true})
            val restored=DjModePreferences(file);restored.load();assertFalse(restored.enabled());assertFalse(restored.state.value.enabled)
            val old=restored.capture()!!;val foreign="{\"version\":2,\"djMode\":true}";file.writeText(foreign)
            assertFalse(restored.setEnabled(old,true){true});assertEquals(foreign,file.readText());assertFalse(restored.enabled())
            restored.load();assertNull(restored.capture());assertEquals(foreign,file.readText())
        } finally {dir.deleteRecursively()}
    }
}
