package com.soundq.android.data.imports

import androidx.compose.runtime.mutableStateOf
import com.soundq.android.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.junit.Assert.*
import org.junit.Test
import kotlin.coroutines.CoroutineContext

/** Real observation owner, auth, journal and exact HTTPS reads; queued (not Unconfined) workers. */
class ImportProgressLifecycleTest {
    private class Queued:CoroutineDispatcher() {
        private val pending=java.util.ArrayDeque<Runnable>()
        override fun dispatch(context:CoroutineContext,block:Runnable) {synchronized(pending){pending.addLast(block)}}
        fun drain() {repeat(10_000) {val next=synchronized(pending){pending.pollFirst()} ?: return;next.run()};error("worker did not settle")}
    }
    private inner class Harness(signedIn:Boolean=true):AutoCloseable {
        val wire=HttpsFixture()
        val session=AccountSession(wire.endpoint,MemoryStore())
        val api=SoundQApi(session,wire.client)
        val progress=ImportProgressObservation(session,api)
        val queue=Queued()
        val scope=CoroutineScope(SupervisorJob()+queue)
        val events=MutableStateFlow(0)
        var now=0L
        var serial=0
        init {if(signedIn)signIn();progress.clock={now}}
        fun signIn() {assertTrue(session.accept(session.beginIntent(),SecretTokens("a","r","A")))}
        fun start() {scope.launch {progress.observe(events.map {Unit})};progress.visible(true);queue.drain()}
        fun addJob():String {
            val id="123e4567-e89b-12d3-a456-${(++serial).toString().padStart(12,'0')}"
            val row=api.intakeReceipts.begin(session.endpoint.identity,"A","download")
            api.intakeReceipts.finish(session.endpoint.identity,"A",row,"accepted",id)
            wire.reply("""{"job_id":"$id","status":"queued","progress":0,"track_id":null,"source_type":"youtube","created_at":"2026-11-14T12:00:00Z"}""")
            return id
        }
        fun wake() {events.value++;queue.drain()}
        fun request(id:String) {
            val r=wire.server.takeRequest(3,java.util.concurrent.TimeUnit.SECONDS)
            assertNotNull("exact job read must dispatch",r)
            assertEquals("GET",r!!.method);assertEquals("/api/v1/downloads/$id",r.url.encodedPath)
        }
        override fun close() {progress.visible(false);scope.cancel();queue.drain();wire.close()}
    }

    @Test fun equalCountRenewalReplacesStructuralComposeStateAndKeepsStaleActionsRetired() {
        Harness().use {h ->
            h.progress.visible(true);val lease=h.progress.open()!!
            val id=h.addJob();h.progress.receipts(lease);h.progress.refresh(lease);h.request(id)
            val old=h.progress.state.value!!
            // collectAsStateWithLifecycle's remembered produceState uses this real structural policy.
            val displayed=mutableStateOf<ImportBatchProgress?>(old)
            var opened=0
            val oldOpen={if(h.progress.owns(old))opened++}
            val oldDismiss={h.progress.dismiss(old)}
            h.progress.visible(false);assertFalse(h.progress.owns(old))
            // Collection is stopped: it misses null, retaining the old non-null value until resume.
            h.progress.visible(true);val renewed=h.progress.open()!!
            h.wire.reply("""{"job_id":"$id","status":"queued","progress":0,"track_id":null,"source_type":"youtube","created_at":"2026-11-14T12:00:00Z"}""")
            h.progress.refresh(renewed);h.request(id)
            val current=h.progress.state.value!!
            assertEquals(old.identity,current.identity) // lease renewal is not a new batch/budget.
            assertEquals(listOf(old.active,old.complete,old.failed,old.unknown),listOf(current.active,current.complete,current.failed,current.unknown))
            assertNotSame(old,current)
            displayed.value=current
            assertSame("structural state must retain the exact current lease publication",current,displayed.value)
            oldOpen();oldDismiss();assertEquals(0,opened);assertSame(current,h.progress.state.value)
            val captured=displayed.value!!
            assertTrue(h.progress.owns(captured));if(h.progress.owns(captured))opened++
            assertEquals(1,opened)
            h.progress.dismiss(captured);assertNull(h.progress.state.value)
            h.progress.receipts(renewed);h.progress.refresh(renewed);assertNull(h.progress.state.value)
            assertEquals(2,h.wire.server.requestCount)
        }
    }

    @Test fun queuedForegroundABAImmediatelyRetiresThenRestartsExactObservation() {
        Harness().use {h ->
            h.start();val first=h.addJob();h.wake();h.request(first)
            val old=h.progress.state.value!!;assertEquals(1,old.active)
            h.progress.visible(false);assertNull(h.progress.state.value);assertFalse(h.progress.owns(old))
            h.progress.visible(true) // no dispatch between false and true
            h.wire.reply("""{"job_id":"$first","status":"queued","progress":0,"track_id":null,"source_type":"youtube","created_at":"2026-11-14T12:00:00Z"}""")
            h.queue.drain()
            assertEquals("foreground re-entry must publish a renewed lease",1,h.progress.state.value?.active)
            h.request(first);assertFalse(h.progress.owns(old))
            val second=h.addJob();h.wake();h.request(second)
            assertEquals(2,h.progress.state.value!!.active)
            assertEquals(3,h.wire.server.requestCount)
        }
    }

    @Test fun acceptedSignInAfterInitialNoAuthorityObservationStartsWithoutVisibilityChange() {
        Harness(false).use {h ->
            val intent=h.session.beginIntent()
            h.start();assertNull(h.progress.state.value);assertNull(h.session.capture())
            val revision=h.session.scopeRevision.value
            assertTrue(h.session.accept(intent,SecretTokens("a","r","A")))
            assertEquals(revision,h.session.scopeRevision.value)
            h.queue.drain() // acceptance, not a lifecycle transition, must open the new journal boundary.
            val id=h.addJob();h.wake()
            assertEquals("accepted auth must restart observation after open returned",1,h.progress.state.value?.active)
            h.request(id);assertEquals(1,h.wire.server.requestCount)
        }
    }

    @Test fun duplicateVisibleAndIdleSignalsDoNotRenewLeaseOrReadHistory() {
        Harness().use {h ->
            h.start();repeat(30){h.progress.visible(true);h.wake()}
            assertNull(h.progress.state.value);assertEquals(0,h.wire.server.requestCount)
            val id=h.addJob();h.wake();h.request(id)
            val accepted=h.progress.state.value!!
            repeat(30){h.progress.visible(true);h.wake()}
            assertSame(accepted,h.progress.state.value);assertTrue(h.progress.owns(accepted))
            assertEquals(1,h.wire.server.requestCount)
            h.progress.visible(false);h.wake();assertNull(h.progress.state.value)
            assertEquals(1,h.wire.server.requestCount)
        }
    }
}
