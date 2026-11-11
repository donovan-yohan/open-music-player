package com.soundq.android.data

import com.soundq.android.data.playlists.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class PlaylistMembershipBoundaryTest {
    private class Harness(val f: HttpsFixture) {
        val session = playlistSession(f)
        val api = SoundQApi(session, f.client)
        val library = LibraryRepository(session, api::library, api::like)
        val repository = PlaylistMembershipRepository(api, library)
        val queue = ArrayDeque<() -> Unit>()
        val route = LibraryPlaylistActions(repository) { queue.add(it) }
        init { f.reply(membershipLibrary()); library.refine(LibraryQuery(text="海", liked=true)) }
        fun open(): MembershipPickerActions = route.open(library.captureTrack(library.state.value.rows.single())!!)!!
        fun ready(): MembershipPickerActions = open().also { f.reply(playlistPage()); it.reload(); drain() }
        fun drain() { while(queue.isNotEmpty()) queue.removeFirst().invoke() }
        fun submit(p: MembershipPickerActions): MembershipSubmit = p.select(repository.state.value.rows.single())!!.also(p::submit)
    }
    @Test fun duplicateAckKeepsSkippedIdentityAndReadsActualMembership() {
        HttpsFixture().use { f ->
            val h=Harness(f);val p=h.ready();val before=h.library.state.value
            f.reply(membershipAck(true));f.reply(membershipDetail());f.reply(membershipPage())
            val submit=h.submit(p);h.drain();p.submit(submit);h.drain()
            assertEquals(MutationOutcome.Confirmed,h.repository.state.value.outcome)
            assertEquals(listOf(TrackId(7)),h.repository.state.value.ack!!.skipped)
            assertTrue(h.repository.state.value.ack!!.added.isEmpty())
            assertSame(before,h.library.state.value)
            assertEquals(5,f.server.requestCount)
        }
    }
    @Test fun malformedAndWrongIdentityAcknowledgementsStayUncertain() {
        val valid=membershipAck()
        val cases=listOf(
            valid.replace("[7]","[99]"),valid.replace("[7]","[\"7\"]"),valid.replace("[7]","[true]"),
            valid.replace("[7]","[7,7]"),valid.replace("[7]","[]"),valid.replace("\"skipped\":[],", ""),
            valid.replace("\"skipped\":[]", "\"skipped\":[7]"),membershipAck(id=99),
            valid.replace("\"name\":\"海辺 — Étude\"","\"name\":123"),valid.replace("\"isPublic\":false","\"isPublic\":\"false\""),
            valid.replace("\"trackCount\":1","\"trackCount\":0"),"{}")
        for(body in cases) HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();f.reply(body);val submit=h.submit(p);h.drain()
            assertEquals(body,MutationOutcome.Uncertain,h.repository.state.value.outcome)
            assertNull(h.repository.state.value.ack)
            p.submit(submit);h.drain();assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun exact200RequiredAndRefusalNeverRefreshesOrReposts() {
        for(code in listOf(201,202,204,400,401,403,404,500,503)) HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();f.reply(membershipAck(),code);val submit=h.submit(p);h.drain()
            assertEquals("status=$code",if(code in listOf(400,401,403,404))MutationOutcome.Refused else MutationOutcome.Uncertain,h.repository.state.value.outcome)
            assertNull(h.repository.state.value.ack);p.submit(submit);h.drain();assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun knownAckSurvivesFailedReadbackAndExplicitRecoverySendsOnlyGets() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();f.reply(membershipAck());f.reply("{}",503)
            val submit=h.submit(p);h.drain()
            assertEquals(MutationOutcome.ReadbackFailed,h.repository.state.value.outcome)
            assertEquals(listOf(TrackId(7)),h.repository.state.value.ack!!.added)
            p.submit(submit);h.drain();assertEquals(4,f.server.requestCount)
            f.reply(membershipDetail());f.reply(membershipPage());p.recover();h.drain()
            assertEquals(MutationOutcome.Confirmed,h.repository.state.value.outcome)
            assertNull(h.repository.state.value.error)
            assertEquals(listOf(TrackId(7)),h.repository.state.value.detail!!.tracks.map {it.id})
            val requests=(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(1,requests.count {it.method=="POST"})
        }
    }
    @Test fun uncertainRecoveryNeverConfirmsOrRevivesSubmitAndDifferentTargetIsExplicit() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();f.reply("{}",500);val submit=h.submit(p);h.drain()
            assertFalse(p.startNew());p.submit(submit);h.drain()
            f.reply("{}",503);p.recover();h.drain();assertFalse(p.startNew())
            f.reply(membershipDetail());f.reply("""{"data":[${membershipSummary()},${membershipSummary(42)}],"total":2,"limit":20,"offset":0}""")
            p.recover();h.drain()
            assertEquals(MutationOutcome.Uncertain,h.repository.state.value.outcome);assertNull(h.repository.state.value.ack)
            assertTrue(p.startNew());p.submit(submit);h.drain()
            assertNull(p.select(h.repository.state.value.rows.first()))
            val fresh=p.select(h.repository.state.value.rows.last())!!
            f.reply(membershipAck(id=42));f.reply(membershipDetail(42));f.reply(membershipPage())
            p.submit(fresh);h.drain()
            assertEquals(PlaylistId(42),h.repository.state.value.ack!!.playlist.id)
            assertEquals(2,(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}.count {it.method=="POST"})
        }
    }
    @Test fun queuedBeforeEntryCloseAndSameRouteReopenRefuseOldReadsAndWrites() {
        HttpsFixture().use {f ->
            val h=Harness(f);val old=h.open();old.reload();old.close();val fresh=h.ready()
            // ready drains the retired old read before its current read.
            assertEquals(2,f.server.requestCount)
            val submit=h.submit(fresh);fresh.close();val replacement=h.open();h.drain()
            assertEquals(2,f.server.requestCount)
            fresh.submit(submit);fresh.reload();fresh.recover();h.drain();assertEquals(2,f.server.requestCount)
            assertEquals(MutationOutcome.Refused,h.repository.state.value.outcome)
            replacement.close();h.route.close();val route2=LibraryPlaylistActions(h.repository){h.queue.add(it)}
            assertNull(h.route.open(h.library.captureTrack(h.library.state.value.rows.single())!!))
            assertNotNull(route2.open(h.library.captureTrack(h.library.state.value.rows.single())!!))
        }
    }
    @Test fun heldReadCannotPublishAfterCloseReopenOrAccountReplacement() {
        for(replaceAccount in listOf(false,true)) HttpsFixture().use {f ->
            val h=Harness(f);val old=h.open();val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(playlistPage()).build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                old.reload();val task=pool.submit {h.drain()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                if(replaceAccount)h.session.accept(h.session.beginIntent(),SecretTokens("b","br","B"))
                old.close();if(!replaceAccount)h.open()
                val before=h.repository.state.value;release.countDown();task.get(5,TimeUnit.SECONDS)
                assertEquals(before,h.repository.state.value);old.reload();h.drain();assertEquals(2,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun dispatchedCloseReopenRetainsReceiptWithoutAutomaticReadsOrReplay() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(membershipAck()).build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val submit=h.submit(p);val task=pool.submit {h.drain()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                p.close();val next=h.open();assertEquals(MutationOutcome.Pending,h.repository.state.value.outcome)
                release.countDown();task.get(5,TimeUnit.SECONDS)
                assertEquals(MutationOutcome.Confirmed,h.repository.state.value.outcome);assertNotNull(h.repository.state.value.ack)
                assertNull(h.repository.state.value.detail);p.submit(submit);next.submit(submit);h.drain();assertEquals(3,f.server.requestCount)
                f.server.dispatcher=QueueDispatcher();f.reply(membershipDetail());f.reply(membershipPage());next.recover();h.drain()
                assertNotNull(h.repository.state.value.detail);assertEquals(5,f.server.requestCount)
            }finally{release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun actualAcknowledgedRowRouteAndAccountCapturedBeforeEnqueue() {
        HttpsFixture().use {f ->
            val h=Harness(f);val row=h.library.state.value.rows.single();val capture=h.library.captureTrack(row)!!
            assertNull(h.library.captureTrack(row.copy()))
            f.reply(membershipLibrary());h.library.refine(h.library.state.value.query)
            assertNull(h.route.open(capture))
            val p=h.ready();h.submit(p)
            h.session.accept(h.session.beginIntent(),SecretTokens("b","br","B"));h.drain()
            assertEquals(3,f.server.requestCount)
            p.reload();h.drain();assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun ownedChoicesPageBeyondFirstTwentyAndEmptyFailureHaveExplicitReadRetry() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.open();f.reply("{}",503);p.reload();h.drain()
            assertNotNull(h.repository.state.value.error)
            f.reply("""{"data":[],"total":0,"limit":20,"offset":0}""");p.reload();h.drain()
            assertEquals(0,h.repository.state.value.total);assertNull(h.repository.state.value.error)
            f.reply("""{"data":[${(1..20).joinToString(","){membershipSummary(it.toLong())}}],"total":21,"limit":20,"offset":0}""");p.reload();h.drain()
            f.reply("""{"data":[${membershipSummary(21)}],"total":21,"limit":20,"offset":20}""");p.more();p.more();h.drain()
            assertEquals((1L..21L).toList(),h.repository.state.value.rows.map {it.id.value})
            assertNotNull(p.select(h.repository.state.value.rows.last()))
            val requests=(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals("20",requests.last().url.queryParameter("offset"));assertEquals(5,requests.size)
        }
    }
    @Test fun reopenedReceiptCanChooseNewPlaylistThroughFreshReadWithoutReposting() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();f.reply(membershipAck());f.reply(membershipDetail());f.reply(membershipPage())
            h.submit(p);h.drain();p.close();val reopened=h.open()
            assertTrue(h.repository.state.value.rows.isEmpty())
            f.reply(membershipPage());assertTrue(reopened.startNew());h.drain()
            assertEquals("Renewed picker must be usable after close/reopen",1,h.repository.state.value.rows.size)
            assertEquals(6,f.server.requestCount)
        }
    }
    @Test fun accountReplacementCannotRecaptureOldAcknowledgedRowsBeforeCollectorRuns() {
        HttpsFixture().use {f ->
            val h=Harness(f);val row=h.library.state.value.rows.single()
            h.session.accept(h.session.beginIntent(),SecretTokens("b","br","B"))
            assertNull("Old Library rows must not borrow replacement credentials",h.library.captureTrack(row))
        }
    }
    @Test fun closingQueuedSubmitSettlesPendingBeforeCancelledWorkerCanDisappear() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();val old=h.submit(p)
            p.close();h.open()
            assertEquals("An unentered cancelled worker must not strand Pending",MutationOutcome.Refused,h.repository.state.value.outcome)
            p.submit(old);h.drain();assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun mutationFailureIsNotPresentedAsAReadFailure() {
        for(code in listOf(403,500)) HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();f.reply("{}",code);h.submit(p);h.drain()
            assertEquals(if(code==403)MutationOutcome.Refused else MutationOutcome.Uncertain,h.repository.state.value.outcome)
            assertNull("Only an actual failed GET should expose read recovery error",h.repository.state.value.error)
        }
    }
    @Test fun dispatchedNetworkLossIsUncertainAndReadRecoveryDoesNotReplay() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready()
            f.server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            val submit=h.submit(p);h.drain()
            assertEquals(MutationOutcome.Uncertain,h.repository.state.value.outcome)
            assertNull(h.repository.state.value.ack)
            f.reply(membershipDetail());f.reply(membershipPage());p.recover();h.drain()
            assertEquals(MutationOutcome.Uncertain,h.repository.state.value.outcome)
            p.submit(submit);h.drain()
            val requests=(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(1,requests.count {it.method=="POST"})
            assertTrue(h.repository.state.value.reconciled)
        }
    }
    @Test fun heldWriteCannotPublishIntoReplacementAccountAndNewAccountCanAdd() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(membershipAck()).build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val old=h.submit(p);val task=pool.submit {h.drain()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                h.session.accept(h.session.beginIntent(),SecretTokens("b","br","B"));h.repository.retire()
                val after=h.repository.state.value
                release.countDown();task.get(5,TimeUnit.SECONDS);assertEquals(after,h.repository.state.value)
                p.submit(old);p.reload();h.drain();assertEquals(3,f.server.requestCount)
                f.server.dispatcher=QueueDispatcher()
                f.reply(membershipLibrary());h.library.refine(LibraryQuery())
                val freshRoute=LibraryPlaylistActions(h.repository){h.queue.add(it)}
                val fresh=freshRoute.open(h.library.captureTrack(h.library.state.value.rows.single())!!)!!
                f.reply(playlistPage());fresh.reload();h.drain()
                f.reply(membershipAck());f.reply(membershipDetail());f.reply(membershipPage());h.submit(fresh);h.drain()
                assertEquals(MutationOutcome.Confirmed,h.repository.state.value.outcome)
            }finally{release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun unsubmittedOldChoiceCannotReviveAfterRefusalAndDeliberatelyNewIntent() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();val retained=p.select(h.repository.state.value.rows.single())!!
            f.reply("{}",403);h.submit(p);h.drain();assertTrue(p.startNew());p.submit(retained);h.drain()
            assertEquals("Retained old choice must not borrow new intent",3,f.server.requestCount)
            assertNull(h.repository.state.value.outcome)
        }
    }
    @Test fun unsubmittedOldChoiceCannotReviveAfterDeliberatelyNewIntent() {
        HttpsFixture().use {f ->
            val h=Harness(f);val p=h.ready();val retained=p.select(h.repository.state.value.rows.single())!!
            f.reply(membershipAck());f.reply(membershipDetail());f.reply(membershipPage())
            h.submit(p);h.drain();assertTrue(p.startNew());p.submit(retained);h.drain()
            assertEquals("Retained old choice must not borrow new intent",5,f.server.requestCount)
            assertNull(h.repository.state.value.outcome)
        }
    }
}
