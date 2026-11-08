package com.soundq.android.data.jam

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicReference

/** Real port/account lifetime behavior; no Android/native insertion claim. */
class JamHostSessionTest {
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","owner"))}
    private fun attached(session:AccountSession)=JamAdmissionPort(session).also {it.attachOwner(UUID.randomUUID().toString());it.bindAccount(session.capture())}

    @Test fun noHostSessionFallbackExistsBeforeActualServiceAndAccountBinding() {
        val session=session();val scope=session.capture()!!;val port=JamAdmissionPort(session)
        port.replaceOwner();assertNull(port.hostSession(scope))
        port.attachOwner(UUID.randomUUID().toString());assertNull(port.hostSession(scope))
        port.bindAccount(scope);assertNotNull(port.hostSession(scope))
        port.detachOwner();assertNull(port.hostSession(scope))
    }
    @Test fun approvedReceiptsKeepActualHostSessionWhileAuthorizedInsertionAdvancesQueueGeneration() {
        val session=session();val scope=session.capture()!!;val port=attached(session);val host=port.hostSession(scope)!!;var inserts=0
        fun insert():AdmissionReceipt {
            val before=port.incarnation!!
            val receipt=port.requestApproved(scope,Track(TrackId(7),"Owned"),UUID.randomUUID().toString(),before,host,{true}) {ticket ->
                assertTrue(port.consume(ticket){inserts++;port.replaceOwner();"occurrence-$inserts"})
            }
            assertNotEquals(before,receipt.ownerAfter);assertEquals(port.incarnation,receipt.ownerAfter)
            return receipt
        }
        val first=insert();val second=insert()
        assertEquals(host,first.sessionId);assertEquals(host,second.sessionId)
        assertNotEquals(first.occurrenceId,second.occurrenceId);assertEquals(2,inserts)
        assertEquals(host,port.hostSession(scope))
    }
    @Test fun stableHostSessionDoesNotWeakenHeldQueueAbaOrConsentFences() {
        for(retireQueue in listOf(false,true)) {
            val session=session();val scope=session.capture()!!;val port=attached(session);val host=port.hostSession(scope)!!;var consent=true;var inserts=0
            assertTrue(runCatching {port.requestApproved(scope,Track(TrackId(7),"Owned"),UUID.randomUUID().toString(),port.incarnation!!,host,{consent}) {ticket ->
                if(retireQueue){port.replaceOwner();port.replaceOwner()}else consent=false
                assertFalse(port.consume(ticket){inserts++;"forbidden"})
            }}.isFailure)
            assertEquals(0,inserts);assertEquals(host,port.hostSession(scope))
        }
    }
    @Test fun lockAndSameAccountAbaRetireAuthorityBeforeCollectorAndNeverReviveOldApproval() {
        val session=session();val scope=session.capture()!!;val port=attached(session);val before=port.hostSession(scope)!!;var inserts=0
        assertTrue(runCatching {port.requestApproved(scope,Track(TrackId(7),"Owned"),UUID.randomUUID().toString(),port.incarnation!!,before,{true}) {ticket ->
            assertTrue(session.lockLocal());assertNull(port.hostSession(scope))
            assertFalse(port.consume(ticket){inserts++;"forbidden"})
        }}.isFailure)
        assertTrue(session.completeLocalUnlock(session.localUnlockTicket()!!));val next=session.capture()!!;port.bindAccount(next)
        assertNotEquals(before,port.hostSession(next));var sends=0
        assertTrue(runCatching {port.requestApproved(next,Track(TrackId(7),"Owned"),UUID.randomUUID().toString(),port.incarnation!!,before,{true}){sends++}}.isFailure)
        assertEquals(0,sends);assertEquals(0,inserts)
        session.accept(session.beginIntent(),SecretTokens("b","br","owner"));assertNull(port.hostSession(next))
        port.bindAccount(session.capture());assertNotEquals(before,port.hostSession(session.capture()!!))
    }
    @Test fun hostReaderNeverHoldsPortMonitorWhileWaitingForAccountMonitor() {
        val session=session();val scope=session.capture()!!;val port=attached(session)
        val pool=Executors.newFixedThreadPool(2){work->Thread(work).apply {isDaemon=true}}
        val holding=CountDownLatch(1);val entered=CountDownLatch(1);val readerThread=AtomicReference<Thread>()
        try {
            val writer=pool.submit {
                synchronized(session) {
                    holding.countDown();assertTrue(entered.await(2,TimeUnit.SECONDS))
                    val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(2)
                    while(readerThread.get().state!=Thread.State.BLOCKED&&System.nanoTime()<deadline)Thread.sleep(1)
                    assertEquals(Thread.State.BLOCKED,readerThread.get().state)
                    port.bindAccount(null)
                }
            }
            assertTrue(holding.await(2,TimeUnit.SECONDS))
            val reader=pool.submit<String?> {readerThread.set(Thread.currentThread());entered.countDown();port.hostSession(scope)}
            writer.get(3,TimeUnit.SECONDS);assertNull(reader.get(3,TimeUnit.SECONDS))
        }finally {pool.shutdownNow()}
    }
}
