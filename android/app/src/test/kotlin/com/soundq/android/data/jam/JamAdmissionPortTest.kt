package com.soundq.android.data.jam

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class JamAdmissionPortTest {
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","owner"))}
    @Test fun sameTrackIndependentExplicitRequestsReceiveIndependentManualOccurrenceReceipts() {
        val session=session();val port=JamAdmissionPort(session);port.replaceOwner();val inserted=mutableListOf<Track>()
        fun admit(request:String):AdmissionReceipt {val before=port.incarnation!!;return port.request(session.capture()!!,Track(TrackId(7),"Owned"),request,before,{true}) {ticket->
            assertTrue(port.consume(ticket){track->inserted.add(track);port.replaceOwner();"independent-${inserted.size}"})
        }}
        val first=admit("r1");val second=admit("r2")
        assertEquals(listOf(7L,7L),inserted.map {it.id.value});assertNotEquals(first.occurrenceId,second.occurrenceId);assertNotEquals(first.sessionId,second.sessionId)
    }
    @Test fun queuedTicketRetiredByConsentOrSameAccountAbaCannotReachInsertion() {
        for(aba in listOf(false,true)) {
            val session=session();val port=JamAdmissionPort(session);val before=port.replaceOwner();val scope=session.capture()!!
            var consent=true;var inserts=0
            val future=Executors.newSingleThreadExecutor()
            try {
                val result=future.submit<Boolean> {runCatching {port.request(scope,Track(TrackId(7),"Owned"),"r",before,{consent}) {id->
                    if(aba)session.accept(session.beginIntent(),SecretTokens("b","br","owner"))else consent=false
                    assertFalse(port.consume(id){inserts++;"must-not-exist"})
                }}.isFailure}
                assertTrue(result.get(2,TimeUnit.SECONDS));assertEquals(0,inserts)
            }finally {future.shutdownNow()}
        }
    }
    @Test fun sameContentOwnerReplacementInvalidatesBeforeTicketSend() {
        val session=session();val port=JamAdmissionPort(session);val old=port.replaceOwner();port.replaceOwner();var sends=0
        assertTrue(runCatching {port.request(session.capture()!!,Track(TrackId(7),"same"),"r",old,{true}){sends++}}.isFailure)
        assertEquals(0,sends)
    }
}
