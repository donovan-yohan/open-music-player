package com.soundq.android.data

import com.soundq.android.playback.QueuePolicy
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class QueueSettingsTest {
    @Test fun sameOwnerReloadAfterExternalRepairRecoversWritableChoice() {
        val dir=Files.createTempDirectory("soundq-preferences-recovery").toFile()
        try {
            val file=dir.resolve("settings").apply {writeText("rejected bytes")}
            val owner=QueueSettingsRepository(FileQueuePreferencesStore(file));owner.load()
            assertTrue(owner.state.value.error);assertNull(owner.capture())
            file.writeText("""{"version":1,"preserveManualQueue":false}""")
            owner.load()
            assertFalse(owner.state.value.error);assertTrue(owner.state.value.writable)
            assertFalse(owner.state.value.keepQueued)
            assertTrue(owner.setKeepQueued(owner.capture()!!,true))
            assertTrue(FileQueuePreferencesStore(file).load())
        } finally {dir.deleteRecursively()}
    }
    @Test fun successfulSaveConsumesCaptureWithoutReplayingItsWrite() {
        var writes=0
        val owner=QueueSettingsRepository(object:QueuePreferencesStore {
            override fun load()=true
            override fun save(keepQueued:Boolean){writes++}
        })
        owner.load();val capture=owner.capture()!!
        assertTrue(owner.setKeepQueued(capture,false))
        assertFalse(owner.setKeepQueued(capture,true))
        assertEquals(1,writes);assertFalse(owner.state.value.keepQueued)
    }
    @Test fun unreadableOrFutureStoreIsPreservedAndExplicitReloadRecovers() {
        val dir=Files.createTempDirectory("soundq-rejected-preferences").toFile()
        try {
            val file=dir.resolve("settings")
            val values=listOf("broken", """{"version":2,"preserveManualQueue":false}""", """{"version":1,"preserveManualQueue":"false"}""")
            for(raw in values) {
                file.writeText(raw)
                val owner=QueueSettingsRepository(FileQueuePreferencesStore(file));owner.load()
                assertTrue(owner.state.value.error);assertFalse(owner.state.value.writable);assertNull(owner.capture())
                assertEquals(raw,file.readText())
            }
            file.writeText("""{"version":1,"preserveManualQueue":false}""")
            val owner=QueueSettingsRepository(FileQueuePreferencesStore(file));owner.load()
            assertTrue(owner.state.value.writable);assertFalse(owner.state.value.keepQueued)
            file.writeText("future unknown bytes")
            assertFalse("external rejected bytes must not be overwritten",owner.setKeepQueued(owner.capture()!!,true))
            assertEquals("future unknown bytes",file.readText())
            owner.load();assertFalse(owner.state.value.writable)
        } finally {dir.deleteRecursively()}
    }
    @Test fun saveFailureRetainsAcceptedValueAndConsumesOldCapture() {
        var writes=0
        val owner=QueueSettingsRepository(object:QueuePreferencesStore {
            override fun load()=false
            override fun save(keepQueued:Boolean){writes++;error("fixture write failure")}
        })
        owner.load();val captured=owner.capture()!!
        assertFalse(owner.setKeepQueued(captured,true));assertFalse(owner.state.value.keepQueued)
        assertTrue(owner.state.value.error);assertFalse(owner.setKeepQueued(captured,true));assertEquals(1,writes)
    }
    @Test fun savedChoiceSurvivesNewOwnerAndChangesOnlyFutureManualCarry() {
        val dir=Files.createTempDirectory("soundq-preferences").toFile()
        try {
            val file=dir.resolve("queue-settings.v1.json")
            val owner=QueueSettingsRepository(FileQueuePreferencesStore(file))
            owner.load()
            assertTrue(owner.state.value.keepQueued)
            assertTrue(owner.setKeepQueued(owner.capture()!!,false))
            assertFalse(owner.state.value.keepQueued)
            val restored=QueueSettingsRepository(FileQueuePreferencesStore(file))
            restored.load()
            assertFalse("durable choice must survive owner reconstruction",restored.state.value.keepQueued)
            assertEquals(emptyList<Int>(),QueuePolicy.carriedManual(listOf(false,true,true),0,restored.state.value.keepQueued))
            assertEquals(listOf(1,2),QueuePolicy.carriedManual(listOf(false,true,true),0,true))
        } finally {dir.deleteRecursively()}
    }
}
