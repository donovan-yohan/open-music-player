package com.soundq.android.data.deviceaudio

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Qualifies the actual app-private filesystem atomic replace/directory-force path when run on Android. */
@RunWith(AndroidJUnit4::class)
class DeviceListeningAndroidPersistenceTest {
    @Test fun appPrivateCommitIsAcknowledgedAndReopens() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.noBackupFilesDir.canonicalFile, "synthetic-store-${UUID.randomUUID()}")
        assertTrue(directory.mkdir())
        val path = File(directory, "listening.json")
        val id = ScanGrantId(UUID.randomUUID())
        val grant = ScanGrant(id, GrantKind.FILE, "Synthetic", ProviderLocator("synthetic", "object-1"), true)
        try {
            DeviceListeningStore(path).use { store ->
                assertEquals(LoadState.READY, store.loadState)
                val access = store.unlock()
                assertEquals(Mutation.APPLIED, store.putGrant(access, grant))
                assertEquals(listOf(grant), store.snapshot(access)!!.grants)
            }
            DeviceListeningStore(path).use { store ->
                val access = store.unlock()
                assertEquals(listOf(grant), store.snapshot(access)!!.grants)
                assertEquals(Mutation.UNCHANGED, store.putGrant(access, grant))
            }
        } finally {
            // This test-created private directory only; never media/catalog production directories.
            directory.deleteRecursively()
        }
    }
}
