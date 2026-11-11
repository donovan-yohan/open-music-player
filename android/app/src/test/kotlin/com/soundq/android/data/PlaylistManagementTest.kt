package com.soundq.android.data

import com.soundq.android.data.playlists.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaylistManagementTest {
    @Test fun deleteRequiresLiveConfirmationCancelIsInertAndOnly204Acknowledges() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client); val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val owner=PlaylistManagementRepository(api,detail);val actions=PlaylistManagementActions(owner){it()}
            val target=actions.capture()!!;val canceled=actions.askDelete(target)!!
            actions.cancelDelete(canceled); actions.confirmDelete(canceled)
            assertEquals(1,f.server.requestCount);assertNotNull(detail.state.value.detail)
            val live=actions.askDelete(target)!!
            f.reply("{}",204)
            actions.confirmDelete(live)
            assertEquals(MutationOutcome.Confirmed,owner.state.value.outcome)
            assertNull(detail.state.value.id)
            actions.confirmDelete(live);assertEquals(2,f.server.requestCount)
            assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
            assertEquals("DELETE",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
        }
    }
    @Test fun uncertainRenameLocksOldWriteAndRecoveryOnlyGetsCapturedTarget() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val owner=PlaylistManagementRepository(api,detail);val actions=PlaylistManagementActions(owner){it()}
            val target=actions.capture()!!;val prior=detail.state.value.detail
            f.reply("{}",503);actions.rename(target,"Changed")
            assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome);assertSame(prior,detail.state.value.detail)
            actions.rename(target,"Changed");assertEquals(2,f.server.requestCount)
            f.reply(managementDetail(name="Changed"));actions.recover()
            assertTrue(owner.state.value.reconciled)
            assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome)
            assertEquals("Changed",detail.state.value.detail!!.playlist.name)
            assertNotNull(actions.capture())
            actions.rename(target,"Changed");assertEquals(3,f.server.requestCount)
            val methods=(1..f.server.requestCount).map { f.server.takeRequest(2,TimeUnit.SECONDS)!!.method }
            assertEquals(listOf("GET","PUT","GET"),methods)
        }
    }
    @Test fun removalAndCapturedUndoRestoreOriginalOrderInOriginalPlaylistAfterNavigation() {
        HttpsFixture().use { f ->
            val api = SoundQApi(playlistSession(f), f.client); val detail = PlaylistDetailRepository(api)
            f.reply(managementDetail()); detail.open(PlaylistId(41))
            val owner = PlaylistManagementRepository(api,detail)
            val actions = PlaylistManagementActions(owner) { it() }
            val target = actions.capture()!!
            f.reply(managementDetail(ids=listOf(7)))
            actions.remove(target, TrackId(9))
            assertEquals(MutationOutcome.Confirmed,owner.state.value.outcome)
            assertEquals(listOf(TrackId(7)),detail.state.value.detail!!.tracks.map { it.id })
            val receipt = owner.state.value.undo!!
            actions.close(); detail.retire()
            f.reply(managementDetail(id=42)); detail.open(PlaylistId(42))
            val replacement = detail.state.value.detail
            val next = PlaylistManagementActions(owner) { it() }
            val undo = next.captureUndo()!!
            f.reply(managementDetail(ids=listOf(7)))
            f.reply("""{"added":[9],"skipped":[],"playlist":${managementSummary(ids=listOf(7,9))}}""")
            f.reply(managementDetail())
            next.undo(undo)
            assertEquals(MutationOutcome.Confirmed,owner.state.value.outcome)
            assertNull(owner.state.value.undo)
            assertSame(replacement,detail.state.value.detail)
            val requests = (1..f.server.requestCount).map { f.server.takeRequest(2,TimeUnit.SECONDS)!! }
            assertEquals(listOf("GET","POST","GET","GET","POST","PUT"),requests.map { it.method })
            assertEquals("/api/v1/playlists/41/tracks/batch-remove",requests[1].url.encodedPath)
            assertEquals("{\"trackIds\":[9]}", requests[1].body!!.utf8())
            assertEquals("/api/v1/playlists/41/tracks",requests[4].url.encodedPath)
            assertEquals("/api/v1/playlists/41/tracks/reorder",requests[5].url.encodedPath)
            assertEquals("{\"trackId\":9,\"newPosition\":0}",requests[5].body!!.utf8())
            next.undo(undo); assertEquals(6,f.server.requestCount)
            assertEquals(PlaylistId(41),receipt.playlist.id)
        }
    }
    @Test fun renameThroughMountedActionAdapterPreservesCompletePutAndAcknowledgedRead() {
        HttpsFixture().use { f ->
            val api = SoundQApi(playlistSession(f), f.client)
            val detail = PlaylistDetailRepository(api)
            f.reply(managementDetail()); detail.open(PlaylistId(41))
            val owner = PlaylistManagementRepository(api, detail)
            val jobs = mutableListOf<() -> Unit>()
            val actions = PlaylistManagementActions(owner) { jobs.add(it) }
            val target = actions.capture()!!
            f.reply(managementSummary(name = "海辺 — renamed")); f.reply(managementDetail(name = "海辺 — renamed"))
            actions.rename(target, "海辺 — renamed")
            assertEquals(MutationOutcome.Pending, owner.state.value.outcome)
            assertEquals("海辺 — Étude", detail.state.value.detail!!.playlist.name)
            jobs.removeAt(0)()
            assertEquals(MutationOutcome.Confirmed, owner.state.value.outcome)
            assertEquals("海辺 — renamed", detail.state.value.detail!!.playlist.name)
            val requests = (1..f.server.requestCount).map { f.server.takeRequest(2, TimeUnit.SECONDS)!! }
            assertEquals(listOf("GET", "PUT", "GET"), requests.map { it.method })
            val put = requests[1]
            assertEquals("/api/v1/playlists/41", put.url.encodedPath)
            val body = Json.parseToJsonElement(put.body!!.utf8()).jsonObject
            assertEquals("Night listening", body.getValue("description").jsonPrimitive.content)
            assertEquals("https://art.example.invalid/cover", body.getValue("coverUrl").jsonPrimitive.content)
            assertFalse(body.getValue("isPublic").jsonPrimitive.boolean)
            assertEquals(setOf("name", "description", "coverUrl", "isPublic"), body.keys)
            actions.rename(target, "Old callback")
            assertTrue(jobs.isEmpty())
        }
    }
}
internal fun managementSummary(id: Long = 41, name: String = "海辺 — Étude", ids: List<Long> = listOf(9,7)): String =
    """{"id":$id,"name":"$name","description":"Night listening","coverUrl":"https://art.example.invalid/cover","isPublic":false,"trackCount":${ids.size},"durationMs":24000}"""
internal fun managementDetail(id: Long = 41, name: String = "海辺 — Étude", ids: List<Long> = listOf(9,7)): String =
    managementSummary(id,name,ids).dropLast(1) + ",\"tracks\":[" + ids.joinToString(",") { """{"id":$it,"title":"Member $it","durationMs":12000}""" } + "]}"
