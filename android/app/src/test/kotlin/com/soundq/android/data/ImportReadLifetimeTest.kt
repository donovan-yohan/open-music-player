package com.soundq.android.data

import com.soundq.android.data.imports.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

/** Actual repository + authenticated HTTPS schedules for IMP-R1/R2, not a replacement reducer. */
class ImportReadLifetimeTest {
    private val a="123e4567-e89b-12d3-a456-426614174000"
    private val b="123e4567-e89b-12d3-a456-426614174001"
    private fun job(id:String,track:Int)="""{"job_id":"$id","status":"complete","progress":100,"track_id":$track,"source_type":"youtube","created_at":"2026-10-28T00:00:00Z"}"""
    private fun page(id:Int,offset:Int=0,total:Int=1)="""{"tracks":[{"id":$id,"title":"Track $id","is_liked":false}],"total":$total,"limit":20,"offset":$offset}"""
    private inner class Harness:AutoCloseable {
        val f=HttpsFixture()
        val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
        val api=SoundQApi(session,f.client)
        val library=LibraryRepository(session,api::library,api::like)
        val imports=ImportRepository(session,api,library)
        val view=imports.open()!!
        val requests=CopyOnWriteArrayList<String>()
        var response:(RecordedRequest)->String={request ->
            when {
                request.url.encodedPath.endsWith("/downloads/$a")->job(a,71)
                request.url.encodedPath.endsWith("/downloads/$b")->job(b,82)
                request.url.encodedPath.endsWith("/downloads")->"""{"jobs":[${job(a,71)},${job(b,82)}]}"""
                else->page(82)
            }
        }
        init {
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                requests.add(request.url.encodedPath+"?"+(request.url.encodedQuery ?: ""))
                return MockResponse.Builder().body(response(request)).build()
            }}
            imports.recent(view)
            assertEquals(listOf(a,b),imports.state.value.recent.map {it.id.value})
            imports.select(view,imports.state.value.recent[0])
        }
        fun selectB(){imports.select(view,imports.state.value.recent[1])}
        fun revealB(){
            imports.check(view)
            assertEquals(b,imports.state.value.selected?.id?.value)
            assertTrue("explicit B Open must be acknowledged by the actual Library reader",imports.openLibrary(view))
            assertEquals(listOf(82L),library.state.value.rows.map {it.id.value})
            assertFalse(library.state.value.loading)
        }
        override fun close(){f.close()}
    }
    private fun captureRace(open:Boolean) {
        Harness().use {h ->
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            h.imports.beforeIdentityReadAdmission={entered.countDown();assertTrue(release.await(5,TimeUnit.SECONDS))}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit<Boolean>{if(open)h.imports.openLibrary(h.view) else {h.imports.check(h.view);false}}
                assertTrue("old A identity was positively captured",entered.await(3,TimeUnit.SECONDS))
                h.selectB();release.countDown()
                assertFalse(work.get(5,TimeUnit.SECONDS))
                h.imports.beforeIdentityReadAdmission=null
                assertEquals("old A cannot replace deliberate B selection",b,h.imports.state.value.selected?.id?.value)
                assertEquals("retired pre-admission A must not dispatch",1,h.requests.size)
                assertFalse(h.imports.state.value.loading)
                assertFalse(h.library.state.value.loading)
                h.revealB()
                assertTrue(h.requests[1].contains("/downloads/$b"))
                assertTrue(h.requests[2].contains("/library?"))
            } finally {release.countDown();h.imports.beforeIdentityReadAdmission=null;pool.shutdownNow()}
        }
    }
    @Test fun checkCapturedBeforeSelectionCannotAcquireFreshReadForOldJob()=captureRace(false)
    @Test fun openCapturedBeforeSelectionCannotAcquireFreshLibraryReadForOldTrack()=captureRace(true)
    @Test fun alreadyDispatchedCheckCannotOverwriteNewSelectionAndBStillReveals() {
        Harness().use {h ->
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            val base=h.response
            h.response={r ->if(r.url.encodedPath.endsWith("/downloads/$a")){entered.countDown();assertTrue(release.await(5,TimeUnit.SECONDS))};base(r)}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit {h.imports.check(h.view)}
                assertTrue(entered.await(3,TimeUnit.SECONDS));h.selectB();release.countDown();work.get(5,TimeUnit.SECONDS)
                assertEquals(b,h.imports.state.value.selected?.id?.value);assertFalse(h.imports.state.value.loading)
                h.revealB()
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun unchangedSelectionStillChecksAndRevealsActualAcknowledgedTrack() {
        Harness().use {h ->h.selectB();h.revealB();assertEquals(3,h.requests.size)}
    }
    private fun cancelReveal(action:String,betweenPages:Boolean) {
        Harness().use {h ->
            h.selectB()
            h.response={r ->if(r.url.encodedPath.endsWith("/library")) {
                val offset=r.url.queryParameter("offset")!!.toInt()
                if(offset==0)page(1,0,2) else page(82,1,2)
            } else "{}"}
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            h.library.beforeImportPage={offset ->if(offset==(if(betweenPages)1 else 0)){entered.countDown();assertTrue(release.await(5,TimeUnit.SECONDS))}}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit<Boolean>{h.imports.openLibrary(h.view)}
                assertTrue("actual Library loading owner admitted before cancellation",entered.await(3,TimeUnit.SECONDS))
                assertTrue(h.library.state.value.loading)
                when(action){"close"->h.imports.close(h.view);"another"->h.imports.another(h.view);else->h.imports.select(h.view,h.imports.state.value.recent[0])}
                val count=h.requests.size
                release.countDown()
                assertFalse("cancelled Open cannot navigate",work.get(5,TimeUnit.SECONDS))
                assertEquals("no first/next fetch after cancellation",count,h.requests.size)
                assertEquals(if(betweenPages)2 else 1,count)
                assertFalse("cancel must settle its exact Library loading owner",h.library.state.value.loading)
                assertFalse(h.imports.state.value.loading)
                h.library.beforeImportPage=null
                h.response={r -> page(99,r.url.queryParameter("offset")!!.toInt(),if(betweenPages)2 else 1)}
                h.library.loadMore()
                assertFalse("normal pagination admission must be usable after cancellation",h.library.state.value.loading)
                assertEquals(99L,h.library.state.value.rows.last().id.value)
                h.response={page(99)}
                h.library.refine(LibraryQuery(text="usable next read"))
                assertFalse(h.library.state.value.loading);assertEquals(listOf(99L),h.library.state.value.rows.map {it.id.value})
                assertEquals("usable next read",h.library.state.value.query.text)
            } finally {release.countDown();h.library.beforeImportPage=null;pool.shutdownNow()}
        }
    }
    @Test fun closeBeforeFirstFetchSettlesOnlyOwnedLibraryLoading()=cancelReveal("close",false)
    @Test fun anotherBeforeFirstFetchSettlesOnlyOwnedLibraryLoading()=cancelReveal("another",false)
    @Test fun selectionBeforeFirstFetchSettlesOnlyOwnedLibraryLoading()=cancelReveal("select",false)
    @Test fun closeBetweenPagesSettlesOnlyOwnedLibraryLoading()=cancelReveal("close",true)
    @Test fun anotherBetweenPagesSettlesOnlyOwnedLibraryLoading()=cancelReveal("another",true)
    @Test fun selectionBetweenPagesSettlesOnlyOwnedLibraryLoading()=cancelReveal("select",true)
    @Test fun dispatchedOpenRetiresOnSelectionAndExplicitBReadStillRevealsB() {
        Harness().use {h ->
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            val held=AtomicBoolean(true);val base=h.response
            h.response={r ->if(r.url.encodedPath.endsWith("/library")&&held.compareAndSet(true,false)) {
                entered.countDown();assertTrue(release.await(5,TimeUnit.SECONDS));page(71)
            } else base(r)}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val old=pool.submit<Boolean>{h.imports.openLibrary(h.view)}
                assertTrue(entered.await(3,TimeUnit.SECONDS));h.selectB();release.countDown()
                assertFalse(old.get(5,TimeUnit.SECONDS))
                assertEquals(b,h.imports.state.value.selected?.id?.value)
                assertFalse(h.library.state.value.loading)
                h.revealB()
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun completedNewerQueryRowsSurviveCancelledOldRevealTerminalCleanup() {
        Harness().use {h ->
            h.selectB()
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            h.library.beforeImportPage={entered.countDown();assertTrue(release.await(5,TimeUnit.SECONDS))}
            h.response={page(99)}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val old=pool.submit<Boolean>{h.imports.openLibrary(h.view)}
                assertTrue(entered.await(3,TimeUnit.SECONDS));h.imports.another(h.view)
                h.library.refine(LibraryQuery(text="newer complete",liked=true))
                val accepted=h.library.state.value
                assertEquals(listOf(99L),accepted.rows.map {it.id.value});assertFalse(accepted.loading)
                release.countDown();assertFalse(old.get(5,TimeUnit.SECONDS))
                assertSame("old terminal must preserve accepted newer rows",accepted,h.library.state.value)
                assertEquals(2,h.requests.size)
            } finally {release.countDown();h.library.beforeImportPage=null;pool.shutdownNow()}
        }
    }
    @Test fun cancelledOldRevealCannotClearNewerQueryLoadingOrRows() {
        Harness().use {h ->
            h.selectB()
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            val newerEntered=CountDownLatch(1);val newerRelease=CountDownLatch(1)
            h.library.beforeImportPage={entered.countDown();assertTrue(release.await(5,TimeUnit.SECONDS))}
            h.response={r ->if(r.url.queryParameter("q")=="newer") {newerEntered.countDown();assertTrue(newerRelease.await(5,TimeUnit.SECONDS));page(99)} else page(82)}
            val pool=Executors.newFixedThreadPool(2)
            try {
                val old=pool.submit<Boolean>{h.imports.openLibrary(h.view)}
                assertTrue(entered.await(3,TimeUnit.SECONDS));h.imports.another(h.view)
                val next=pool.submit{h.library.refine(LibraryQuery(text="newer",liked=true))}
                assertTrue(newerEntered.await(3,TimeUnit.SECONDS));val waiting=h.library.state.value
                assertTrue(waiting.loading);assertEquals("newer",waiting.query.text)
                release.countDown();assertFalse(old.get(5,TimeUnit.SECONDS))
                assertSame("old terminal cleanup must not publish over newer loading owner",waiting,h.library.state.value)
                newerRelease.countDown();next.get(5,TimeUnit.SECONDS)
                assertEquals(listOf(99L),h.library.state.value.rows.map {it.id.value});assertFalse(h.library.state.value.loading)
                assertTrue(h.library.state.value.query.liked)
            } finally {release.countDown();newerRelease.countDown();h.library.beforeImportPage=null;pool.shutdownNow()}
        }
    }
}
