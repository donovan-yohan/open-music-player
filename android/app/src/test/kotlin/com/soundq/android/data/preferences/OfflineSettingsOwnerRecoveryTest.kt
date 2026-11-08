package com.soundq.android.data.preferences

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class OfflineSettingsOwnerRecoveryTest {
    @Test fun storageCaptureCannotMutateAnotherInstallationOwnerAtTheSameRevision() {
        val dir=Files.createTempDirectory("storage-owner-recovery-").toFile()
        try {
            val first=StoragePreferences(dir.resolve("first")).also {it.load()}
            val targetFile=dir.resolve("second")
            val second=StoragePreferences(targetFile).also {it.load()}
            assertFalse("A revision is not owner identity",second.setTemporaryAudio(first.capture()!!,false){true})
            assertTrue(second.state.value.temporaryAudioEnabled)
            assertFalse(targetFile.exists())
            assertTrue(second.setTemporaryAudio(second.capture()!!,false){true})
            assertFalse(StoragePreferences(targetFile).also {it.load()}.state.value.temporaryAudioEnabled)
        } finally {dir.deleteRecursively()}
    }

    @Test fun endOfQueueCaptureCannotMutateAnotherInstallationOwnerAtTheSameRevision() {
        val dir=Files.createTempDirectory("end-queue-owner-recovery-").toFile()
        try {
            val first=EndOfQueuePreferences(dir.resolve("first")).also {it.load()}
            val targetFile=dir.resolve("second")
            val second=EndOfQueuePreferences(targetFile).also {it.load()}
            assertFalse("A revision is not owner identity",second.setMode(first.capture()!!,EndOfQueue.Off){true})
            assertEquals(EndOfQueue.ShuffleLibrary,second.state.value.mode)
            assertFalse(targetFile.exists())
            assertTrue(second.setMode(second.capture()!!,EndOfQueue.Off){true})
            assertEquals(EndOfQueue.Off,EndOfQueuePreferences(targetFile).also {it.load()}.state.value.mode)
        } finally {dir.deleteRecursively()}
    }

    @Test fun failedSettingsWritesKeepAcceptedValuesUntilExplicitReloadAndFreshIntent() {
        val dir=Files.createTempDirectory("settings-failed-store-").toFile()
        try {
            val parent=dir.resolve("blocked").also {it.writeText("keep")}
            val storage=StoragePreferences(parent.resolve("storage")).also {it.load()}
            val end=EndOfQueuePreferences(parent.resolve("end")).also {it.load()}
            val s=storage.capture()!!;val e=end.capture()!!
            assertFalse(storage.setTemporaryAudio(s,false){true})
            assertFalse(end.setMode(e,EndOfQueue.Off){true})
            assertTrue(storage.state.value.temporaryAudioEnabled)
            assertEquals(EndOfQueue.ShuffleLibrary,end.state.value.mode)
            assertTrue(storage.state.value.error);assertTrue(end.state.value.error)
            assertEquals("keep",parent.readText())
            assertTrue(parent.delete());assertTrue(parent.mkdir())
            assertFalse(storage.setTemporaryAudio(s,false){true})
            assertFalse(end.setMode(e,EndOfQueue.Off){true})
            storage.load();end.load()
            assertTrue(storage.setTemporaryAudio(storage.capture()!!,false){true})
            assertTrue(end.setMode(end.capture()!!,EndOfQueue.Off){true})
            assertFalse(StoragePreferences(parent.resolve("storage")).also {it.load()}.state.value.temporaryAudioEnabled)
            assertEquals(EndOfQueue.Off,EndOfQueuePreferences(parent.resolve("end")).also {it.load()}.state.value.mode)
        } finally {dir.deleteRecursively()}
    }
}
