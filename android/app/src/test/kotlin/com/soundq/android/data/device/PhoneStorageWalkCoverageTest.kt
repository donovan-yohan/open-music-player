package com.soundq.android.data.device

import android.Manifest
import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.database.MatrixCursor
import android.net.Uri
import android.os.Environment
import android.os.Process
import android.os.storage.StorageManager
import com.soundq.android.AppGraph
import com.soundq.android.data.ApiEndpoint
import com.soundq.android.data.AuthState
import com.soundq.android.data.SecretTokens
import com.soundq.android.data.SessionStore
import com.soundq.android.data.deviceaudio.*
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowContentResolver
import org.robolectric.shadows.ShadowEnvironment
import org.robolectric.shadows.StorageVolumeBuilder

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [30], application = PhoneStorageWalkCoverageTest.ScanApplication::class,
    shadows = [PhoneStorageWalkCoverageTest.StoragePermission::class])
class PhoneStorageWalkCoverageTest {
    // Only the fixture graph may open the real journal; do not start the manifest's application graph.
    class ScanApplication : Application()

    @Implements(Environment::class)
    class StoragePermission : ShadowEnvironment() {
        companion object {
            @Volatile var sample: () -> Boolean = { false }
            @JvmStatic @Implementation(minSdk = 30) fun isExternalStorageManager(): Boolean = sample()
        }
    }

    @Test fun permissionRegainedBeforeIndexQueryDoesNotRetireUnwalkedPickerRowOrBookmark() = runBlocking {
        Fixture().use { f ->
            f.pickedFile.writeBytes(byteArrayOf(1, 2, 3))
            val scan = f.refresh(denyWalk = true)
            assertEquals(listOf("allowed", "denied", "allowed", "index"), f.events.take(4))
            assertFalse("Storage was not walked", "walk" in f.events)
            assertEquals(listOf(f.pickedFile.path), f.lookedUpPickerPaths)
            f.assertPickerStatePreserved()
            assertEquals(PhoneScanObservation(indexed = true, complete = false, storage = true), scan)
            assertTrue(f.pickedFile.isFile)
        }
    }

    @Test fun completedWalkRetiresMissingPickerRowAndBookmark() = runBlocking {
        Fixture().use { f ->
            assertFalse(f.pickedFile.exists())
            val scan = f.refresh()
            assertEquals(listOf("allowed", "allowed", "walk", "allowed", "index"), f.events.take(5))
            assertEquals(listOf(f.pickedFile.path), f.lookedUpPickerPaths)
            assertEquals(PhoneScanObservation(indexed = true, complete = true, storage = true), scan)
            val after = decodeDomain(f.disk.readBytes())
            assertTrue(after.files.isEmpty())
            assertTrue(after.journal.isEmpty())
            assertEquals(listOf(GrantKind.INDEXED), after.grants.map { it.kind })
        }
    }

    @Test @Config(sdk = [28])
    fun legacySdkKeepsIntentionalNoWalkAndDoesNotRetirePickerState() = runBlocking {
        Fixture(legacySdk = true).use { f ->
            f.pickedFile.writeBytes(byteArrayOf(1, 2, 3))
            assertEquals(PhoneScanObservation(indexed = true, complete = true, storage = true), f.refresh())
            assertEquals(listOf("index"), f.events)
            assertEquals(listOf(f.pickedFile.path), f.lookedUpPickerPaths)
            f.assertPickerStatePreserved()
        }
    }

