package com.soundq.android.data

import com.soundq.android.data.imports.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class ImportOwnershipTest {
    private val a="123e4567-e89b-12d3-a456-426614174000"
    private val b="123e4567-e89b-12d3-a456-426614174001"
    private fun job(id:String,status:String="complete",progress:Int=100,track:String="71")="""{"job_id":"$id","status":"$status","progress":$progress,"track_id":$track,"source_type":"youtube","url":"https://youtu.be/fixture","created_at":"2026-10-28T00:00:00Z"}"""
    @Test fun recentSelectionOwnsItsIdentityReadFailurePreservesReceiptAndOpenRequiresAcknowledgedLibraryRow() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
            val imports=ImportRepository(session,api,library);val view=imports.open()!!
            imports.edit(view,"https://youtu.be/A");val post=imports.claim(view)!!
            f.reply("""{"job_id":"$a","status":"queued"}""",201);imports.submit(post)
            f.reply("""{"jobs":[${job(b)}]}""");imports.recent(view)
            assertEquals("recent read must publish job B",b,imports.state.value.recent.singleOrNull()?.id?.value)
            imports.select(view,imports.state.value.recent.single())
            assertNull(imports.state.value.acknowledgement)
            f.reply("{\"error\":\"secret upstream\"}",500);imports.check(view)
            assertFalse(imports.state.value.loading);assertEquals(b,imports.state.value.selected?.id?.value)
            assertNotNull(imports.state.value.error)
            f.reply("""{"tracks":[{"id":71,"title":"Imported acknowledged row","is_liked":false}],"total":1,"limit":20,"offset":0}""")
            assertTrue(imports.openLibrary(view))
            assertEquals(TrackId(71),library.state.value.rows.single().id)
            assertEquals(LibraryQuery(),library.state.value.query)
            imports.another(view);imports.submit(post)
            imports.edit(view,"https://soundcloud.com/fixture/new-song")
            assertNotNull(imports.claim(view))
            assertNull(imports.state.value.acknowledgement);assertNull(imports.state.value.selected)
            assertEquals(4,f.server.requestCount)
        }
    }
    @Test fun supersedingEqualValuedLibraryQueryCannotCertifyImportsOwnAcknowledgedRead() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val calls=java.util.concurrent.atomic.AtomicInteger()
            val library=LibraryRepository(session,{_,_,offset ->
                if(calls.incrementAndGet()==1){entered.countDown();release.await(3,TimeUnit.SECONDS)}
                LibraryPage(listOf(Track(TrackId(71),"Imported row")),1,20,offset)
            },{_,_,_ ->})
            val imports=ImportRepository(session,api,library);val view=imports.open()!!
            f.reply("""{"jobs":[${job(b)}]}""");imports.recent(view);imports.select(view,imports.state.value.recent.single())
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit<Boolean>{imports.openLibrary(view)};assertTrue(entered.await(2,TimeUnit.SECONDS))
                library.refine(LibraryQuery());release.countDown()
                assertFalse("a sibling read with equal query values is not this import reveal acknowledgement",work.get(3,TimeUnit.SECONDS))
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun openLibraryPaginatesSoleAcknowledgedOwnerAndRefusesAbsentRowWithoutTouchingNormalQueryOnStatus() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
            f.reply("""{"tracks":[],"total":0,"limit":20,"offset":0}""");library.refine(LibraryQuery(text="keep query",liked=true))
            val imports=ImportRepository(session,api,library);val view=imports.open()!!
            f.reply("""{"jobs":[${job(b)}]}""");imports.recent(view);imports.select(view,imports.state.value.recent.single())
            assertEquals("keep query",library.state.value.query.text)
            f.reply("""{"tracks":[{"id":1,"title":"First page"}],"total":2,"limit":1,"offset":0}""")
            f.reply("""{"tracks":[{"id":71,"title":"Imported page two"}],"total":2,"limit":1,"offset":1}""")
            assertTrue(imports.openLibrary(view));assertEquals(listOf(1L,71L),library.state.value.rows.map {it.id.value})
            f.reply("""{"tracks":[],"total":0,"limit":20,"offset":0}""")
            assertFalse(imports.openLibrary(view));assertFalse(imports.state.value.loading)
        }
    }
    @Test fun heldStatusClosePreservesKnownReceiptAndRefusesLatePublication() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val imports=ImportRepository(session,api,LibraryRepository(session,api::library,api::like));val view=imports.open()!!
            imports.edit(view,"https://youtu.be/A");val post=imports.claim(view)!!;f.reply("""{"job_id":"$a","status":"queued"}""",201);imports.submit(post)
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();release.await(3,TimeUnit.SECONDS);return MockResponse.Builder().body(job(a)).build()}}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit {imports.check(view)};assertTrue(entered.await(2,TimeUnit.SECONDS))
                imports.close(view);val replacement=imports.open()!!;release.countDown();work.get(3,TimeUnit.SECONDS)
                assertNull(imports.state.value.selected);assertEquals(a,imports.state.value.acknowledgement?.id?.value)
                assertFalse(imports.state.value.loading);assertTrue(imports.current(replacement))
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun retiredDraftCallbackCannotClaimAnotherLinksNewIntent() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val imports=ImportRepository(session,api,LibraryRepository(session,api::library,api::like));val view=imports.open()!!
            imports.edit(view,"https://youtu.be/A");val oldDraft=imports.state.value.draft
            val post=imports.claim(view,oldDraft)!!;f.reply("{}",503);imports.submit(post)
            imports.another(view);imports.edit(view,"https://youtu.be/B")
            assertNull(imports.claim(view,oldDraft));assertNotNull(imports.claim(view,imports.state.value.draft))
        }
    }
    @Test fun completionAtHundredWithoutTrackCannotOpenAndUncertainSubmitOnlyRecoversByReading() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
            val imports=ImportRepository(session,api,library);val view=imports.open()!!
            imports.edit(view,"https://youtu.be/A");val post=imports.claim(view)!!
            f.reply("{}",503);imports.submit(post);imports.submit(post)
            assertEquals(SafeFailure.Reason.Uncertain,imports.state.value.error);assertNull(imports.claim(view))
            f.reply("""{"jobs":[${job(b,"processing",100,"null")}]}""");imports.recent(view)
            imports.select(view,imports.state.value.recent.single());assertFalse(imports.openLibrary(view))
            assertEquals(LibraryQuery(),library.state.value.query);assertEquals(2,f.server.requestCount)
            f.reply(job(b,"complete",100,"null"));imports.check(view);assertFalse(imports.openLibrary(view))
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun heldStatusAndLibraryCloseCannotNavigateOrOverwriteReplacementView() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
            val imports=ImportRepository(session,api,library);val view=imports.open()!!
            f.reply("""{"jobs":[${job(b)}]}""");imports.recent(view);imports.select(view,imports.state.value.recent.single())
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();release.await(3,TimeUnit.SECONDS)
                return MockResponse.Builder().body("""{"tracks":[{"id":71,"title":"Late imported row"}],"total":1,"limit":20,"offset":0}""").build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit<Boolean>{imports.openLibrary(view)};assertTrue(entered.await(2,TimeUnit.SECONDS))
                imports.close(view);val replacement=imports.open()!!;release.countDown()
                assertFalse(work.get(3,TimeUnit.SECONDS));assertTrue(imports.current(replacement));assertFalse(imports.state.value.loading)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun heldAckCannotAdoptReplacementAccountOrRestoreRetiredCallbacks() {
        HttpsFixture().use {f ->
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();release.await(3,TimeUnit.SECONDS);return MockResponse.Builder().code(201).body("""{"job_id":"$a","status":"queued"}""").build()}}
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val imports=ImportRepository(session,api,LibraryRepository(session,api::library,api::like));val view=imports.open()!!
            imports.edit(view,"https://youtu.be/A");val post=imports.claim(view)!!;val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit {imports.submit(post)};assertTrue(entered.await(2,TimeUnit.SECONDS))
                session.accept(session.beginIntent(),SecretTokens("b","br","B"));val replacement=imports.open()!!
                release.countDown();work.get(3,TimeUnit.SECONDS)
                assertNull(imports.state.value.acknowledgement);assertFalse(imports.state.value.pending)
                imports.edit(view,"https://youtu.be/old");assertNull(imports.claim(view));assertEquals("",imports.state.value.draft.text)
                assertTrue(imports.current(replacement));assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun heldPostClaimsBeforeEnqueueAndCloseReopenRecoversLateAccountOwnedAckWithoutReplay() {
        HttpsFixture().use {f ->
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();release.await(3,TimeUnit.SECONDS)
                return MockResponse.Builder().code(201).body("""{"job_id":"$a","status":"queued"}""").build()
            }}
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
            val imports=ImportRepository(session,api,library);val view=imports.open()!!
            imports.edit(view,"https://youtu.be/fixture")
            val submission=imports.claim(view)
            assertNotNull("submit must claim a pending immutable intent before work is enqueued",submission)
            assertTrue(imports.state.value.pending);assertNull(imports.state.value.acknowledgement)
            assertNull(imports.claim(view))
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit {imports.submit(submission!!)}
                assertTrue(entered.await(2,TimeUnit.SECONDS))
                imports.close(view)
                val reopened=imports.open()!!
                assertNull(imports.claim(view));assertNull(imports.claim(reopened))
                release.countDown();work.get(3,TimeUnit.SECONDS)
                assertEquals(a,imports.state.value.acknowledgement?.id?.value)
                assertFalse(imports.state.value.pending)
                imports.submit(submission!!)
                assertEquals(1,f.server.requestCount)
                assertTrue(library.state.value.rows.isEmpty())
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
}
