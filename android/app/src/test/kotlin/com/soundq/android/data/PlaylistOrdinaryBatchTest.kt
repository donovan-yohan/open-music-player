package com.soundq.android.data

import com.soundq.android.data.playlists.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaylistOrdinaryBatchTest {
    @Test fun completeEditorChangesAllMetadataAndChecksExactReadback() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client); val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail()); detail.open(PlaylistId(41))
            val repository=PlaylistManagementRepository(api,detail); val actions=PlaylistManagementActions(repository){it()}
            val draft=PlaylistDraft("New", "Notes", "https://art.invalid/new", true)
            val summary=managementSummary(name="New").replace("Night listening","Notes").replace("https://art.example.invalid/cover","https://art.invalid/new").replace("\"isPublic\":false","\"isPublic\":true")
            f.reply(summary); f.reply(summary.dropLast(1)+",\"canManage\":true,\"tracks\":[{\"id\":9,\"title\":\"Member 9\"},{\"id\":7,\"title\":\"Member 7\"}]}")
            val target=actions.capture()!!
            actions.update(target,draft)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertEquals(draft,detail.state.value.detail!!.playlist.draft)
            actions.update(target,draft.copy(name="stale"))
            assertEquals(3,f.server.requestCount)
            val requests=(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","PUT","GET"),requests.map {it.method})
            assertEquals(draft, PlaylistJson.summary(Json.parseToJsonElement(summary).jsonObject).draft)
            assertEquals(PlaylistJson.draft(draft),Json.parseToJsonElement(requests[1].body!!.utf8()))
        }
    }
    @Test fun batchCancelIsInertAndConfirmationIsConsumedWithExactOrderedMembership() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail(ids=listOf(9,7,5)));detail.open(PlaylistId(41))
            val repository=PlaylistManagementRepository(api,detail);val jobs=ArrayDeque<()->Unit>()
            val actions=PlaylistManagementActions(repository){jobs.add(it)}; val target=actions.capture()!!
            assertNull(actions.askRemove(target,emptyList()))
            assertNull(actions.askRemove(target,listOf(TrackId(999))))
            assertNull(actions.askRemove(target,listOf(TrackId(7),TrackId(7))))
            val canceled=actions.askRemove(target,listOf(TrackId(7),TrackId(9)))!!
            actions.cancelRemove(canceled);actions.confirmRemove(canceled); assertTrue(jobs.isEmpty())
            val live=actions.askRemove(target,listOf(TrackId(7),TrackId(9)))!!
            f.reply(managementDetail(ids=listOf(5)))
            actions.confirmRemove(live);actions.confirmRemove(live)
            assertEquals(1,jobs.size);assertEquals(MutationOutcome.Pending,repository.state.value.outcome)
            jobs.removeFirst()()
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertEquals(listOf(TrackId(5)),detail.state.value.detail!!.tracks.map {it.id})
            assertNull(repository.state.value.undo)
            f.server.takeRequest(2,TimeUnit.SECONDS)
            val post=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("/api/v1/playlists/41/tracks/batch-remove",post.url.encodedPath)
            assertEquals("{\"trackIds\":[9,7]}",post.body!!.utf8())
        }
    }
    @Test fun lostBatchAckUsesGetOnlyAndDoesNotReplayCapturedRemoval() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val repository=PlaylistManagementRepository(api,detail);val actions=PlaylistManagementActions(repository){it()}
            val confirmation=actions.askRemove(actions.capture()!!,listOf(TrackId(9),TrackId(7)))!!
            f.reply("{}",503);actions.confirmRemove(confirmation)
            assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome)
            actions.confirmRemove(confirmation)
            f.reply(managementDetail(ids=emptyList()));actions.recover()
            assertTrue(repository.state.value.reconciled)
            assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome)
            assertEquals(emptyList<Track>(),detail.state.value.detail!!.tracks)
            assertEquals(listOf("GET","POST","GET"),(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun queuedBatchCannotDispatchAfterCloseOrSameIdDetailReplacement() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val repository=PlaylistManagementRepository(api,detail);val jobs=ArrayDeque<()->Unit>()
            val actions=PlaylistManagementActions(repository){jobs.add(it)}
            val c=actions.askRemove(actions.capture()!!,listOf(TrackId(9)))!!
            actions.confirmRemove(c);actions.close();jobs.removeFirst()()
            assertEquals(1,f.server.requestCount);assertEquals(MutationOutcome.Refused,repository.state.value.outcome)
            val next=PlaylistManagementActions(repository){jobs.add(it)}
            val c2=next.askRemove(next.capture()!!,listOf(TrackId(7)))!!
            f.reply(managementDetail());detail.open(PlaylistId(41))
            next.confirmRemove(c2);assertTrue(jobs.isEmpty());assertEquals(2,f.server.requestCount)
        }
    }
}
