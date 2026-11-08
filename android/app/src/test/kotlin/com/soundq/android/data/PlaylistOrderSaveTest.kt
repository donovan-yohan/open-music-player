package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaylistOrderSaveTest {
    @Test fun saveQueueFiltersUnsupportedPreservesRepeatsAndReportsOnlyRealAck() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client)
            val owner=QueuePlaylistRepository(api);val jobs=mutableListOf<()->Unit>()
            var visible=com.soundq.android.playback.PlaybackProjection(connection=com.soundq.android.playback.PlaybackProjection.Connection.Connected,
                queue=listOf(9L,0L,7L,9L).mapIndexed {i,id->com.soundq.android.playback.QueueOccurrence("occ-$i",id,"Member $id","",false)})
            val actions=QueuePlaylistActions(owner,{jobs.add(it)},{visible})
            assertTrue(actions.capture())
            f.reply("""{"data":[${managementSummary()}],"total":1,"limit":20,"offset":0}""")
            actions.reload();jobs.removeAt(0)()
            val target=actions.select(owner.state.value.rows.single())!!
            actions.save(target)
            visible=visible.copy(queue=visible.queue.reversed())
            f.reply("""{"added":[7],"skipped":[9,9],"playlist":${managementSummary()}}""")
            jobs.removeAt(0)()
            assertEquals(MutationOutcome.Confirmed,owner.state.value.outcome)
            assertEquals(listOf(TrackId(7)),owner.state.value.ack!!.added)
            assertEquals(listOf(TrackId(9),TrackId(9)),owner.state.value.ack!!.skipped)
            assertEquals(1,owner.state.value.snapshot!!.duplicateOccurrences)
            assertEquals(1,owner.state.value.snapshot!!.omittedOccurrences)
            assertEquals(listOf(9L,0L,7L,9L),owner.state.value.snapshot!!.occurrences.map {it.trackId})
            f.server.takeRequest(2,TimeUnit.SECONDS)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("POST",request.method);assertEquals("/api/v1/playlists/41/tracks",request.url.encodedPath)
            assertEquals("{\"trackIds\":[9,7,9]}",request.body!!.utf8())
            actions.save(target);assertTrue(jobs.isEmpty())
        }
    }
    @Test fun privateReorderInsertsReturnedOrderAndDoesNotOptimisticallyPublish() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client); val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail()); detail.open(PlaylistId(41))
            val owner=PlaylistOrderRepository(api,detail); val jobs=mutableListOf<()->Unit>()
            val actions=PlaylistOrderActions(owner){jobs.add(it)}
            val target=actions.capture()!!; val before=detail.state.value.detail
            actions.move(target,TrackId(9),listOf(TrackId(9),TrackId(7)),1)
            assertSame(before,detail.state.value.detail)
            f.reply(managementDetail(ids=listOf(7,9))); jobs.removeAt(0)()
            assertEquals(MutationOutcome.Confirmed,owner.state.value.outcome)
            assertEquals(listOf(7L,9L),detail.state.value.detail!!.tracks.map {it.id.value})
            f.server.takeRequest(2,TimeUnit.SECONDS)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("PUT",request.method); assertEquals("/api/v1/playlists/41/tracks/reorder",request.url.encodedPath)
            assertEquals("{\"trackId\":9,\"newPosition\":1}",request.body!!.utf8())
            actions.move(target,TrackId(9),listOf(TrackId(9),TrackId(7)),1);assertTrue(jobs.isEmpty())
        }
    }
}
