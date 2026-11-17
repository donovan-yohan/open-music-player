package com.soundq.android.data.imports

import com.soundq.android.data.*
import com.soundq.android.data.acquisition.IntakeReceipt
import org.junit.Assert.*
import org.junit.Test

/** Real journal + exact HTTPS job reads; no progress-owned mutation or invented job status. */
class ImportProgressUncertaintyTest {
    private val jobId="123e4567-e89b-12d3-a456-000000004001"
    private val decisionId="123e4567-e89b-12d3-a456-000000004002"
    private inner class Harness:AutoCloseable {
        val wire=HttpsFixture()
        val session=AccountSession(wire.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
        val api=SoundQApi(session,wire.client)
        val progress=ImportProgressObservation(session,api)
        val journal=api.intakeReceipts
        val endpoint=session.endpoint.identity
        var now=0L
        init {progress.clock={now};progress.visible(true)}
        fun begin(kind:String="download",account:String="A")=journal.begin(endpoint,account,kind)
        fun finish(row:IntakeReceipt,phase:String,job:String?=null,account:String="A") {
            journal.finish(endpoint,account,row,phase,job,if(row.kind=="source"&&phase=="accepted")decisionId else null)
        }
        fun uncertain(lease:ImportProgressObservation.Lease,kind:String="download"):IntakeReceipt {
            val requests=wire.server.requestCount
            val row=begin(kind);finish(row,"uncertain");progress.receipts(lease)
            assertTrue(progress.state.value!!.needsChecking)
            assertEquals(requests,wire.server.requestCount)
            assertEquals(0,progress.state.value!!.unknown)
            assertNull(progress.nextDelay(lease))
            return row
        }
        fun renew():ImportProgressObservation.Lease {
            progress.visible(false);assertNull(progress.state.value)
            progress.visible(true);return progress.open()!!
        }
        fun read(lease:ImportProgressObservation.Lease,status:String="queued",id:String=jobId) {
            wire.reply("""{"job_id":"$id","status":"$status","progress":100,"track_id":null,"source_type":"youtube","created_at":"2026-11-14T12:00:00Z"}""")
            progress.refresh(lease)
            val request=wire.server.takeRequest(3,java.util.concurrent.TimeUnit.SECONDS)
            assertNotNull("exact job GET must actually dispatch",request)
            assertEquals("GET",request!!.method)
            assertEquals("/api/v1/downloads/$id",request.url.encodedPath)
        }
        override fun close(){progress.retire();wire.close()}
    }

    private fun settleDownload(renew:Boolean) {
        Harness().use {h ->
            val old=h.progress.open()!!;val operation=h.uncertain(old)
            val lease=if(renew)h.renew() else old
            h.finish(operation,"accepted",jobId)
            if(renew) {
                h.progress.receipts(old);h.progress.refresh(old)
                assertFalse(h.progress.current(old));assertTrue(h.progress.state.value!!.needsChecking)
                assertEquals(0,h.wire.server.requestCount)
            }
            h.progress.receipts(lease)
            assertEquals("ACK is not a job observation",1,h.progress.state.value!!.unknown)
            assertEquals(0,h.progress.state.value!!.complete)
            assertFalse(h.progress.state.value!!.needsChecking)
            h.read(lease)
            assertEquals(1,h.progress.state.value!!.active)
            assertEquals(0,h.progress.state.value!!.complete)
            assertEquals(1,h.wire.server.requestCount)
            assertEquals("accepted",h.journal.entries(h.endpoint,"A").single().phase)
        }
    }
    @Test fun sameForegroundUncertaintySettlesOnlyThroughExactJobRead()=settleDownload(false)
    @Test fun observedUncertaintyRemainsSettleableAfterForegroundRenewal()=settleDownload(true)

    private fun settleDecision(renew:Boolean) {
        Harness().use {h ->
            var lease=h.progress.open()!!;val source=h.uncertain(lease,"source")
            if(renew)lease=h.renew()
            h.finish(source,"accepted")
            // A separately published queue operation, not the source decision, owns this exact job.
            val queued=h.begin("queue");h.finish(queued,"accepted",jobId)
            h.progress.receipts(lease)
            assertFalse("decision-only settlement must clear only its uncertainty",h.progress.state.value!!.needsChecking)
            assertEquals(1,h.progress.state.value!!.unknown);assertEquals(0,h.progress.state.value!!.complete)
            h.read(lease,"complete")
            assertEquals(1,h.progress.state.value!!.complete);assertEquals(0,h.progress.state.value!!.active)
            assertFalse(h.progress.state.value!!.needsChecking)
            h.now+=ImportProgressObservation.DWELL_MS-1;h.progress.advance(lease)
            assertEquals(1,h.progress.state.value!!.complete)
            h.now++;h.progress.advance(lease);assertNull(h.progress.state.value)
            assertNull(h.progress.nextDelay(lease));assertEquals(1,h.wire.server.requestCount)
            assertEquals(listOf("accepted","accepted"),h.journal.entries(h.endpoint,"A").map {it.phase})
        }
    }
    @Test fun acceptedDecisionWithoutJobAllowsSeparateCompletedJobToDwellAndDisappear()=settleDecision(false)
    @Test fun acceptedDecisionWithoutJobAlsoSettlesAfterForegroundRenewal()=settleDecision(true)

    @Test fun acceptedOrRefusedNoJobSettlesOnlyItsOperationWithoutInventingCounts() {
        for(kind in listOf("download","source","queue"))for(phase in listOf("accepted","refused"))for(renew in listOf(false,true)) {
            Harness().use {h ->
                var lease=h.progress.open()!!;val row=h.uncertain(lease,kind)
                if(renew)lease=h.renew()
                h.finish(row,phase);h.progress.receipts(lease);h.progress.refresh(lease)
                assertNull("$kind/$phase/renew=$renew has no job to count",h.progress.state.value)
                assertNull(h.progress.nextDelay(lease));assertEquals(0,h.wire.server.requestCount)
                assertEquals(phase,h.journal.entries(h.endpoint,"A").single().phase)
            }
        }
    }

    private fun freshJobAfterNoJobSettlement(phase:String,coalesced:Boolean) {
        for(kind in listOf("source","download","queue"))Harness().use {h ->
            val lease=h.progress.open()!!
            // A completed earlier job leaves real handled/seen boundaries on this same lease.
            val previous=h.begin();h.finish(previous,"accepted",jobId)
            h.progress.receipts(lease);h.read(lease,"complete")
            h.now+=ImportProgressObservation.DWELL_MS;h.progress.advance(lease)
            assertNull(h.progress.state.value)
            val row=h.uncertain(lease,kind)
            val old=h.progress.state.value!!
            if(coalesced)h.now+=ImportProgressObservation.EXPIRY_MS+1
            h.finish(row,phase)
            if(!coalesced) {
                h.progress.receipts(lease);h.progress.refresh(lease)
                assertNull(h.progress.state.value);assertNull(h.progress.nextDelay(lease))
                repeat(3){h.progress.receipts(lease);h.progress.refresh(lease)}
                assertNull("settled receipts cannot reopen an empty episode",h.progress.state.value)
                h.now+=ImportProgressObservation.EXPIRY_MS+1
            }
            val freshId="123e4567-e89b-12d3-a456-000000004003"
            val fresh=h.begin();h.finish(fresh,"accepted",freshId)
            val settled=h.journal.entries(h.endpoint,"A")
            // In the coalesced schedule this one pass both settles the old row and admits the new job.
            h.progress.receipts(lease)
            assertEquals(1,h.progress.state.value!!.unknown)
            assertFalse(h.progress.state.value!!.needsChecking)
            h.read(lease,id=freshId)
            val active=h.progress.state.value!!
            assertTrue("$kind/$phase/coalesced=$coalesced needs a new bounded episode",active.identity>old.identity)
            assertEquals(listOf(1,0,0,0),listOf(active.active,active.complete,active.failed,active.unknown))
            assertFalse(active.needsChecking);assertFalse(h.progress.owns(old))
            assertEquals(ImportProgressObservation.POLL_MS,h.progress.nextDelay(lease))
            assertEquals(2,h.wire.server.requestCount)
            assertEquals(setOf(previous.operation,row.operation,fresh.operation),lease.handled)
            assertEquals(setOf(jobId,freshId).map {java.util.UUID.fromString(it)}.toSet(),lease.seenJobs)
            assertEquals(settled,h.journal.entries(h.endpoint,"A"))
            // Repeated handled receipts and a new receipt for a seen job are both no-ops.
            val duplicate=h.begin("queue");h.finish(duplicate,"accepted",jobId)
            val unchanged=h.journal.entries(h.endpoint,"A")
            repeat(3){h.progress.receipts(lease);h.progress.refresh(lease)}
            assertEquals(active,h.progress.state.value);assertEquals(2,h.wire.server.requestCount)
            assertEquals(unchanged,h.journal.entries(h.endpoint,"A"))
            h.now+=ImportProgressObservation.POLL_MS;h.read(lease,"complete",freshId)
            assertEquals(1,h.progress.state.value!!.complete)
            h.now+=ImportProgressObservation.DWELL_MS;h.progress.advance(lease)
            repeat(3){h.progress.receipts(lease);h.progress.refresh(lease)}
            assertNull(h.progress.state.value);assertNull(h.progress.nextDelay(lease))
            assertEquals(3,h.wire.server.requestCount)
            assertEquals(unchanged,h.journal.entries(h.endpoint,"A"))
        }
    }
    @Test fun acceptedNoJobRetiresEmptyEpisodeBeforeFreshJobAfterOldExpiry()=freshJobAfterNoJobSettlement("accepted",false)
    @Test fun refusedNoJobRetiresEmptyEpisodeBeforeFreshJobAfterOldExpiry()=freshJobAfterNoJobSettlement("refused",false)
    @Test fun acceptedNoJobAndFreshJobCoalescedAfterOldExpiryStartNewEpisode()=freshJobAfterNoJobSettlement("accepted",true)
    @Test fun refusedNoJobAndFreshJobCoalescedAfterOldExpiryStartNewEpisode()=freshJobAfterNoJobSettlement("refused",true)

    @Test fun noJobSettlementCannotRenewOtherObservedUncertaintyOrLiveFacts() {
        for(phase in listOf("accepted","refused"))for(liveFact in listOf(false,true))Harness().use {h ->
            val lease=h.progress.open()!!;val row=h.uncertain(lease,"source")
            val old=h.progress.state.value!!
            val other=h.begin()
            h.finish(other,if(liveFact)"accepted" else "uncertain",if(liveFact)jobId else null)
            h.progress.receipts(lease)
            if(liveFact)h.read(lease)
            h.now+=ImportProgressObservation.EXPIRY_MS+1
            h.finish(row,phase);h.progress.receipts(lease)
            if(!liveFact) {
                val fresh=h.begin();h.finish(fresh,"accepted",jobId);h.progress.receipts(lease)
            }
            h.progress.refresh(lease)
            val retained=h.progress.state.value!!
            assertEquals(old.identity,retained.identity)
            assertTrue(retained.needsChecking)
            assertEquals(listOf(0,0,0,1),listOf(retained.active,retained.complete,retained.failed,retained.unknown))
            assertEquals(if(liveFact)1 else 0,h.wire.server.requestCount)
            assertNull(h.progress.nextDelay(lease))
        }
    }

    @Test fun noJobSettlementCannotClearCapacityChecking() {
        for(phase in listOf("accepted","refused"))Harness().use {h ->
            val lease=h.progress.open()!!
            val rows=List(ImportProgressObservation.MAX_JOBS+1){h.begin("source").also {h.finish(it,"uncertain")}}
            h.progress.receipts(lease);val old=h.progress.state.value!!
            rows.forEach {h.finish(it,phase)};h.progress.receipts(lease)
            assertEquals(old.identity,h.progress.state.value!!.identity)
            assertTrue(h.progress.state.value!!.needsChecking)
            assertEquals(0,h.progress.state.value!!.unknown)
            h.now+=ImportProgressObservation.EXPIRY_MS+1
            val fresh=h.begin();h.finish(fresh,"accepted",jobId)
            h.progress.receipts(lease);h.progress.refresh(lease)
            assertEquals(old.identity,h.progress.state.value!!.identity)
            assertTrue(h.progress.state.value!!.needsChecking)
            assertEquals(1,h.progress.state.value!!.unknown)
            assertNull(h.progress.nextDelay(lease));assertEquals(0,h.wire.server.requestCount)
        }
    }

    @Test fun pendingPhaseWithAttachedJobDoesNotClearObservedUncertainty() {
        Harness().use {h ->
            val lease=h.progress.open()!!;val row=h.uncertain(lease,"source")
            h.finish(row,"pending",jobId);h.progress.receipts(lease);h.progress.refresh(lease)
            val state=h.progress.state.value!!
            assertTrue(state.needsChecking)
            assertEquals(listOf(0,0,0,0),listOf(state.active,state.complete,state.failed,state.unknown))
            assertNull(h.progress.nextDelay(lease));assertEquals(0,h.wire.server.requestCount)
            assertEquals("pending",h.journal.entries(h.endpoint,"A").single().phase)
        }
    }

    @Test fun settlingOneOperationCannotBlanketClearOtherUncertainty() {
        Harness().use {h ->
            val lease=h.progress.open()!!
            val first=h.uncertain(lease,"source");val second=h.uncertain(lease)
            h.finish(first,"accepted");h.progress.receipts(lease)
            assertTrue(h.progress.state.value!!.needsChecking);assertEquals(0,h.progress.state.value!!.unknown)
            assertEquals("uncertain",h.journal.entries(h.endpoint,"A").last().phase)
            h.finish(second,"refused");h.progress.receipts(lease)
            assertNull(h.progress.state.value);assertEquals(0,h.wire.server.requestCount)
        }
    }

    @Test fun observedExceptionCannotAdmitHistoricalOrUnobservedPreFloorReceipts() {
        Harness().use {h ->
            val historical=h.begin();h.finish(historical,"uncertain")
            val old=h.progress.open()!!;h.progress.receipts(old);assertNull(h.progress.state.value)
            val known=h.uncertain(old,"source")
            val unobserved=h.begin() // Not reconciled before the foreground boundary.
            h.finish(unobserved,"uncertain")
            val lease=h.renew()
            h.finish(historical,"accepted",jobId);h.finish(unobserved,"accepted",jobId)
            h.finish(known,"accepted");h.progress.receipts(lease);h.progress.refresh(lease)
            assertNull(h.progress.state.value);assertNull(h.progress.nextDelay(lease))
            assertEquals(0,h.wire.server.requestCount)
            // A genuinely new publication remains admissible after those exclusions.
            val fresh=h.begin();h.finish(fresh,"accepted",jobId);h.progress.receipts(lease);h.read(lease)
            assertEquals(1,h.progress.state.value!!.active);assertEquals(1,h.wire.server.requestCount)
        }
    }

    @Test fun foreignAndAccountABAResultsCannotUseRetainedOperationIdentity() {
        Harness().use {h ->
            val old=h.progress.open()!!;val known=h.uncertain(old)
            val foreign=h.begin(account="B");h.finish(foreign,"accepted",jobId,"B")
            h.progress.receipts(old);assertTrue(h.progress.state.value!!.needsChecking)
            assertEquals(0,h.wire.server.requestCount)
            h.session.accept(h.session.beginIntent(),SecretTokens("b","r","B"))
            val b=h.progress.open()!!;assertNull(h.progress.state.value)
            h.finish(known,"accepted",jobId)
            h.progress.receipts(old);h.progress.refresh(old);h.progress.receipts(b);h.progress.refresh(b)
            assertNull(h.progress.state.value);assertFalse(h.progress.current(old))
            h.session.accept(h.session.beginIntent(),SecretTokens("a2","r","A"))
            val returned=h.progress.open()!!
            h.progress.receipts(old);h.progress.receipts(b);h.progress.receipts(returned);h.progress.refresh(returned)
            assertNull(h.progress.state.value);assertEquals(0,h.wire.server.requestCount)
            val fresh=h.begin();h.finish(fresh,"accepted",jobId);h.progress.receipts(returned);h.read(returned)
            assertEquals(1,h.progress.state.value!!.active);assertEquals(1,h.wire.server.requestCount)
        }
    }
}
