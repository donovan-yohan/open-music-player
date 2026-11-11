package com.soundq.android.data.jam

import com.soundq.android.data.*
import com.soundq.android.playback.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Metadata/transport models only; actual service and device gates are separate. */
class JamCanonicalEvidenceTest {
    private fun id()=UUID.randomUUID().toString()
    private fun identity()=JamOccurrence("c".repeat(64),id(),"synthetic-service:1")
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","owner"))}
    @Test fun exactKeyTravelsWithCanonicalOccurrenceWithoutDedupingOrdinaryAba() {
        val identity=identity()
        val saved=QueueSnapshot("endpoint","owner",listOf(SavedOccurrence("a",7,"A","",false),SavedOccurrence("b",9,"B","",true,jam=identity),SavedOccurrence("a2",7,"A","",false)),1,1800)
        val reopened=QueueSnapshot.decode(saved.encode(),"endpoint","owner")!!
        assertEquals(saved,reopened);assertEquals(listOf("a","b","a2"),reopened.items.map {it.occurrence})
        assertEquals(identity,reopened.items[1].jam);assertEquals(1800L,reopened.position)
        assertNull(QueueSnapshot.decode(saved.encode(),"other","owner"));assertNull(QueueSnapshot.decode(saved.encode(),"endpoint","other"))
    }
    @Test fun duplicateCanonicalKeyOrMalformedMetadataIsRejectedNotSilentlyDropped() {
        val identity=identity();val item=SavedOccurrence("a",7,"A","",true,jam=identity)
        val duplicate=QueueSnapshot("endpoint","owner",listOf(item,item.copy(occurrence="b")),0,0)
        assertNull(QueueSnapshot.decode(duplicate.encode(),"endpoint","owner"))
        val valid=duplicate.copy(items=listOf(item)).encode()
        assertNull(QueueSnapshot.decode(valid.replace(identity.admissionKey,"bad"),"endpoint","owner"))
        assertTrue(runCatching {JamOccurrence(identity.admissionKey,"123E4567-e89b-42d3-a456-426614174000",identity.sessionId)}.isFailure)
    }
    @Test fun oldQueueObservationStillHasIndependentRepeatedHostOccurrences() {
        val raw="""{"version":1,"endpoint":"endpoint","account":"owner","selected":0,"position":0,"items":[{"occurrence":"a","track":7,"title":"A","artist":"","manual":false},{"occurrence":"b","track":7,"title":"A","artist":"","manual":true}]}"""
        val saved=QueueSnapshot.decode(raw,"endpoint","owner")!!
        assertEquals(2,saved.items.size);assertTrue(saved.items.all {it.jam==null})
    }
    @Test fun readOnlyLookupCannotFallThroughAnOldInsertionAdapter() {
        val session=session();val scope=session.capture()!!;val port=JamAdmissionPort(session)
        port.attachOwner(id());port.bindAccount(scope);val host=port.hostSession(scope)!!;val key=JamOccurrence("c".repeat(64),id(),host);var inserts=0
        assertTrue(runCatching {port.lookupApproved(scope,Track(TrackId(7),"Owned"),key.requestId,port.incarnation!!,host,key,{true}) {ticket ->
            assertFalse(port.consume(ticket){inserts++;"forbidden"})
        }}.isFailure)
        assertEquals(0,inserts)
    }
    @Test fun lookupReceivesExactIdentityAndReturnsOnlyHandlerEvidenceWithoutChangingGeneration() {
        val session=session();val scope=session.capture()!!;val port=JamAdmissionPort(session)
        port.attachOwner(id());port.bindAccount(scope);val host=port.hostSession(scope)!!;val before=port.incarnation!!;val key=JamOccurrence("c".repeat(64),id(),host)
        val receipt=port.lookupApproved(scope,Track(TrackId(7),"Owned"),key.requestId,before,host,key,{true}) {ticket ->
            assertTrue(port.consumeWithProvenance(ticket){track,observed,lookupOnly ->
                assertTrue(lookupOnly);assertEquals(key,observed);assertEquals(TrackId(7),track.id);"synthetic-existing-occurrence"
            })
        }
        assertEquals("synthetic-existing-occurrence",receipt.occurrenceId);assertEquals(host,receipt.sessionId)
        assertEquals(before,port.incarnation);assertEquals(before,receipt.ownerAfter)
    }
    @Test fun changedRequestOrHostCannotRebindAValidLookingKey() {
        val session=session();val scope=session.capture()!!;val port=JamAdmissionPort(session)
        port.attachOwner(id());port.bindAccount(scope);val host=port.hostSession(scope)!!;val key=JamOccurrence("c".repeat(64),id(),host);var sends=0
        assertTrue(runCatching {port.lookupApproved(scope,Track(TrackId(7),"Owned"),id(),port.incarnation!!,host,key,{true}){sends++}}.isFailure)
        assertTrue(runCatching {port.lookupApproved(scope,Track(TrackId(7),"Owned"),key.requestId,port.incarnation!!,"other",key,{true}){sends++}}.isFailure)
        assertEquals(0,sends)
    }
}
