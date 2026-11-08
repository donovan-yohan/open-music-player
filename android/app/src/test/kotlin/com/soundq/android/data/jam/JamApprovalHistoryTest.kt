package com.soundq.android.data.jam

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption.*
import java.nio.file.attribute.FileTime
import java.util.UUID

/** Durable consent journal semantics, not backend or canonical queue proof. */
class JamApprovalHistoryTest {
    private val binding="a".repeat(64)
    private val fingerprint="b".repeat(64)
    private val key="c".repeat(64)
    private fun id()=UUID.randomUUID().toString()
    private fun fixture(work:(File)->Unit) {
        val directory=Files.createTempDirectory(File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"jam-approval-").toFile()
        try {work(File(directory,"history.json"))}finally {directory.deleteRecursively()}
    }
    @Test fun unknownApprovalReopensExactPayloadAndDoesNotGrantAdmission()=fixture {file ->
        val request=id();val original=ApprovalIntent(fingerprint,7,"fixture-service:1",id())
        AdmissionHistory(file,binding).beginApproval(request,original)
        val reopened=AdmissionHistory(file,binding)
        assertEquals(original,reopened.approval(request));assertFalse(reopened.attempted(request))
        assertTrue(runCatching {reopened.begin(request,key)}.isFailure)
        assertEquals(original,reopened.beginApproval(request,original.copy(expectedVersion=99,generation=id())))
        assertEquals(original,AdmissionHistory(file,binding).approval(request))
    }
    @Test fun confirmedKeyCannotRebindAndNativeAttemptRemainsIndependent()=fixture {file ->
        val request=id();val intent=ApprovalIntent(fingerprint,1,"fixture-service:1",id())
        val history=AdmissionHistory(file,binding);history.beginApproval(request,intent);history.confirmApproval(request,key)
        assertFalse(history.attempted(request));assertTrue(history.begin(request,key))
        assertTrue(runCatching {history.confirmApproval(request,"d".repeat(64))}.isFailure)
        assertTrue(runCatching {history.beginApproval(request,intent.copy(fingerprint="d".repeat(64)))}.isFailure)
        assertTrue(runCatching {history.beginApproval(request,intent.copy(hostSession="different-service:1"))}.isFailure)
        val reopened=AdmissionHistory(file,binding);assertEquals(key,reopened.approval(request)!!.admissionKey)
        assertTrue(reopened.approval(request)!!.confirmed);assertTrue(reopened.attempted(request));assertNull(reopened.receipt(request,key))
    }
    @Test fun qualifiedLineageAdvancesOnlySameSessionAndExactPriorGeneration()=fixture {file ->
        val history=AdmissionHistory(file,binding);val before=id();val after=id();val other=id()
        val a=id();val b=id();val foreign=id();val replaced=id()
        history.beginApproval(a,ApprovalIntent(fingerprint,1,"same:1",before));history.confirmApproval(a,key)
        history.beginApproval(b,ApprovalIntent(fingerprint,2,"same:1",before))
        history.beginApproval(foreign,ApprovalIntent(fingerprint,3,"different:1",before))
        history.beginApproval(replaced,ApprovalIntent(fingerprint,4,"same:1",other))
        history.advanceApprovals("same:1",before,after)
        val reopened=AdmissionHistory(file,binding)
        assertEquals(after,reopened.approval(a)!!.generation);assertEquals(after,reopened.approval(b)!!.generation)
        assertEquals(before,reopened.approval(foreign)!!.generation);assertEquals(other,reopened.approval(replaced)!!.generation)
        assertFalse(reopened.approval(b)!!.confirmed);assertFalse(reopened.attempted(a))
    }
    @Test fun oldUnknownAttemptMigratesWithoutInventingApprovalOrPermittingReplay()=fixture {file ->
        val request=id()
        file.writeText("""{"version":1,"binding":"$binding","attempts":[{"requestId":"$request","admissionKey":null,"receipt":null}]}""")
        val history=AdmissionHistory(file,binding);assertTrue(history.attempted(request));assertNull(history.approval(request));assertFalse(history.begin(request))
        val next=id();history.beginApproval(next,ApprovalIntent(fingerprint,2,"fixture-service:1",id()))
        val reopened=AdmissionHistory(file,binding);assertTrue(reopened.attempted(request));assertNull(reopened.approval(request));assertNotNull(reopened.approval(next))
        assertFalse(reopened.begin(request))
    }
    @Test fun staleJournalOwnerCannotConfirmAfterIdenticalByteFileReplacement()=fixture {file ->
        val request=id();val history=AdmissionHistory(file,binding);history.beginApproval(request,ApprovalIntent(fingerprint,1,"fixture-service:1",id()))
        val bytes=file.readBytes();check(file.delete());file.writeBytes(bytes)
        assertTrue(runCatching {history.confirmApproval(request,key)}.isFailure)
        assertArrayEquals(bytes,file.readBytes());assertFalse(history.approval(request)!!.confirmed)
        assertFalse(AdmissionHistory(file,binding).approval(request)!!.confirmed)
    }
    @Test fun staleJournalOwnerCannotConfirmAfterDistinctIdenticalByteAtomicReplacement()=fixture {file ->
        val request=id();val history=AdmissionHistory(file,binding);history.beginApproval(request,ApprovalIntent(fingerprint,1,"fixture-service:1",id()))
        val bytes=file.readBytes();val replacement=File(file.parentFile,"replacement.new").apply {writeBytes(bytes)}
        Files.move(replacement.toPath(),file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
        assertTrue(runCatching {history.confirmApproval(request,key)}.isFailure)
        assertArrayEquals(bytes,file.readBytes());assertFalse(history.approval(request)!!.confirmed)
        assertFalse(AdmissionHistory(file,binding).approval(request)!!.confirmed)
    }
    @Test fun changedJournalTimestampCannotRenewRetainedWriterEvenWithIdenticalBytes()=fixture {file ->
        val request=id();val history=AdmissionHistory(file,binding);history.beginApproval(request,ApprovalIntent(fingerprint,1,"fixture-service:1",id()))
        val bytes=file.readBytes();val changed=FileTime.fromMillis(0)
        assertNotEquals(changed,Files.getLastModifiedTime(file.toPath()))
        Files.setLastModifiedTime(file.toPath(),changed)
        assertTrue(runCatching {history.confirmApproval(request,key)}.isFailure)
        assertArrayEquals(bytes,file.readBytes());assertFalse(history.approval(request)!!.confirmed)
        assertFalse(AdmissionHistory(file,binding).approval(request)!!.confirmed)
    }
    @Test fun sameOwnerCanCommitAgainAndReopenedOwnerCanConfirmDespiteSiblingDirectoryWrites()=fixture {file ->
        val request=id();val history=AdmissionHistory(file,binding);val intent=ApprovalIntent(fingerprint,1,"fixture-service:1",id())
        history.beginApproval(request,intent)
        File(file.parentFile,"unrelated").writeText("unrelated")
        history.confirmApproval(request,key)
        val reopened=AdmissionHistory(file,binding);assertTrue(reopened.approval(request)!!.confirmed)
        val next=id();reopened.beginApproval(next,intent);reopened.confirmApproval(next,key)
        assertTrue(AdmissionHistory(file,binding).approval(next)!!.confirmed)
    }
    @Test fun changedJournalBytesRefuseWithoutDiscardingReplacementEvidence()=fixture {file ->
        val request=id();val history=AdmissionHistory(file,binding);history.beginApproval(request,ApprovalIntent(fingerprint,1,"fixture-service:1",id()))
        file.appendText(" ");val bytes=file.readBytes()
        assertTrue(runCatching {history.confirmApproval(request,key)}.isFailure)
        assertArrayEquals(bytes,file.readBytes());assertFalse(history.approval(request)!!.confirmed)
        assertFalse(AdmissionHistory(file,binding).approval(request)!!.confirmed)
    }
    @Test fun boundedApprovalsRefuseEvictionOrSilentOverwrite()=fixture {file ->
        val history=AdmissionHistory(file,binding)
        repeat(50){history.beginApproval(id(),ApprovalIntent(fingerprint,1,"fixture-service:1",id()))}
        val before=file.readBytes()
        assertTrue(runCatching {history.beginApproval(id(),ApprovalIntent(fingerprint,1,"fixture-service:1",id()))}.isFailure)
        assertArrayEquals(before,file.readBytes());assertEquals(50,AdmissionHistory(file,binding).approvals().size)
    }
}