    private class Fixture(private val legacySdk: Boolean = false) : AutoCloseable {
        private val app = RuntimeEnvironment.getApplication()
        val events = CopyOnWriteArrayList<String>()
        val lookedUpPickerPaths = CopyOnWriteArrayList<String>()
        private val root = object : File(app.cacheDir, "shared-storage") {
            override fun listFiles(): Array<File>? {
                events += "walk"
                return super.listFiles()
            }
        }.apply { check(mkdir()) }
        val pickedFile = File(root, "picked.wav")
        private val graph = AppGraph(app, ApiEndpoint.parse("https://fixture.invalid/api/v1"),
            okhttp3.OkHttpClient.Builder().addInterceptor { error("Network is outside the fixture") }.build(),
            store = object : SessionStore {
                override fun load(endpoint: ApiEndpoint): SecretTokens? = null
                override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) = Unit
                override fun clear() = Unit
            })
        private val repo = graph.phoneAudio
        val disk = File(graph.directory, "phone-listening.v1.json")
        private val picker = ScanGrant(ScanGrantId(UUID.randomUUID()), GrantKind.FILE, pickedFile.name,
            ProviderLocator("com.android.providers.downloads.documents", "content://com.android.providers.downloads.documents/document/${Uri.encode("raw:${pickedFile.path}")}"), true)
        private val row = DeviceAudio(DeviceFileId(UUID.randomUUID()),
            ProviderObjectId("android-content", "document:com.android.providers.downloads.documents:raw:${pickedFile.path}"),
            // Exact SHA-256 and length of byteArrayOf(1, 2, 3).
            ContentRevision("039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81", 3),
            1, OriginalMetadata(pickedFile.name, "Picked"), 601_000,
            listOf(LocatorAccess(picker.id, picker.locator, AccessState.AVAILABLE)))
        private val entry = JournalEntry(HistoryKey.Device(row.id), 3000, Bookmark(row.owner, 123_456), UUID.randomUUID(), 2)

        init {
            if (legacySdk) shadowOf(app).denyPermissions(Manifest.permission.READ_EXTERNAL_STORAGE)
            else {
                StoragePermission.sample = { false }
                val volume = StorageVolumeBuilder("fixture", root, "Fixture", Process.myUserHandle(), Environment.MEDIA_MOUNTED)
                    .setIsPrimary(true).build()
                shadowOf(app.getSystemService(StorageManager::class.java)).addStorageVolume(volume)
            }
            ShadowContentResolver.registerProviderInternal("media", object : ContentProvider() {
                override fun onCreate() = true
                override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sortOrder: String?): MatrixCursor {
                    when {
                        sortOrder == "_id ASC" -> events += "index"
                        args != null -> lookedUpPickerPaths.addAll(args)
                        else -> error("Unexpected MediaStore query: $uri")
                    }
                    return MatrixCursor(checkNotNull(projection).toList().toTypedArray())
                }
                override fun getType(uri: Uri): String? = error("No type lookup expected")
                override fun insert(uri: Uri, values: ContentValues?): Uri? = error("No provider writes expected")
                override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?): Int = error("No provider writes expected")
                override fun delete(uri: Uri, selection: String?, args: Array<out String>?): Int = error("No provider writes expected")
            })
            disk.writeBytes(encodeDomain(DomainState(5, listOf(picker), listOf(row), emptyList(), listOf(entry))).toString().toByteArray())
        }

        suspend fun refresh(denyWalk: Boolean = false): PhoneScanObservation {
            assertFalse(graph.session.restore { throw AssertionError("No account to restore") })
            assertTrue(graph.session.state.value is AuthState.SignedOut)
            repo.start()
            assertEquals(PhoneScanObservation(indexed = false, complete = true), finishedScan())
            assertPickerStatePreserved()
            assertTrue(events.isEmpty())
            if (legacySdk) shadowOf(app).grantPermissions(Manifest.permission.READ_EXTERNAL_STORAGE)
            else {
                val denyOnce = AtomicBoolean(denyWalk)
                StoragePermission.sample = {
                    // Admission sees a grant; only its first running sample (walk admission) sees denial.
                    val allowed = !(repo.state.value.refreshing && denyOnce.compareAndSet(true, false))
                    events += if (allowed) "allowed" else "denied"
                    allowed
                }
            }
            repo.refresh()
            return finishedScan(indexed = true)
        }

        private suspend fun finishedScan(indexed: Boolean = false) = withTimeoutOrNull(10_000) {
            repo.state.first { !it.refreshing && it.scan?.indexed == indexed }.scan
        } ?: error("Scan did not settle (indexed=$indexed): ${repo.state.value}, events=$events")

        fun assertPickerStatePreserved() {
            val stored = decodeDomain(disk.readBytes())
            assertEquals("MediaStore omission did not authorize deleting the exact picker row", listOf(row), stored.files)
            assertEquals("The exact listening entry and bookmark must survive", listOf(entry), stored.journal)
            assertEquals(picker, stored.grants.single { it.kind == GrantKind.FILE })
        }

        override fun close() {
            graph.close()
            StoragePermission.sample = { false }
        }
    }
}
