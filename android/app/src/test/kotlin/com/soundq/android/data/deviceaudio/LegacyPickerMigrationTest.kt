package com.soundq.android.data.deviceaudio

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/** An upgraded phone's store holds rows an older build's file and folder pickers reached. They are never shown;
 * a whole indexed scan folds the ones the provider proves (see [DeviceIdentityFoldTest]) and drops the rest. */
class LegacyPickerMigrationTest {
    private fun target(): File {
        val base = System.getProperty("device.domain.fixtures") ?: System.getProperty("java.io.tmpdir")
        return File(Files.createTempDirectory(File(requireNotNull(base)).toPath(), "legacy-picker-case-").toFile(), "domain.json")
    }
    private fun id(name: String) = UUID.nameUUIDFromBytes(name.toByteArray())
    private val indexed = ScanGrant(ScanGrantId(id("indexed")), GrantKind.INDEXED, "Android audio index", ProviderLocator("android", "indexed:external-audio"), false)
    private val file = ScanGrant(ScanGrantId(id("file")), GrantKind.FILE, "picked.mp3", ProviderLocator("com.android.externalstorage.documents", "content://com.android.externalstorage.documents/document/primary%3AMusic%2Fpicked.mp3"), true)
    private val folder = ScanGrant(ScanGrantId(id("folder")), GrantKind.FOLDER, "Mixes", ProviderLocator("com.android.externalstorage.documents", "content://com.android.externalstorage.documents/tree/primary%3AMixes"), true, AccessState.REVOKED)
    private val mediaLocator = ProviderLocator("media", "content://media/external_primary/audio/media/7")
    private val mediaKey = ProviderObjectId("android-content", "media:v:content://media/external_primary/audio/media/7:3")
    private val revision = ContentRevision("a".repeat(64), 4096)
    private fun row(name: String, objectId: ProviderObjectId, vararg routes: Pair<ScanGrant, ProviderLocator>) = DeviceAudio(DeviceFileId(id(name)), objectId, revision, 2,
        OriginalMetadata("$name.mp3", name, "Artist", null, null), 1_200_000, routes.map { (g, l) -> LocatorAccess(g.id, l, g.state) })
    /** Indexed and listened to; never touched by the migration. */
    private val media = row("media", mediaKey, indexed to mediaLocator)
    /** A picked file whose provider object the index does not prove. */
    private val picked = row("picked", ProviderObjectId("android-content", "document:com.android.externalstorage.documents:primary:Music/picked.mp3"), file to file.locator)
    /** A folder-picker file whose grant was already lost: shown as "Choose file again" by older builds. */
    private val lost = row("lost", ProviderObjectId("android-content", "document:com.android.externalstorage.documents:primary:Mixes/lost.mp3"), folder to ProviderLocator("com.android.externalstorage.documents", "content://com.android.externalstorage.documents/tree/primary%3AMixes/document/primary%3AMixes%2Flost.mp3"))
    private fun listened(row: DeviceAudio, at: Long, position: Long) = JournalEntry(HistoryKey.Device(row.id), at, Bookmark(row.owner, position), id("t-${row.id}"), 3)
    private val server = HistoryKey.Server(ServerAccount("https://fixture.invalid", "account"), ServerAudioId(5))
    private val journal = listOf(listened(media, 9_000, 650_000), listened(picked, 8_000, 120_000), listened(lost, 7_000, 30_000), JournalEntry(server, 6_000))
    /** Format 2 too: one older fold already redirected a row into the picked one. */
    private val folded = RetiredDeviceIdentity(ContentOwner(HistoryKey.Device(DeviceFileId(id("older"))), revision, 1), picked.id)
    private fun written(path: File, retired: List<RetiredDeviceIdentity> = listOf(folded)) {
        path.parentFile.mkdirs()
        path.writeBytes(encodeDomain(DomainState(41, listOf(indexed, file, folder), listOf(media, picked, lost), emptyList(), journal, retired)).toString().toByteArray(Charsets.UTF_8))
    }
    private fun found() = DiscoveredAudio(mediaKey, mediaLocator, revision, media.metadata, media.durationMs)

