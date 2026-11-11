package com.soundq.android.data

import com.soundq.android.data.playlists.*
import com.soundq.android.playback.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class PlaylistOrderSaveBoundaryTest {
    private fun projection(ids:List<Long> = listOf(9,7))=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,queue=ids.mapIndexed {i,id->QueueOccurrence("occ-$i",id,"Member $id","",false)})
    private fun rows(f:HttpsFixture) {f.reply("""{"data":[${managementSummary()}],"total":1,"limit":20,"offset":0}""")}
    @Test fun compositeCreateAddPartialKeepsDraftAndExactGetRecoveryNeverReplays() {
        HttpsFixture().use {f->
            val owner=QueuePlaylistRepository(SoundQApi(playlistSession(f),f.client));val actions=QueuePlaylistActions(owner,{it()},{projection()})
            assertTrue(actions.capture());val target=actions.newTarget(PlaylistDraft("Saved queue"))!!
            f.reply(managementSummary(name="Saved queue",ids=emptyList()).replace("Night listening","").replace("https://art.example.invalid/cover","").replace("24000","0"),201)
            f.reply("{}",403);actions.save(target)
            assertEquals(MutationOutcome.ReadbackFailed,owner.state.value.outcome)
            assertEquals("Saved queue",owner.state.value.draft!!.name);assertEquals(PlaylistId(41),owner.state.value.created!!.id)
            val oldRecovery=actions.recoveryAction()!!
            actions.close();val next=QueuePlaylistActions(owner,{it()},{projection(listOf(7))})
            assertFalse(next.capture());oldRecovery();assertEquals(2,f.server.requestCount)
            f.reply(managementDetail());next.recover()
            assertTrue(owner.state.value.reconciled);assertFalse(owner.state.value.loading)
            assertEquals(MutationOutcome.ReadbackFailed,owner.state.value.outcome);assertNull(owner.state.value.ack)
            next.save(target);assertEquals(3,f.server.requestCount)
            val methods=(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method}
            assertEquals(listOf("POST","POST","GET"),methods)
            assertTrue(next.startNew());assertTrue(next.capture());assertEquals(listOf(TrackId(7)),owner.state.value.snapshot!!.tracks)
        }
    }
    @Test fun unsupportedQueueRefusesEntireCaptureAndDoesNotDispatch() {
        HttpsFixture().use {f->
            val owner=QueuePlaylistRepository(SoundQApi(playlistSession(f),f.client))
            val a=QueuePlaylistActions(owner,{it()},{projection(listOf(0,-1))})
            assertFalse(a.capture());assertNull(a.newTarget(PlaylistDraft("No")));assertEquals(0,f.server.requestCount)
        }
    }
    @Test fun createUncertaintyRecoveryIsReadOnlyListAndRequiresExplicitNewCapture() {
        HttpsFixture().use {f->
            val owner=QueuePlaylistRepository(SoundQApi(playlistSession(f),f.client));val a=QueuePlaylistActions(owner,{it()},{projection()})
            a.capture();val target=a.newTarget(PlaylistDraft("Uncertain"))!!;f.reply("{}",503);a.save(target)
            assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome);a.save(target);assertEquals(1,f.server.requestCount)
            rows(f);a.recover();assertTrue(owner.state.value.reconciled);assertNull(owner.state.value.created)
            assertEquals(listOf("POST","GET"),(1..2).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun invalidAddAcksCannotGrantSuccess() {
        for(body in listOf("{}","""{"added":[9,7],"skipped":[9],"playlist":${managementSummary()}}""","""{"added":[7,9],"skipped":[],"playlist":${managementSummary()}}""","""{"added":[9,7],"skipped":[],"playlist":${managementSummary().replace("false","true")}}""")) HttpsFixture().use {f->
            val owner=QueuePlaylistRepository(SoundQApi(playlistSession(f),f.client));val a=QueuePlaylistActions(owner,{it()},{projection()})
            a.capture();rows(f);a.reload();val target=a.select(owner.state.value.rows.single())!!
            f.reply(body);a.save(target);assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome);assertNull(owner.state.value.ack)
            a.save(target);assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun queuedSaveAndRetainedTargetCannotAcquireReopenedOrAccountAbaAuthority() {
        HttpsFixture().use {f->
            val session=playlistSession(f);val owner=QueuePlaylistRepository(SoundQApi(session,f.client));val jobs=mutableListOf<()->Unit>();val a=QueuePlaylistActions(owner,{jobs.add(it)},{projection()})
            a.capture();rows(f);a.reload();jobs.removeAt(0)();val old=a.select(owner.state.value.rows.single())!!
            a.save(old);a.close();val next=QueuePlaylistActions(owner,{jobs.add(it)},{projection()});jobs.removeAt(0)()
            assertEquals(1,f.server.requestCount);assertEquals(MutationOutcome.Refused,owner.state.value.outcome);next.save(old);assertTrue(jobs.isEmpty())
            session.revoke();check(session.accept(session.beginIntent(),SecretTokens("synthetic-new-a","synthetic-new-r","playlist-account-a")))
            next.save(old);assertTrue(jobs.isEmpty())
        }
    }
    @Test fun dispatchedAddAckSurvivesRouteCloseButCreateCannotContinueAddAfterClose() {
        for(create in listOf(false,true)) HttpsFixture().use {f->
            val owner=QueuePlaylistRepository(SoundQApi(playlistSession(f),f.client));val a=QueuePlaylistActions(owner,{it()},{projection()});a.capture()
            val target=if(create)a.newTarget(PlaylistDraft("Created"))!! else {rows(f);a.reload();a.select(owner.state.value.rows.single())!!}
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS))
                return MockResponse.Builder().code(if(create)201 else 200).body(if(create)managementSummary(name="Created",ids=emptyList()).replace("Night listening","").replace("https://art.example.invalid/cover","").replace("24000","0") else """{"added":[9,7],"skipped":[],"playlist":${managementSummary()}}""").build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val task=pool.submit {a.save(target)};assertTrue(entered.await(3,TimeUnit.SECONDS));a.close();QueuePlaylistActions(owner,{it()},{projection()})
                release.countDown();task.get(5,TimeUnit.SECONDS)
                assertEquals(if(create)MutationOutcome.ReadbackFailed else MutationOutcome.Confirmed,owner.state.value.outcome)
                assertEquals(if(create)1 else 2,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun reorderQueuedCaptureRefusesAfterSameIdReopenAndAccountReplacement() {
        HttpsFixture().use {f->
            val session=playlistSession(f);val api=SoundQApi(session,f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val owner=PlaylistOrderRepository(api,detail);val jobs=mutableListOf<()->Unit>();val a=PlaylistOrderActions(owner){jobs.add(it)}
            val old=a.capture()!!
            assertTrue(a.move(old,TrackId(9),listOf(TrackId(9),TrackId(7)),1))
            detail.retire();f.reply(managementDetail());detail.open(PlaylistId(41));val replacement=detail.state.value
            jobs.removeAt(0)()
            assertEquals(2,f.server.requestCount);assertEquals(MutationOutcome.Refused,owner.state.value.outcome);assertSame(replacement,detail.state.value)
            assertFalse(a.move(old,TrackId(9),listOf(TrackId(9),TrackId(7)),1))
            val fresh=a.capture()!!
            session.revoke();check(session.accept(session.beginIntent(),SecretTokens("synthetic-new-a","synthetic-new-r","playlist-account-a")))
            assertFalse(a.move(fresh,TrackId(9),listOf(TrackId(9),TrackId(7)),1));assertTrue(jobs.isEmpty())
        }
    }
    @Test fun queuedOrderRecoverySettlesLoadingWithoutReadingReplacementDestination() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val owner=PlaylistOrderRepository(api,detail);val jobs=mutableListOf<()->Unit>();val a=PlaylistOrderActions(owner){jobs.add(it)}
            val target=a.capture()!!;a.move(target,TrackId(9),listOf(TrackId(9),TrackId(7)),1)
            f.reply("{}",503);jobs.removeAt(0)();assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome)
            val retained=a.recoveryAction()!!;retained();assertTrue(owner.state.value.loading)
            detail.retire();f.reply(managementDetail());detail.open(PlaylistId(41));val replacement=detail.state.value
            jobs.removeAt(0)()
            assertFalse(owner.state.value.loading);assertFalse(owner.state.value.reconciled);assertSame(replacement,detail.state.value)
            retained();assertTrue(jobs.isEmpty());assertEquals(3,f.server.requestCount)
            f.reply(managementDetail(ids=listOf(7,9)));a.recover();jobs.removeAt(0)()
            assertTrue(owner.state.value.reconciled);assertFalse(owner.state.value.loading)
            assertEquals(listOf("GET","PUT","GET","GET"),(1..4).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun reorderWrongOrderAckIsUncertainAndOnlyGetRecoveryPublishes() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val d=PlaylistDetailRepository(api);f.reply(managementDetail());d.open(PlaylistId(41))
            val owner=PlaylistOrderRepository(api,d);val a=PlaylistOrderActions(owner){it()};val t=a.capture()!!;val before=d.state.value.detail
            f.reply(managementDetail());a.move(t,TrackId(9),listOf(TrackId(9),TrackId(7)),1)
            assertEquals(MutationOutcome.Uncertain,owner.state.value.outcome);assertSame(before,d.state.value.detail);assertNull(a.capture())
            f.reply(managementDetail(ids=listOf(7,9)));a.recover()
            assertTrue(owner.state.value.reconciled);assertFalse(owner.state.value.loading);assertEquals(listOf(7L,9L),d.state.value.detail!!.tracks.map {it.id.value})
            assertEquals(listOf("GET","PUT","GET"),(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }
}
