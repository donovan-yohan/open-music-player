package com.soundq.android.data.jam

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.UUID

class JamRecoveryTargetTest {
    private fun check(work:(File)->Unit) {
        val root=Files.createTempDirectory(File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"jam-target-").toFile()
        try {work(root)}finally {root.deleteRecursively()}
    }
    @Test fun exactTargetRestoresOnlyUnderItsEndpointAccountBindingAndContainsNoWriter()=check {root ->
        val file=File(root,"target.json");val id=UUID.randomUUID().toString();val binding="a".repeat(64)
        JamRecoveryTarget(file,binding).save(id)
        assertEquals(id,JamRecoveryTarget(file,binding).read())
        assertTrue(runCatching {JamRecoveryTarget(file,"b".repeat(64)).read()}.isFailure)
        assertFalse(file.readText().contains("writer"));assertFalse(file.readText().contains("session"))
        JamRecoveryTarget(file,binding).save(null);assertNull(JamRecoveryTarget(file,binding).read())
    }
    @Test fun rejectedTargetIsPreservedAndNeverOverwritten()=check {root ->
        val file=File(root,"target.json");file.writeText("{future or rejected}");val bytes=file.readBytes()
        assertTrue(runCatching {JamRecoveryTarget(file,"a".repeat(64)).save(UUID.randomUUID().toString())}.isFailure)
        assertArrayEquals(bytes,file.readBytes())
    }
    @Test fun symlinkCannotRedirectTargetReadOrWrite()=check {root ->
        val file=File(root,"original.json");val binding="a".repeat(64);JamRecoveryTarget(file,binding).save(UUID.randomUUID().toString())
        val bytes=file.readBytes();val alias=File(root,"alias.json");Files.createSymbolicLink(alias.toPath(),file.toPath())
        assertTrue(runCatching {JamRecoveryTarget(alias,binding).read()}.isFailure)
        assertTrue(runCatching {JamRecoveryTarget(alias,binding).save(null)}.isFailure)
        assertArrayEquals(bytes,file.readBytes())
    }
}
