package com.soundq.android.data

import com.soundq.android.data.playlists.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class PlaylistManagementBoundaryTest {
    private fun setup(f: HttpsFixture): Triple<AccountSession,PlaylistDetailRepository,PlaylistManagementRepository> {
        val session=playlistSession(f);val api=SoundQApi(session,f.client);val detail=PlaylistDetailRepository(api)
        f.reply(managementDetail());detail.open(PlaylistId(41))
        return Triple(session,detail,PlaylistManagementRepository(api,detail))
    }
    @Test fun oldRecoveryCallbackCannotSelectNewOperationOnSameRoute() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()}
            f.reply("{}",503);actions.rename(actions.capture()!!,"First")
            val oldRead=actions.recoveryAction()!!
            f.reply(managementDetail(name="First"));actions.recover()
            f.reply("{}",503);actions.rename(actions.capture()!!,"Second")
            val before=f.server.requestCount
            f.reply(managementDetail(name="Second"))
            oldRead()
            assertEquals(before,f.server.requestCount)
            assertEquals("First",detail.state.value.detail!!.playlist.name)
        }
    }
    @Test fun retainedRecoveryCallbackCannotRetryAfterSuccessfulReconciliationOrCaptureAnotherDestinationRead() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()}
            f.reply("{}",503);actions.rename(actions.capture()!!,"First")
            val oldRead=actions.recoveryAction()!!
            f.reply(managementDetail(name="First"));actions.recover()
            val before=f.server.requestCount
            f.reply(managementDetail(name="First"))
            oldRead()
            assertEquals(before,f.server.requestCount)
            assertEquals("First",detail.state.value.detail!!.playlist.name)
        }
    }
    @Test fun queuedRecoveryCannotDispatchAfterDetailSelectionChanges() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val jobs=mutableListOf<()->Unit>();val actions=PlaylistManagementActions(owner){jobs.add(it)}
            f.reply("{}",503);actions.rename(actions.capture()!!,"New");jobs.removeAt(0)()
            actions.recover()
            f.reply(managementDetail(id=42));detail.open(PlaylistId(42))
            val prior=detail.state.value.detail;val count=f.server.requestCount
            f.reply(managementDetail(name="New"));jobs.removeAt(0)()
            assertEquals(count,f.server.requestCount);assertSame(prior,detail.state.value.detail)
            assertFalse(owner.state.value.loading)
        }
    }
    @Test fun capturedUndoCannotMutateAfterSameDetailReopensButNewCaptureRetainsReceipt() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val jobs=mutableListOf<()->Unit>();val actions=PlaylistManagementActions(owner){jobs.add(it)}
            f.reply(managementDetail(ids=listOf(7)));actions.remove(actions.capture()!!,TrackId(9));jobs.removeAt(0)()
            val undo=actions.captureUndo()!!
            detail.retire();f.reply(managementDetail(ids=listOf(7)));detail.open(PlaylistId(41))
            actions.undo(undo)
            assertTrue(jobs.isEmpty())
            assertNotNull(actions.captureUndo())
        }
    }
    @Test fun uncertainRemovalKeepsMembersAndRecoveryNeverManufacturesUndoOrRepeatsRemoval() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()};val target=actions.capture()!!;val prior=detail.state.value.detail
            f.reply("{}",503);actions.remove(target,TrackId(9))
            assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome);assertSame(prior,detail.state.value.detail);assertNull(owner.state.value.undo)
            actions.remove(target,TrackId(9));assertEquals(2,f.server.requestCount)
            f.reply(managementDetail(ids=listOf(7)));actions.recover()
            assertTrue(owner.state.value.reconciled);assertNull(owner.state.value.undo)
            assertEquals(listOf(TrackId(7)),detail.state.value.detail!!.tracks.map {it.id})
            assertEquals(listOf("GET","POST","GET"),(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun malformedAndUncertainUndoAddMustNeverDispatchReorderOrAutomaticallyReplayAdd() {
        val responses=listOf("{}" to 200,"{}" to 503,
            """{"added":[9],"skipped":[9],"playlist":${managementSummary(ids=listOf(7,9))}}""" to 200)
        for((body,status) in responses) HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()}
            f.reply(managementDetail(ids=listOf(7)));actions.remove(actions.capture()!!,TrackId(9))
            val undo=actions.captureUndo()!!;val prior=detail.state.value.detail
            f.reply(managementDetail(ids=listOf(7)));f.reply(body,status);actions.undo(undo)
            assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome);assertSame(prior,detail.state.value.detail)
            assertEquals(4,f.server.requestCount);actions.undo(undo);assertEquals(4,f.server.requestCount)
            f.reply(managementDetail(ids=listOf(7,9)));actions.recover()
            assertNull(owner.state.value.undo);assertEquals(5,f.server.requestCount)
        }
    }
    @Test fun producerRefusedRenameCanBeExplicitlyRetriedWithFreshCaptureWithoutAuthRefresh() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()};val old=actions.capture()!!
            f.reply("{}",401);actions.rename(old,"New")
            assertEquals(MutationOutcome.Refused,owner.state.value.outcome);assertEquals(2,f.server.requestCount)
            actions.rename(old,"New");assertEquals(2,f.server.requestCount)
            f.reply(managementSummary(name="New"));f.reply(managementDetail(name="New"));actions.rename(actions.capture()!!,"New")
            assertEquals(MutationOutcome.Confirmed,owner.state.value.outcome);assertEquals("New",detail.state.value.detail!!.playlist.name)
        }
    }
    @Test fun heldRecoveryAccountReplacementCannotPublishIntoReplacementDetail() {
        HttpsFixture().use {f ->
            val (session,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()}
            f.reply("{}",503);actions.rename(actions.capture()!!,"New")
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(managementDetail(name="New")).build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val task=pool.submit{actions.recover()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                session.revoke();check(session.accept(session.beginIntent(),SecretTokens("other-a","other-r","other")))
                owner.retire();detail.retire();val replacement=owner.state.value
                release.countDown();task.get(5,TimeUnit.SECONDS)
                assertSame(replacement,owner.state.value);assertNull(detail.state.value.detail)
                assertEquals(3,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun malformedRenameAcksNeverGrantSuccessOrEraseAcknowledgedDetail() {
        val bodies=listOf("{}",managementSummary(id=42,name="New"),managementSummary(name="New").replace("false","true"),
            managementSummary(name="New").replace("\"New\"","null"),managementSummary(name="New").replace("\"Night listening\"","12"),
            managementSummary(name="New").replace("\"trackCount\":2","\"trackCount\":\"2\""))
        for(body in bodies) HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()};val prior=detail.state.value.detail
            f.reply(body);actions.rename(actions.capture()!!,"New")
            assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome);assertSame(prior,detail.state.value.detail)
            assertNull(actions.capture());assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun delete200Or202IsUncertainAnd404RecoveryDoesNotRepeatDelete() {
        for(status in listOf(200,202)) HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()};val prior=detail.state.value.detail
            val confirm=actions.askDelete(actions.capture()!!)!!;f.reply("{}",status);actions.confirmDelete(confirm)
            assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome);assertSame(prior,detail.state.value.detail)
            f.reply("{}",404);actions.recover()
            assertTrue(owner.state.value.reconciled);assertTrue(owner.state.value.missing);assertNull(detail.state.value.id)
            actions.confirmDelete(confirm);assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun acknowledgedRenameReadFailurePreservesPriorThenGetRecoveryPublishes() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()};val prior=detail.state.value.detail
            f.reply(managementSummary(name="New"));f.reply("{}",503);actions.rename(actions.capture()!!,"New")
            assertEquals(MutationOutcome.ReadbackFailed,owner.state.value.outcome);assertSame(prior,detail.state.value.detail)
            f.reply("{}",503);actions.recover();assertFalse(owner.state.value.loading);assertSame(prior,detail.state.value.detail)
            f.reply(managementDetail(name="New"));actions.recover()
            assertTrue(owner.state.value.reconciled);assertEquals("New",detail.state.value.detail!!.playlist.name)
            assertEquals(listOf("GET","PUT","GET","GET","GET"),(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun queuedWriteRecoveryAndCanceledDeleteCannotAcquireReplacementRouteAuthority() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val jobs=mutableListOf<()->Unit>();val actions=PlaylistManagementActions(owner){jobs.add(it)}
            val target=actions.capture()!!;val confirm=actions.askDelete(target)!!
            actions.rename(target,"New");actions.close();detail.retire()
            val replacement=PlaylistManagementActions(owner){jobs.add(it)}
            jobs.removeAt(0)();actions.confirmDelete(confirm)
            assertEquals(1,f.server.requestCount);assertEquals(MutationOutcome.Refused,owner.state.value.outcome)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            f.reply("{}",503);replacement.rename(replacement.capture()!!,"New");jobs.removeAt(0)()
            replacement.recover();replacement.close()
            PlaylistManagementActions(owner){it()};jobs.removeAt(0)()
            assertEquals(3,f.server.requestCount);assertFalse(owner.state.value.loading)
        }
    }
    @Test fun heldOldWriteCannotPublishOrReadBackAfterSamePlaylistReopens() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()};val target=actions.capture()!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.method=="PUT"){entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(managementSummary(name="New")).build()}
                return MockResponse.Builder().body(managementDetail()).build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val task=pool.submit{actions.rename(target,"New")};assertTrue(entered.await(3,TimeUnit.SECONDS))
                actions.close();detail.retire();val replacement=PlaylistManagementActions(owner){it()}
                detail.open(PlaylistId(41));val prior=detail.state.value.detail
                release.countDown();task.get(5,TimeUnit.SECONDS)
                assertSame(prior,detail.state.value.detail);assertEquals(3,f.server.requestCount)
                assertNull(replacement.capture());assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun accountAbaPermanentlyRefusesOldTargetsUndoAndReadCallbacks() {
        HttpsFixture().use {f ->
            val (session,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()};val old=actions.capture()!!
            val confirm=actions.askDelete(old)!!
            f.reply(managementDetail(ids=listOf(7)));actions.remove(old,TrackId(9));val undo=actions.captureUndo()!!
            session.revoke();check(session.accept(session.beginIntent(),SecretTokens("new-a","new-r","playlist-account-a")))
            actions.rename(old,"Wrong");actions.undo(undo);actions.confirmDelete(confirm);actions.recover()
            assertEquals(2,f.server.requestCount)
            owner.retire();detail.retire();assertNull(owner.state.value.undo)
        }
    }
    @Test fun partialUndoAddAcknowledgedThenReorderRefusedHasGetOnlyRecovery() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()}
            f.reply(managementDetail(ids=listOf(7)));actions.remove(actions.capture()!!,TrackId(9))
            val undo=actions.captureUndo()!!;val prior=detail.state.value.detail
            f.reply(managementDetail(ids=listOf(7)))
            f.reply("""{"added":[9],"skipped":[],"playlist":${managementSummary(ids=listOf(7,9))}}""")
            f.reply("{}",403);actions.undo(undo)
            assertEquals(MutationOutcome.ReadbackFailed,owner.state.value.outcome);assertSame(prior,detail.state.value.detail)
            actions.undo(undo);assertEquals(5,f.server.requestCount)
            f.reply(managementDetail(ids=listOf(7,9)));actions.recover()
            assertEquals(listOf(TrackId(7),TrackId(9)),detail.state.value.detail!!.tracks.map {it.id})
            assertNull(owner.state.value.undo);actions.undo(undo);assertEquals(6,f.server.requestCount)
        }
    }
    @Test fun ordinaryUndoPublishesRestoredMembersIntoOriginalMountedDetail() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()}
            f.reply(managementDetail(ids=listOf(7)));actions.remove(actions.capture()!!,TrackId(9))
            f.reply(managementDetail(ids=listOf(7)))
            f.reply("""{"added":[9],"skipped":[],"playlist":${managementSummary(ids=listOf(7,9))}}""")
            f.reply(managementDetail());actions.undo(actions.captureUndo()!!)
            assertEquals(listOf(TrackId(9),TrackId(7)),detail.state.value.detail!!.tracks.map {it.id})
        }
    }
    @Test fun malformedRemovalMemberScalarDoesNotBecomeAcknowledgedState() {
        HttpsFixture().use {f ->
            val (_,detail,owner)=setup(f);val actions=PlaylistManagementActions(owner){it()};val prior=detail.state.value.detail
            f.reply(managementDetail(ids=listOf(7)).replace("\"Member 7\"","null"));actions.remove(actions.capture()!!,TrackId(9))
            assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome);assertSame(prior,detail.state.value.detail)
        }
    }
}
