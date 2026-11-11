package com.soundq.android.data

import com.soundq.android.data.playlists.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class HarmonicSeedPreservationTest {
    @Test fun actualPlaylistProducerAnalysisIsNotDiscardedAtDetailBoundary() {
        val raw=javaClass.getResource("/harmonic/playlist-seed.json")!!.readText()
        val original=PlaylistJson.detail(Json.parseToJsonElement(raw).jsonObject,PlaylistId(17))
        val changed=PlaylistJson.detail(Json.parseToJsonElement(raw.replace("125.2","129.2")).jsonObject,PlaylistId(17))
        assertNotEquals("Playlist detail must retain actual producer seed facts without a per-row fetch",original,changed)
        assertEquals(listOf(214000L,200000L),original.tracks.map {it.durationMs})
    }
}
