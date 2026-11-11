package com.soundq.android.data.preferences

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class StoragePreferencesTest {
    @Test fun absentSettingsHaveSourceDefaultsAndOnlyBoundStorageChoicePersists() {
        val dir=Files.createTempDirectory("storage-preferences").toFile()
        try {
            val file=dir.resolve("storage.v1.json");val owner=StoragePreferences(file);owner.load()
            assertTrue(owner.state.value.temporaryAudioEnabled)
            assertTrue(owner.setTemporaryAudio(owner.capture()!!,false){true})
            val rebuilt=StoragePreferences(file);rebuilt.load();assertFalse(rebuilt.state.value.temporaryAudioEnabled)
            assertEquals(0,ListeningPreferences().crossfadeSeconds)
            assertEquals(EndOfQueue.ShuffleLibrary,ListeningPreferences().endOfQueue)
            assertEquals(Appearance.System,ListeningPreferences().appearance)
        } finally {dir.deleteRecursively()}
    }
    @Test fun failedWritePreservesAcceptedValueAndRejectsStaleRouteAndForeignBytes() {
        val dir=Files.createTempDirectory("storage-rejected").toFile()
        try {
            val file=dir.resolve("storage");val owner=StoragePreferences(file);owner.load()
            assertFalse(owner.setTemporaryAudio(owner.capture()!!,false){false});assertFalse(file.exists())
            val capture=owner.capture()!!;file.writeText("future bytes")
            assertFalse(owner.setTemporaryAudio(capture,false){true});assertTrue(owner.state.value.temporaryAudioEnabled)
            assertEquals("future bytes",file.readText());assertFalse(owner.setTemporaryAudio(capture,false){true})
            owner.load();assertTrue(owner.state.value.error);assertNull(owner.capture())
        } finally {dir.deleteRecursively()}
    }
}
