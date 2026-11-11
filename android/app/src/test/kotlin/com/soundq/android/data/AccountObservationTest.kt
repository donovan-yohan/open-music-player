package com.soundq.android.data

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.coroutines.CoroutineContext

class AccountObservationTest {
    /** Normal main posts; its immediate variant resumes inline only on main. */
    private class MainQueue:MainCoroutineDispatcher() {
        private val owner=Thread.currentThread()
        private val tasks=ConcurrentLinkedQueue<Runnable>()
        override val immediate:MainCoroutineDispatcher=object:MainCoroutineDispatcher() {
            override val immediate:MainCoroutineDispatcher get()=this
            override fun isDispatchNeeded(context:CoroutineContext)=Thread.currentThread()!==owner
            override fun dispatch(context:CoroutineContext,block:Runnable){tasks.add(block)}
        }
        override fun isDispatchNeeded(context:CoroutineContext)=true
        override fun dispatch(context:CoroutineContext,block:Runnable){tasks.add(block)}
        fun drain() {
            check(Thread.currentThread()===owner)
            repeat(1000){val next=tasks.poll() ?: return;next.run()}
            error("Observer queue failed to settle within bounded drain")
        }
    }
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore()).apply {
        assertTrue(accept(beginIntent(),SecretTokens("fixture-access","fixture-refresh","A")))
    }
    @Test fun localUnlockNeverRunsRepositoryCallbackInsideSessionPublicationMonitor() {
        val main=MainQueue();val work=CoroutineScope(SupervisorJob()+main);val session=session()
        val observed=mutableListOf<Pair<AccountObservation,Boolean>>()
        try {
            work.observeAccountState(session,main){observed.add(it to Thread.holdsLock(session))}
            main.drain();observed.clear()
            assertTrue(session.lockLocal())
            assertTrue(session.completeLocalUnlock(session.localUnlockTicket()!!))
            assertTrue("Account callback ran before publication returned; inverse repository locks can deadlock",observed.isEmpty())
            main.drain()
            assertTrue(observed.isNotEmpty())
            assertTrue(observed.none {it.second})
            assertEquals(AuthState.SignedIn("A"),observed.last().first.state)
        } finally {work.cancel();main.drain()}
    }
    @Test fun equalTerminalAuthAfterUndrainedLockUnlockStillObservesNewCapabilityEpoch() {
        val main=MainQueue();val work=CoroutineScope(SupervisorJob()+main);val session=session()
        val observed=mutableListOf<AccountObservation>();val old=session.capture()!!
        try {
            work.observeAccountState(session,main){observed.add(it)}
            main.drain();observed.clear()
            val publisher=Thread {
                check(session.lockLocal())
                check(session.completeLocalUnlock(session.localUnlockTicket()!!))
            }
            publisher.start();publisher.join(5000);assertFalse(publisher.isAlive)
            assertFalse(session.current(old));assertFalse(session.remoteCurrent(old))
            main.drain()
            assertTrue("Conflated equal SignedIn state lost capability-epoch invalidation",observed.isNotEmpty())
            assertEquals(AuthState.SignedIn("A"),observed.last().state)
            assertEquals(session.version(),observed.last().revision)
            assertTrue(observed.last().revision>old.epoch)
            assertTrue(session.remoteCurrent(session.capture()!!))
        } finally {work.cancel();main.drain()}
    }
    @Test fun queuedRetirementReconcilesCurrentReplacementNotStaleAccountCleanup() {
        val main=MainQueue();val work=CoroutineScope(SupervisorJob()+main);val session=session()
        val observed=mutableListOf<AccountObservation>();val old=session.capture()!!
        try {
            work.observeAccountState(session,main){observed.add(it)}
            main.drain();observed.clear()
            val publisher=Thread {
                session.retire()
                check(session.accept(session.beginIntent(),SecretTokens("new-fixture-access","new-fixture-refresh","B")))
            }
            publisher.start();publisher.join(5000);assertFalse(publisher.isAlive)
            main.drain()
            assertTrue(observed.isNotEmpty())
            assertTrue(observed.all {it.state==AuthState.SignedIn("B")&&it.revision==session.version()})
            assertFalse(session.remoteCurrent(old))
            assertEquals("B",session.capture()!!.accountId)
        } finally {work.cancel();main.drain()}
    }
}
