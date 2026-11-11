package com.soundq.android.data

import com.soundq.android.data.playlists.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class PlaylistOrdinaryChooserTest {
    private class Harness(val f:HttpsFixture) {
        val api=SoundQApi(playlistSession(f),f.client)
        val library=LibraryRepository(api.session,api::library,api::like)
        val repository=PlaylistMembershipRepository(api,library)
        val jobs=ArrayDeque<()->Unit>()
        val route:LibraryPlaylistActions
        val picker:MembershipPickerActions
        init {
            f.reply(membershipLibrary());library.refine(LibraryQuery())
            route=LibraryPlaylistActions(repository){jobs.add(it)}
            picker=route.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(playlistPage());picker.reload();drain()
        }
        fun drain(){while(jobs.isNotEmpty())jobs.removeFirst()()}
    }
    @Test fun createNewClaimsOnceThenAddsToExactReturnedIdAndReadsMembership() {
        HttpsFixture().use { f ->
            val h=Harness(f);val before=h.library.state.value
            val draft=PlaylistDraft("Chooser new", "Notes")
            val created="""{"id":73,"name":"Chooser new","description":"Notes","isPublic":false,"trackCount":0,"durationMs":0}"""
            f.reply(created,201);f.reply(membershipAck(id=73));f.reply(membershipDetail(id=73));f.reply(membershipPage())
            h.picker.create(draft);h.picker.create(draft)
            assertEquals(1,h.jobs.size);assertEquals(MutationOutcome.Pending,h.repository.state.value.outcome)
            h.drain()
            assertEquals(PlaylistId(73),h.repository.state.value.created?.id)
            assertEquals(MutationOutcome.Confirmed,h.repository.state.value.outcome)
            assertEquals(listOf(TrackId(7)),h.repository.state.value.detail!!.tracks.map {it.id})
            assertSame(before,h.library.state.value)
            val requests=(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","GET","POST","POST","GET","GET"),requests.map {it.method})
            assertEquals("/api/v1/playlists/73/tracks",requests[3].url.encodedPath)
            assertEquals("{\"trackIds\":[7]}",requests[3].body!!.utf8())
        }
    }
    @Test fun unknownCreateOnlyBrowsesThenRequiresExactExistingChoiceNeverRepeatsCreate() {
        HttpsFixture().use { f ->
            val h=Harness(f);val draft=PlaylistDraft("Chooser new")
            f.reply("{}",503);h.picker.create(draft);h.drain()
            assertEquals(MutationOutcome.Uncertain,h.repository.state.value.outcome)
            assertNull("Only failed reads expose read-recovery errors",h.repository.state.value.error)
            assertNull(h.repository.state.value.created)
            h.picker.create(draft);assertTrue(h.jobs.isEmpty())
            f.reply(playlistPage());h.picker.recover();h.drain()
            assertTrue(h.repository.state.value.reconciled)
            assertTrue(h.picker.startNew())
            h.picker.create(draft);assertTrue(h.jobs.isEmpty())
            val exact=h.picker.select(h.repository.state.value.rows.single())!!
            f.reply(membershipAck());f.reply(membershipDetail());f.reply(membershipPage())
            h.picker.submit(exact);h.drain()
            val requests=(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(1,requests.count {it.method=="POST"&&it.url.encodedPath=="/api/v1/playlists"})
            assertEquals(1,requests.count {it.method=="POST"&&it.url.encodedPath=="/api/v1/playlists/41/tracks"})
        }
    }
    @Test fun lostAddAckRecoversKnownIdWithGetOnlyNeverCreatesOrAddsAgain() {
        HttpsFixture().use { f ->
            val h=Harness(f);val draft=PlaylistDraft("Chooser new")
            f.reply("""{"id":73,"name":"Chooser new","isPublic":false,"trackCount":0,"durationMs":0}""",201)
            f.reply("{}",503);h.picker.create(draft);h.drain()
            assertEquals(MutationOutcome.Uncertain,h.repository.state.value.outcome)
            f.reply(membershipDetail(id=73));f.reply(membershipPage());h.picker.recover();h.drain()
            assertTrue(h.repository.state.value.reconciled)
            assertEquals(MutationOutcome.Uncertain,h.repository.state.value.outcome)
            h.picker.continueCreated();h.picker.create(draft);assertTrue(h.jobs.isEmpty())
            assertEquals(2,(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}.count {it.method=="POST"})
        }
    }
    @Test fun createResponseAfterCloseRetainsKnownIdButCannotAddUntilExplicitFreshRecovery() {
        HttpsFixture().use { f ->
            val h=Harness(f);val draft=PlaylistDraft("Chooser new")
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            val created="""{"id":73,"name":"Chooser new","isPublic":false,"trackCount":0,"durationMs":0}"""
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.method=="POST"&&request.url.encodedPath=="/api/v1/playlists") {
                    entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().code(201).body(created).build()
                }
                return MockResponse.Builder().body(if(request.url.encodedPath.endsWith("/73")) created.dropLast(1)+",\"tracks\":[]}" else membershipPage()).build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                h.picker.create(draft);val task=pool.submit {h.drain()}
                assertTrue(entered.await(3,TimeUnit.SECONDS));h.picker.close();release.countDown();task.get(5,TimeUnit.SECONDS)
                assertEquals(3,f.server.requestCount)
                val fresh=h.route.open(h.library.captureTrack(h.library.state.value.rows.single())!!)!!
                assertEquals(PlaylistId(73),h.repository.state.value.created?.id)
                fresh.continueCreated();assertTrue(h.jobs.isEmpty())
                fresh.recover();h.drain()
                assertTrue(h.repository.state.value.reconciled)
                f.server.dispatcher=QueueDispatcher()
                f.reply(membershipAck(id=73));f.reply(membershipDetail(id=73));f.reply(membershipPage())
                fresh.continueCreated();fresh.continueCreated();assertEquals(1,h.jobs.size);h.drain()
                assertEquals(MutationOutcome.Confirmed,h.repository.state.value.outcome)
                val requests=(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
                assertEquals(1,requests.count {it.method=="POST"&&it.url.encodedPath=="/api/v1/playlists"})
                assertEquals(1,requests.count {it.method=="POST"&&it.url.encodedPath=="/api/v1/playlists/73/tracks"})
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun droppedCreateResponseRetainsUncertaintyWithoutASecondPost() {
        HttpsFixture().use { f ->
            val h=Harness(f);val draft=PlaylistDraft("Chooser new")
            f.server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            h.picker.create(draft);h.drain()
            assertEquals(MutationOutcome.Uncertain,h.repository.state.value.outcome)
            assertTrue(h.repository.state.value.creationBlocked)
            f.reply(playlistPage());h.picker.recover();h.drain()
            assertTrue(h.repository.state.value.reconciled)
            h.picker.create(draft);assertTrue(h.jobs.isEmpty())
            assertEquals(1,(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}.count {it.method=="POST"})
        }
    }
    @Test fun heldCreationCannotPublishOrContinueUnderReplacementAccount() {
        HttpsFixture().use { f ->
            val h=Harness(f);val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS))
                return MockResponse.Builder().code(201).body("""{"id":73,"name":"Chooser new","isPublic":false,"trackCount":0,"durationMs":0}""").build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                h.picker.create(PlaylistDraft("Chooser new"));val task=pool.submit {h.drain()}
                assertTrue(entered.await(3,TimeUnit.SECONDS))
                h.api.session.accept(h.api.session.beginIntent(),SecretTokens("b","br","B"));h.repository.retire()
                val replacement=h.repository.state.value
                release.countDown();task.get(5,TimeUnit.SECONDS)
                assertSame(replacement,h.repository.state.value)
                h.picker.continueCreated();h.picker.recover();h.picker.create(PlaylistDraft("Chooser new"));h.drain()
                assertEquals(3,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun queuedCreationIsRefusedAfterLibrarySourceReplacement() {
        HttpsFixture().use { f ->
            val h=Harness(f);h.picker.create(PlaylistDraft("Chooser new"))
            f.reply(membershipLibrary());h.library.refine(LibraryQuery(text="replacement"));h.drain()
            assertEquals(3,f.server.requestCount)
            assertEquals(MutationOutcome.Refused,h.repository.state.value.outcome)
        }
    }
}
