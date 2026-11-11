package com.soundq.android.playback

import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import kotlin.coroutines.CoroutineContext

class ArrangementLifetimeTest {
    private class HeldDispatcher:CoroutineDispatcher() {
        private val queued=java.util.ArrayDeque<Runnable>()
        override fun dispatch(context:CoroutineContext,block:Runnable){queued.add(block)}
        fun drain(){while(queued.isNotEmpty())queued.removeFirst().run()}
    }
    // Exact pre-repair ArrangementControls launch. The supported member replaces
    // this compatibility extension when available; the assertions stay identical.
    @Suppress("EXTENSION_SHADOWED_BY_MEMBER")
    private fun ArrangementSave.schedule(scope:CoroutineScope,work:(()->Unit)?,dispatcher:CoroutineDispatcher):Job? =
        work?.let {scope.launch(dispatcher){it()}}

    private fun fixture(test:(HttpsFixture,AccountSession,AccountScope,TimelineRepository,ArrangementSave)->Unit) {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val account=session.capture()!!
            val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"arrangement-lifetime-").toFile()
            try {
                val timeline=TimelineRepository(session,dir){_,_,_,_->error("no analysis")}
                timeline.observe(account,listOf(TimelineSource("a",7,"Fixture",2000,QueueSegment.Context)))
                test(f,session,account,timeline,ArrangementSave(SoundQApi(session,f.client),timeline))
            } finally {dir.deleteRecursively()}
        }
    }
    @Test fun saveCancelledBeforeEntryReleasesItsReservationAndAllowsFreshSave() = fixture {f,_,account,timeline,save ->
        val dispatcher=HeldDispatcher();val parent=Job();val jobs=CoroutineScope(parent)
        val document=timeline.state.value.document
        val work=save.save(account,document,"Arrangement"){true}!!
        val job=save.schedule(jobs,work,dispatcher)!!
        assertTrue(save.state.value.busy);parent.cancel();dispatcher.drain()
        assertTrue(job.isCompleted);assertEquals(0,f.server.requestCount)
        save.enter(account)
        assertFalse("Never-entered Save must release busy",save.state.value.busy)
        assertFalse("No write entered, so there is no uncertain create",save.state.value.blocked)
        val fresh=save.save(account,document,"Arrangement"){true}
        assertNotNull("Same account route reentry must admit a fresh Save",fresh)
        // A retained old callback cannot consume or clear the fresh reservation.
        work();assertEquals(0,f.server.requestCount);assertTrue(save.state.value.busy)
        val cancelled=Job().apply {cancel()};save.schedule(CoroutineScope(cancelled),fresh,dispatcher)
        dispatcher.drain();assertFalse(save.state.value.busy)
    }
    @Test fun getAlreadyCancelledBeforeEntryReleasesItsReservationAndAllowsFreshRecovery() = fixture {f,_,account,timeline,save ->
        val dispatcher=HeldDispatcher();val parent=Job().apply {cancel()}
        val document=timeline.state.value.document;val id=document.arrangementPlan().id
        val work=save.readback(account,id,document){true}!!
        val job=save.schedule(CoroutineScope(parent),work,dispatcher)!!;dispatcher.drain()
        assertTrue(job.isCompleted);assertEquals(0,f.server.requestCount)
        save.enter(account);assertFalse("Never-entered GET must release busy",save.state.value.busy)
        val fresh=save.readback(account,id,document){true};assertNotNull(fresh)
        work();assertEquals(0,f.server.requestCount);assertTrue(save.state.value.busy)
        save.schedule(CoroutineScope(parent),fresh,dispatcher);dispatcher.drain();assertFalse(save.state.value.busy)
    }
    @Test fun heldPostCancellationAndRouteLossRemainUncertainAndNonReplayable() = fixture {f,_,account,timeline,save ->
        val received=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
        val live=java.util.concurrent.atomic.AtomicBoolean(true)
        f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(r:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
            received.countDown();check(release.await(5,java.util.concurrent.TimeUnit.SECONDS))
            return mockwebserver3.MockResponse.Builder().code(503).body("{}").build()
        }}
        val executor=java.util.concurrent.Executors.newSingleThreadExecutor();val dispatcher=executor.asCoroutineDispatcher()
        val parent=Job();val jobs=CoroutineScope(parent);val document=timeline.state.value.document
        try {
            val work=save.save(account,document,"Arrangement"){live.get()}!!
            val job=save.schedule(jobs,work,dispatcher)!!
            assertTrue(received.await(5,java.util.concurrent.TimeUnit.SECONDS))
            parent.cancel();live.set(false);release.countDown();runBlocking {job.join()}
            save.enter(account);assertFalse(save.state.value.busy);assertTrue(save.state.value.blocked)
            assertNull(save.save(account,document,"Arrangement"){true});work()
            assertEquals(1,f.server.requestCount)
            assertEquals("POST",f.server.takeRequest(2,java.util.concurrent.TimeUnit.SECONDS)!!.method)
        } finally {release.countDown();parent.cancel();dispatcher.close();executor.shutdownNow()}
    }
    @Test fun staleCompletionCannotClearNewAccountAbaReservationOrPublishItsResult() = fixture {f,session,account,timeline,save ->
        val received=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
        f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(r:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
            received.countDown();check(release.await(5,java.util.concurrent.TimeUnit.SECONDS))
            return mockwebserver3.MockResponse.Builder().code(503).body("{}").build()
        }}
        val executor=java.util.concurrent.Executors.newSingleThreadExecutor();val document=timeline.state.value.document
        try {
            val old=save.readback(account,document.arrangementPlan().id,document){true}!!
            val task=executor.submit {old()};assertTrue(received.await(5,java.util.concurrent.TimeUnit.SECONDS))
            session.accept(session.beginIntent(),SecretTokens("b","r","other"));save.enter(session.capture()!!)
            session.accept(session.beginIntent(),SecretTokens("a","r","fixture"));val next=session.capture()!!
            timeline.observe(next,listOf(TimelineSource("a",7,"Fixture",2000,QueueSegment.Context)))
            val dispatcher=HeldDispatcher();val parent=Job()
            val fresh=save.readback(next,document.arrangementPlan().id,timeline.state.value.document){true}!!
            val job=save.schedule(CoroutineScope(parent),fresh,dispatcher)!!
            release.countDown();task.get(5,java.util.concurrent.TimeUnit.SECONDS)
            assertTrue("Old completion cannot clear a newer reservation",save.state.value.busy)
            assertNull(save.state.value.saved);assertNull(save.state.value.message)
            parent.cancel();dispatcher.drain();assertTrue(job.isCompleted);assertFalse(save.state.value.busy)
            old();assertEquals(1,f.server.requestCount)
        } finally {release.countDown();executor.shutdownNow()}
    }
    @Test fun getExecutesAtMostOnceAndTerminalizesItsOwnPendingMarker() = fixture {f,_,account,timeline,save ->
        val document=timeline.state.value.document
        f.reply("{}",503);f.reply("{}",503)
        val work=save.readback(account,document.arrangementPlan().id,document){true}!!
        work();work()
        assertEquals("A recovery callback cannot replay GET",1,f.server.requestCount)
        assertFalse(save.state.value.busy)
    }
}
