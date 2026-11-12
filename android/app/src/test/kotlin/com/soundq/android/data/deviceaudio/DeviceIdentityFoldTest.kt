package com.soundq.android.data.deviceaudio

import com.soundq.android.playback.ListeningSpeedKey
import com.soundq.android.playback.PlaybackRef
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/** One MediaStore row stored twice by an older build: once by the indexed scan, once under the key its file picker
 * grant produced. The indexed scan publishes the picker key as a proven former key and folds the row into itself. */
class DeviceIdentityFoldTest {
    private fun target(): File {
        val base = System.getProperty("device.domain.fixtures") ?: System.getProperty("java.io.tmpdir")
        return File(Files.createTempDirectory(File(requireNotNull(base)).toPath(), "device-fold-case-").toFile(), "domain.json")
    }
    private val content = ContentRevision("c".repeat(64), 960044)
    private val canonical = ProviderObjectId("android-content", "media:v:content://media/external_primary/audio/media/41:7")
    private val legacy = ProviderObjectId("android-content", "media:v:content://media/external/downloads/41:7")
    private val indexedLocator = ProviderLocator("media", "content://media/external_primary/audio/media/41")
    private val fileLocator = ProviderLocator("media", "content://media/external/downloads/41")
    private val indexed = ScanGrant(ScanGrantId(UUID.nameUUIDFromBytes("indexed".toByteArray())), GrantKind.INDEXED, "Android audio index", ProviderLocator("android", "indexed:external-audio"), false)
    private val file = ScanGrant(ScanGrantId(UUID.nameUUIDFromBytes("file".toByteArray())), GrantKind.FILE, "song.wav", fileLocator, true)
    private val keptId = DeviceFileId(UUID.nameUUIDFromBytes("kept".toByteArray()))
    private val oldId = DeviceFileId(UUID.nameUUIDFromBytes("old".toByteArray()))
    private val metadata = OriginalMetadata("song.wav", "Song", null, null, null)
    private fun row(id: DeviceFileId, objectId: ProviderObjectId, grant: ScanGrant, locator: ProviderLocator, revision: ContentRevision = content) =
        DeviceAudio(id, objectId, revision, 1, metadata, 1_200_000, listOf(LocatorAccess(grant.id, locator, AccessState.AVAILABLE)))
    private val kept = row(keptId, canonical, indexed, indexedLocator)
    private val old = row(oldId, legacy, file, fileLocator)
    private fun listened(row: DeviceAudio, at: Long, position: Long?) =
        JournalEntry(HistoryKey.Device(row.id), at, position?.let { Bookmark(row.owner, it) }, UUID.randomUUID(), 2)
    /** An upgraded phone's store, exactly as the older build wrote it. */
    private fun written(path: File, files: List<DeviceAudio>, journal: List<JournalEntry> = emptyList(), grants: List<ScanGrant> = listOf(indexed, file)) {
        path.parentFile.mkdirs()
        path.writeBytes(encodeDomain(DomainState(9, grants, files, emptyList(), journal)).toString().toByteArray(Charsets.UTF_8))
    }
    private fun found(id: ProviderObjectId, locator: ProviderLocator, former: Set<ProviderObjectId> = emptySet(), revision: ContentRevision = content) =
        DiscoveredAudio(id, locator, revision, OriginalMetadata("song.wav", "Song", null, null, locator.value), 1_200_000, formerObjectIds = former)
    /** The production refresh order: this session's index grant, the scan with proven former keys, then retirement. */
    private fun indexedScan(store: DeviceListeningStore, vararg rows: DiscoveredAudio): AccessCapture {
        val access = store.unlock()
        assertNotEquals(Mutation.REFUSED, store.putGrant(access, indexed.copy(state = AccessState.AVAILABLE)))
        assertNotEquals(Mutation.REFUSED, store.publishScan(store.beginScan(access, indexed.id)!!, rows.toList()))
        assertNotEquals(Mutation.REFUSED, store.retireLegacyAccess(access))
        return access
    }