    @Test fun pickerRowsAreNeverShownAndOnlyTheIndexScansOrIsGranted() {
        val path = target(); written(path)
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            val snapshot = store.snapshot(access)!!
            assertEquals(listOf(media.id), snapshot.files.map { it.id })
            assertEquals(listOf(indexed.id), snapshot.grants.map { it.id })
            assertEquals(listOf(HistoryKey.Device(media.id)), snapshot.history.map { it.key })
            assertEquals(emptyList<RetiredDeviceIdentity>(), snapshot.retired)
            assertNull("A picker row cannot be played", store.captureSource(access, picked.id))
            assertEquals(setOf(picked.objectId, lost.objectId), store.legacyObjects(access))
            // No new picker grant, and a persisted one from an older build never scans.
            assertEquals(Mutation.REFUSED, store.putGrant(access, file.copy(id = ScanGrantId(id("new-file")))))
            assertEquals(Mutation.REFUSED, store.putGrant(access, folder.copy(state = AccessState.AVAILABLE)))
            assertNull(store.beginScan(access, file.id))
        }
    }

    @Test fun wholeIndexedScanDropsUnprovenPickerRowsAndTheirStateAndLeavesIndexedListeningExact() {
        val path = target(); written(path)
        val before = decodeDomain(path.readBytes())
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            assertNotEquals(Mutation.REFUSED, store.putGrant(access, indexed.copy(state = AccessState.AVAILABLE)))
            assertEquals(Mutation.UNCHANGED, store.publishScan(store.beginScan(access, indexed.id)!!, listOf(found())))
            assertEquals(Mutation.APPLIED, store.retireLegacyAccess(access))
            assertEquals(Mutation.UNCHANGED, store.retireLegacyAccess(access))
            assertEquals(emptySet<ProviderObjectId>(), store.legacyObjects(access))
            assertEquals(650_000L, store.bookmark(store.captureSource(access, media.id)!!)!!.positionMs)
        }
        val after = decodeDomain(path.readBytes())
        assertEquals(listOf(indexed.id), after.grants.map { it.id })
        assertEquals(listOf(before.files.single { it.id == media.id }), after.files)
        assertEquals("Indexed and server listening are untouched", before.journal.filter { it.key == HistoryKey.Device(media.id) || it.key == server }, after.journal)
        assertEquals(emptyList<RetiredDeviceIdentity>(), after.retired)
        val text = path.readText()
        assertTrue(text.startsWith("{\"version\":1,"))
        for (gone in listOf(picked.id.value, lost.id.value, file.id.value, folder.id.value)) assertFalse(text.contains(gone.toString()))
        // Reopening the real store: same state, and the migration has nothing left to do.
        val bytes = path.readBytes()
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            assertEquals(listOf(media.id), store.snapshot(access)!!.files.map { it.id })
            assertEquals(Mutation.UNCHANGED, store.retireLegacyAccess(access))
        }
        assertArrayEquals(bytes, path.readBytes())
    }

    @Test fun aStoreWithoutPickerGrantsIsNotRewritten() {
        val path = target()
        path.parentFile.mkdirs()
        path.writeBytes(encodeDomain(DomainState(3, listOf(indexed), listOf(media), emptyList(), listOf(listened(media, 9_000, 650_000)))).toString().toByteArray(Charsets.UTF_8))
        val bytes = path.readBytes()
        DeviceListeningStore(path).use { store -> assertEquals(Mutation.UNCHANGED, store.retireLegacyAccess(store.unlock())) }
        assertArrayEquals(bytes, path.readBytes())
    }

    @Test fun lockedOrReplacedStoreRefusesRetirementWithoutWriting() {
        val path = target(); written(path)
        val bytes = path.readBytes()
        DeviceListeningStore(path).use { store ->
            val access = store.unlock(); store.lock()
            assertEquals(Mutation.REFUSED, store.retireLegacyAccess(access))
            assertNull(store.legacyObjects(access))
        }
        assertArrayEquals(bytes, path.readBytes())
    }
}
