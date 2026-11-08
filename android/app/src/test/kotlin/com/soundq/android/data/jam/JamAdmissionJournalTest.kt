package com.soundq.android.data.jam

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption.*
import java.util.UUID

/** Real file custody and actual ticket receipt; not Android queue/runtime proof. */
class JamAdmissionJournalTest {
    private val binding="b".repeat(64)
    private val key="a".repeat(64)
    private fun owned(work:(File)->Unit) {
        val root=Files.createTempDirectory(File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"jam-journal-").toFile()
        try {work(root)}finally {root.deleteRecursively()}
    }
    @Test fun unknownAttemptSurvivesNewReaderAndCannotBeReplayedOrRebound()=owned {root ->
        val file=File(root,"admission.json");val id=UUID.randomUUID().toString()
        assertTrue(AdmissionHistory(file,binding).begin(id,key))
        val bytes=file.readBytes();val reopened=AdmissionHistory(file,binding)
        assertTrue(reopened.attempted(id));assertNull(reopened.receipt(id,key));assertFalse(reopened.begin(id,key))
        assertThrows(IllegalArgumentException::class.java){reopened.receipt(id,"c".repeat(64))}
        assertArrayEquals(bytes,file.readBytes())
    }
    @Test fun actualTicketReceiptAndPostInsertionGenerationSurviveReopenWithoutAnotherOwnerCall()=owned {root ->
        val file=File(root,"admission.json");val id=UUID.randomUUID().toString();val history=AdmissionHistory(file,binding)
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","synthetic-owner"))}
        val port=JamAdmissionPort(session);val before=port.replaceOwner();var ownerCalls=0
        assertTrue(history.begin(id,key))
        val receipt=port.request(session.capture()!!,Track(TrackId(7),"Synthetic owned track"),id,before,{true}) {ticket ->
            port.consume(ticket){ownerCalls++;port.replaceOwner();"actual-ticket-occurrence"}
        }
        history.admitted(id,receipt)
        val reopened=AdmissionHistory(file,binding)
        assertEquals(receipt,reopened.receipt(id,key));assertEquals(1,ownerCalls)
        assertFalse(reopened.begin(id,key));assertEquals(1,ownerCalls)
        val bytes=file.readBytes()
        assertThrows(IllegalArgumentException::class.java){reopened.admitted(id,null)}
        assertArrayEquals(bytes,file.readBytes())
    }
    @Test fun staleReaderCannotOverwriteAnotherAcceptedAttemptOrReceipt()=owned {root ->
        val file=File(root,"admission.json");val first=AdmissionHistory(file,binding);val stale=AdmissionHistory(file,binding)
        val id=UUID.randomUUID().toString();assertTrue(first.begin(id,key));val bytes=file.readBytes()
        assertThrows(IllegalStateException::class.java){stale.begin(UUID.randomUUID().toString(),key)}
        assertArrayEquals(bytes,file.readBytes());assertTrue(AdmissionHistory(file,binding).attempted(id))
    }
    @Test fun corruptFutureAndWrongOwnerBindingsRefuseWithoutChangingEvidence()=owned {root ->
        val file=File(root,"admission.json");AdmissionHistory(file,binding).begin(UUID.randomUUID().toString(),key)
        val valid=file.readBytes()
        assertThrows(IllegalArgumentException::class.java){AdmissionHistory(file,"c".repeat(64))}
        assertArrayEquals(valid,file.readBytes())
        file.writeText("{\"version\":2,\"binding\":\"$binding\",\"attempts\":[]}")
        val future=file.readBytes();assertThrows(IllegalArgumentException::class.java){AdmissionHistory(file,binding)}
        assertArrayEquals(future,file.readBytes())
    }
    @Test fun byteIdenticalFileReplacementDoesNotGrantRetainedWriterCustody()=owned {root ->
        val file=File(root,"admission.json");val history=AdmissionHistory(file,binding);val id=UUID.randomUUID().toString();history.begin(id,key)
        val bytes=file.readBytes();val foreign=File(root,"foreign.new").apply {writeBytes(bytes)}
        Files.move(foreign.toPath(),file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
        assertThrows(IllegalStateException::class.java){history.admitted(id,AdmissionReceipt(id,"session","occurrence"))}
        assertArrayEquals(bytes,file.readBytes())
    }
    @Test fun byteIdenticalDirectoryReplacementAndAliasDoNotGrantCustody()=owned {root ->
        val directory=File(root,"scope").apply {mkdir()};val file=File(directory,"admission.json")
        val history=AdmissionHistory(file,binding);val id=UUID.randomUUID().toString();history.begin(id,key);val bytes=file.readBytes()
        val held=File(root,"held");assertTrue(directory.renameTo(held));assertTrue(directory.mkdir());file.writeBytes(bytes)
        assertThrows(IllegalStateException::class.java){history.begin(UUID.randomUUID().toString(),key)}
        assertArrayEquals(bytes,file.readBytes());assertArrayEquals(bytes,File(held,"admission.json").readBytes())
        val alias=File(root,"alias");Files.createSymbolicLink(alias.toPath(),directory.toPath())
        assertThrows(IllegalArgumentException::class.java){AdmissionHistory(File(alias,"admission.json"),binding)}
    }
    @Test fun fullPartyHistoryRefusesOverflowWithoutEvictingUnknownAttempts()=owned {root ->
        val file=File(root,"admission.json");val history=AdmissionHistory(file,binding);val ids=List(50){UUID.randomUUID().toString()}
        ids.forEach {assertTrue(history.begin(it,key))};val bytes=file.readBytes()
        assertFalse(history.begin(UUID.randomUUID().toString(),key));assertArrayEquals(bytes,file.readBytes())
        val reopened=AdmissionHistory(file,binding);ids.forEach {assertTrue(reopened.attempted(it));assertNull(reopened.receipt(it,key))}
        assertTrue(file.length()<=65536)
    }
}
