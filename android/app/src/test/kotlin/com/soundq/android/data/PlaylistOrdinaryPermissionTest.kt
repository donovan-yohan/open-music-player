package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaylistOrdinaryPermissionTest {
    @Test fun explicitPrivateDenialAndMalformedPermissionCannotBorrowLegacyOwnerFallback() {
        for(permission in listOf("false","\"true\"","null","1")) HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail().dropLast(1)+",\"canManage\":$permission}")
            detail.open(PlaylistId(41))
            val repository=PlaylistManagementRepository(api,detail);val actions=PlaylistManagementActions(repository){it()}
            assertNull(actions.capture())
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun ownedPublicSingleRemovalAndCapturedUndoRequireFreshOwnerPermission() {
        HttpsFixture().use { f ->
            fun public(body:String)=body.replace("\"isPublic\":false","\"isPublic\":true").dropLast(1)+",\"canManage\":true}"
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(public(managementDetail()));detail.open(PlaylistId(41))
            val repository=PlaylistManagementRepository(api,detail);val actions=PlaylistManagementActions(repository){it()}
            f.reply(public(managementDetail(ids=listOf(7))));actions.remove(actions.capture()!!,TrackId(9))
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            val undo=actions.captureUndo()!!
            f.reply(public(managementDetail(ids=listOf(7))))
            f.reply("""{"added":[9],"skipped":[],"playlist":${managementSummary().replace("\"isPublic\":false","\"isPublic\":true")}}""")
            f.reply(public(managementDetail()));actions.undo(undo)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertEquals(listOf(TrackId(9),TrackId(7)),detail.state.value.detail!!.tracks.map {it.id})
            assertEquals(listOf("GET","POST","GET","POST","PUT"),(1..5).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun batchWrongRemainingOrderCannotPublishAndAccountReplacementCannotDispatch() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail(ids=listOf(9,7,5)));detail.open(PlaylistId(41))
            val before=detail.state.value.detail
            val repository=PlaylistManagementRepository(api,detail);val jobs=ArrayDeque<()->Unit>()
            val actions=PlaylistManagementActions(repository){jobs.add(it)}
            val confirmation=actions.askRemove(actions.capture()!!,listOf(TrackId(9)))!!
            f.reply(managementDetail(ids=listOf(5,7)));actions.confirmRemove(confirmation);jobs.removeFirst()()
            assertEquals(MutationOutcome.ReadbackFailed,repository.state.value.outcome)
            assertSame(before,detail.state.value.detail)
            f.reply(managementDetail(ids=listOf(7,5)));actions.recover();jobs.removeFirst()()
            val next=actions.askRemove(actions.capture()!!,listOf(TrackId(7)))!!
            actions.confirmRemove(next)
            api.session.accept(api.session.beginIntent(),SecretTokens("b","br","B"));jobs.removeFirst()()
            assertEquals(3,f.server.requestCount)
        }
    }
}
