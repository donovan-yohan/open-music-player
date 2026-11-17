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
            val row=begin(kind);finish(row,"uncertain");progress.receipts(lease)
            assertTrue(progress.state.value!!.needsChecking)
            assertEquals(0,wire.server.requestCount)
            assertEquals(0,progress.state.value!!.unknown)
            assertNull(progress.nextDelay(lease))
            return row
        }
        fun renew():ImportProgressObservation.Lease {
            progress.visible(false);assertNull(progress.state.value)
            progress.visible(true);return progress.open()!!
        }
        fun read(lease:ImportProgressObservation.Lease,status:String="queued") {
            wire.reply("""{"job_id":"$jobId","status":"$status","progress":100,"track_id":null,"source_type":"youtube","created_at":"2026-11-14T12:00:00Z"}""")
            progress.refresh(lease)
            val request=wire.server.takeRequest(3,java.util.concurrent.TimeUnit.SECONDS)
            assertNotNull("exact job GET must actually dispatch",request)
            assertEquals("GET",request!!.method)
            assertEquals("/api/v1/downloads/$jobId",request.url.encodedPath)
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