    @Test fun indexedScanFoldsTheLegacyRowIntoTheIndexedRowAndKeepsTheLatestListening() {
        val path = target()
        written(path, listOf(kept, old), listOf(listened(kept, 1_000, 100_000), listened(old, 2_000, 300_000)))
        DeviceListeningStore(path).use { store ->
            val access = indexedScan(store, found(canonical, indexedLocator, setOf(legacy)))
            val snapshot = store.snapshot(access)!!
            val row = snapshot.files.single()
            assertEquals(kept.id, row.id)
            assertEquals(canonical, row.objectId)
            assertEquals(kept.owner, row.owner)
            assertEquals("Only the audio index reaches it now", listOf(indexed.id to indexedLocator), row.aliases.map { it.grantId to it.locator })
            assertEquals(listOf(indexed.id), snapshot.grants.map { it.id })
            // Recency keeps the later play; resume keeps the most recent listening's position.
            val history = snapshot.history.single()
            assertEquals(HistoryKey.Device(kept.id), history.key)
            assertEquals(2_000L, history.playedAtEpochMs)
            assertEquals(300_000L, store.bookmark(store.captureSource(access, row.id)!!)!!.positionMs)
            // A saved queue naming the retired row still resolves to the surviving row for the same content.
            assertEquals(row, snapshot.resolve(old.id, old.revision, old.incarnation))
            assertNull(snapshot.resolve(old.id, old.revision, old.incarnation + 1))
            assertNull(snapshot.resolve(old.id, ContentRevision("d".repeat(64), 1), old.incarnation))
            // Idempotent on the next refresh.
            assertEquals(Mutation.UNCHANGED, store.publishScan(store.beginScan(access, indexed.id)!!, listOf(found(canonical, indexedLocator, setOf(legacy)))))
            assertEquals(Mutation.UNCHANGED, store.retireLegacyAccess(access))
        }
        assertTrue(path.readText().startsWith("{\"version\":2,"))
        assertFalse(path.readText().contains("\"FILE\""))
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            store.putGrant(access, indexed) // this session's index access
            val snapshot = store.snapshot(access)!!
            assertEquals(listOf(kept.id), snapshot.files.map { it.id })
            assertEquals(300_000L, store.bookmark(store.captureSource(access, kept.id)!!)!!.positionMs)
            assertEquals(kept.id, snapshot.resolve(old.id, old.revision, old.incarnation)!!.id)
        }
    }

    @Test fun anOlderLegacyListeningDoesNotReplaceANewerIndexedOne() {
        val path = target()
        written(path, listOf(kept, old), listOf(listened(old, 1_000, 300_000), listened(kept, 2_000, 100_000)))
        DeviceListeningStore(path).use { store ->
            val access = indexedScan(store, found(canonical, indexedLocator, setOf(legacy)))
            val history = store.snapshot(access)!!.history.single()
            assertEquals(2_000L, history.playedAtEpochMs)
            assertEquals(100_000L, store.bookmark(store.captureSource(access, kept.id)!!)!!.positionMs)
        }
    }

    @Test fun historyOnlyOnTheLegacyRowMovesToTheSurvivor() {
        val path = target()
        written(path, listOf(kept, old), listOf(listened(old, 5_000, 700_000)))
        DeviceListeningStore(path).use { store ->
            val access = indexedScan(store, found(canonical, indexedLocator, setOf(legacy)))
            val history = store.snapshot(access)!!.history.single()
            assertEquals(HistoryKey.Device(kept.id) to 5_000L, history.key to history.playedAtEpochMs)
            assertEquals(700_000L, store.bookmark(store.captureSource(access, kept.id)!!)!!.positionMs)
        }
    }

    @Test fun aLegacyRowAloneIsRekeyedInPlace() {
        val path = target()
        written(path, listOf(old), listOf(listened(old, 1_000, 200_000)), listOf(file))
        DeviceListeningStore(path).use { store ->
            val access = indexedScan(store, found(canonical, indexedLocator, setOf(legacy)))
            val after = store.snapshot(access)!!
            val row = after.files.single()
            assertEquals(old.id, row.id)
            assertEquals(canonical, row.objectId)
            assertEquals(old.owner, row.owner)
            assertEquals(listOf(indexed.id to indexedLocator), row.aliases.map { it.grantId to it.locator })
            assertEquals(1_000L, after.history.single().playedAtEpochMs)
            assertEquals(200_000L, store.bookmark(store.captureSource(access, old.id)!!)!!.positionMs)
            assertEquals(emptyList<RetiredDeviceIdentity>(), after.retired)
        }
        // Nothing folded away: still the format older builds read.
        assertTrue(path.readText().startsWith("{\"version\":1,"))
    }

    @Test fun aChangedFileKeepsHistoryButNotAPositionInOtherContent() {
        val path = target()
        written(path, listOf(kept, old), listOf(listened(old, 3_000, 300_000)))
        DeviceListeningStore(path).use { store ->
            val edited = ContentRevision("e".repeat(64), 960100)
            val access = indexedScan(store, found(canonical, indexedLocator, setOf(legacy), edited))
            val snapshot = store.snapshot(access)!!
            val row = snapshot.files.single()
            assertEquals(edited, row.revision)
            assertEquals(3_000L, snapshot.history.single().playedAtEpochMs)
            assertNull(store.bookmark(store.captureSource(access, row.id)!!))
            assertNull(snapshot.resolve(old.id, old.revision, old.incarnation))
            assertEquals(kept.id, row.id)
        }
    }

    @Test fun aFormerKeyPublishedAsItsOwnObjectIsNotFolded() {
        val path = target()
        written(path, listOf(kept, old))
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            store.putGrant(access, indexed)
            val other = ProviderLocator("media", "content://media/external_primary/audio/media/99")
            assertEquals(Mutation.APPLIED, store.publishScan(store.beginScan(access, indexed.id)!!, listOf(found(canonical, indexedLocator, setOf(legacy)), found(legacy, other))))
            assertEquals(2, store.snapshot(access)!!.files.size)
        }
    }

    @Test fun perTrackSpeedIsSharedByBothRowsBecauseItIsKeyedByContent() {
        fun ref(row: DeviceAudio) = PlaybackRef.Device(row.id.value.toString(), row.revision.sha256, row.revision.byteLength, row.incarnation)
        assertNotEquals(kept.id, old.id)
        assertEquals(ListeningSpeedKey.device(ref(kept)), ListeningSpeedKey.device(ref(old)))
    }

    @Test fun combinePrefersTheLatestResumeStateAndFallsBackToTheOtherBookmark() {
        val key = HistoryKey.Device(DeviceFileId(UUID.randomUUID()))
        val owner = ContentOwner(key, content, 1)
        val traversal = UUID.randomUUID()
        val kept = JournalEntry(key, 1_000, Bookmark(owner, 50_000), traversal, 4)
        val playedWithoutCheckpoint = JournalEntry(key, 2_000, null, UUID.randomUUID(), 1)
        assertEquals(playedWithoutCheckpoint.copy(bookmark = Bookmark(owner, 50_000)), IdentityFold.combine(kept, playedWithoutCheckpoint))
        val finished = JournalEntry(key, 2_000, null, UUID.randomUUID(), 9, completed = true)
        assertEquals(finished, IdentityFold.combine(kept, finished))
        val tie = JournalEntry(key, 1_000, Bookmark(owner, 90_000), UUID.randomUUID(), 2)
        assertEquals(kept, IdentityFold.combine(kept, tie))
        assertEquals(kept, IdentityFold.combine(kept, null))
        assertEquals(tie, IdentityFold.combine(null, tie))
    }

    @Test fun retiredIdentitiesAreStrictlyDecoded() {
        val path = target()
        written(path, listOf(kept, old))
        DeviceListeningStore(path).use { store -> indexedScan(store, found(canonical, indexedLocator, setOf(legacy))) }
        val text = path.readText()
        val retired = decodeDomain(text.toByteArray()).retired.single()
        // A retired identity may not point at a missing row, appear in format 1, or be an empty format 2 list.
        val missing = text.replace("\"into\":\"${retired.into.value}\"", "\"into\":\"${UUID.randomUUID()}\"")
        val downgraded = text.replaceFirst("{\"version\":2,", "{\"version\":1,")
        val empty = text.substringBefore(",\"retired\":") + ",\"retired\":[]}"
        for (bytes in listOf(missing, downgraded, empty)) {
            assertNotEquals(text, bytes)
            assertTrue(runCatching { decodeDomain(bytes.toByteArray()) }.isFailure)
        }
    }
}
