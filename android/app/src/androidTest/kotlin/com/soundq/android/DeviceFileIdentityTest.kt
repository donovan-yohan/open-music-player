package com.soundq.android

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.attribute.BasicFileAttributes

/** Actual Android filesystem provider contract for OFF-1. Compile-only until native owner executes. */
class DeviceFileIdentityTest {
    private fun key(file:File,directory:Boolean):Any {
        val attributes=Files.readAttributes(file.toPath(),BasicFileAttributes::class.java,NOFOLLOW_LINKS)
        assertEquals(directory,attributes.isDirectory)
        assertEquals(!directory,attributes.isRegularFile)
        return assertNotNullKey(attributes.fileKey())
    }
    private fun assertNotNullKey(key:Any?):Any {assertNotNull("Android private filesystem must expose a non-null file identity",key);return key!!}
    @Test fun privateFilesystemKeysSurviveRenameButRejectOrdinaryDirectoryAndFileReplacement() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext
        val root=Files.createTempDirectory(app.noBackupFilesDir.toPath(),"file-identity-").toFile()
        try {
            val dir=File(root,"scope").apply {check(mkdir())};val directoryKey=key(dir,true)
            val stage=File(dir,"stage.part").apply {writeText("owned")};val fileKey=key(stage,false)
            assertEquals(directoryKey,key(dir,true));assertEquals(fileKey,key(stage,false))
            val promoted=File(dir,"promoted.audio")
            Files.move(stage.toPath(),promoted.toPath(),ATOMIC_MOVE)
            assertEquals(fileKey,key(promoted,false));assertEquals(directoryKey,key(dir,true))
            val heldFile=File(dir,"held-original.audio")
            Files.move(promoted.toPath(),heldFile.toPath(),ATOMIC_MOVE)
            promoted.writeText("owned")
            assertNotEquals(fileKey,key(promoted,false));assertEquals(fileKey,key(heldFile,false))
            val heldDir=File(root,"held-original-scope")
            Files.move(dir.toPath(),heldDir.toPath(),ATOMIC_MOVE)
            assertEquals(directoryKey,key(heldDir,true));assertTrue(dir.mkdir())
            assertNotEquals(directoryKey,key(dir,true))
            assertEquals("owned",File(heldDir,"held-original.audio").readText())
        } finally {root.deleteRecursively()}
    }
}
