package com.soundq.android.data.deviceaudio

import com.soundq.android.playback.ListeningSpeedKey
import com.soundq.android.playback.PlaybackRef
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/** One MediaStore row stored twice: once by the indexed scan, once under the legacy key its file grant
 * produced. The next file-grant scan proves the legacy key is a former key of the indexed object. */
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
    private fun found(id: ProviderObjectId, locator: ProviderLocator, former: Set<ProviderObjectId> = emptySet(), revision: ContentRevision = content) =
        DiscoveredAudio(id, locator, revision, OriginalMetadata("song.wav", "Song", null, null, locator.value), 1_200_000, formerObjectIds = former)
    private fun publish(store: DeviceListeningStore, access: AccessCapture, grant: ScanGrant, vararg rows: DiscoveredAudio) =
        store.publishScan(store.beginScan(access, grant.id)!!, rows.toList())
    /** Plays [row] at [at] and checkpoints [position]; returns the source. */
    private fun listen(store: DeviceListeningStore, access: AccessCapture, row: DeviceAudio, at: Long, position: Long?) {
        val source = store.captureSource(access, row.id)!!
        val t = store.beginTraversal(source, UUID.randomUUID(), 1, 0, 0, 1_200_000)!!
        assertEquals(Mutation.APPLIED, store.played(SuccessfulPlaybackReceipt(t, 1, at)))
        if (position != null) assertEquals(Mutation.APPLIED, store.checkpoint(SourcePositionCheckpoint(t, 2, position)))
        assertEquals(Mutation.APPLIED, store.retireTraversal(t))
    }
    /** Today's duplicate: the indexed row and the file-grant row for one MediaStore item. */
    private fun duplicated(store: DeviceListeningStore): Triple<AccessCapture, DeviceAudio, DeviceAudio> {
        val access = store.unlock()
        assertEquals(Mutation.APPLIED, store.putGrant(access, indexed))
        assertEquals(Mutation.APPLIED, store.putGrant(access, file))
        assertEquals(Mutation.APPLIED, publish(store, access, indexed, found(canonical, indexedLocator)))
        assertEquals(Mutation.APPLIED, publish(store, access, file, found(legacy, fileLocator)))
        val files = store.snapshot(access)!!.files
        assertEquals(2, files.size)
        return Triple(access, files.single { it.objectId == canonical }, files.single { it.objectId == legacy })
    }

    @Test fun fileGrantScanFoldsTheLegacyRowIntoTheIndexedRowAndKeepsTheLatestListening() {
        val path = target()
        lateinit var survivor: DeviceAudio; lateinit var retired: DeviceAudio
        DeviceListeningStore(path).use { store ->
            val (access, kept, old) = duplicated(store); survivor = kept; retired = old
            listen(store, access, kept, at = 1_000, position = 100_000)
            listen(store, access, old, at = 2_000, position = 300_000)
            assertEquals(Mutation.APPLIED, publish(store, access, file, found(canonical, fileLocator, setOf(legacy))))
            val snapshot = store.snapshot(access)!!
            val row = snapshot.files.single()
            assertEquals(kept.id, row.id)
            assertEquals(canonical, row.objectId)
            assertEquals(kept.owner, row.owner)
            assertEquals("The indexed row keeps presenting itself", kept.metadata, row.metadata)
            assertEquals(setOf(indexed.id to indexedLocator, file.id to fileLocator), row.aliases.filter { it.state == AccessState.AVAILABLE }.map { it.grantId to it.locator }.toSet())
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
            assertEquals(Mutation.UNCHANGED, publish(store, access, file, found(canonical, fileLocator, setOf(legacy))))
            assertEquals(Mutation.UNCHANGED, publish(store, access, indexed, found(canonical, indexedLocator)))
        }
        assertTrue(path.readText().startsWith("{\"version\":2,"))
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            val snapshot = store.snapshot(access)!!
            assertEquals(listOf(survivor.id), snapshot.files.map { it.id })
            assertEquals(300_000L, store.bookmark(store.captureSource(access, survivor.id)!!)!!.positionMs)
            assertEquals(survivor.id, snapshot.resolve(retired.id, retired.revision, retired.incarnation)!!.id)
        }
    }

    @Test fun anOlderLegacyListeningDoesNotReplaceANewerIndexedOne() {
        DeviceListeningStore(target()).use { store ->
            val (access, kept, old) = duplicated(store)
            listen(store, access, old, at = 1_000, position = 300_000)
            listen(store, access, kept, at = 2_000, position = 100_000)
            assertEquals(Mutation.APPLIED, publish(store, access, file, found(canonical, fileLocator, setOf(legacy))))
            val history = store.snapshot(access)!!.history.single()
            assertEquals(2_000L, history.playedAtEpochMs)
            assertEquals(100_000L, store.bookmark(store.captureSource(access, kept.id)!!)!!.positionMs)
        }
    }

    @Test fun historyOnlyOnTheLegacyRowMovesToTheSurvivor() {
        DeviceListeningStore(target()).use { store ->
            val (access, kept, old) = duplicated(store)
            listen(store, access, old, at = 5_000, position = 700_000)
            assertEquals(Mutation.APPLIED, publish(store, access, file, found(canonical, fileLocator, setOf(legacy))))
            val history = store.snapshot(access)!!.history.single()
            assertEquals(HistoryKey.Device(kept.id) to 5_000L, history.key to history.playedAtEpochMs)
            assertEquals(700_000L, store.bookmark(store.captureSource(access, kept.id)!!)!!.positionMs)
        }
    }

    @Test fun aLegacyRowAloneIsRekeyedInPlace() {
        val path = target()
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            assertEquals(Mutation.APPLIED, store.putGrant(access, file))
            assertEquals(Mutation.APPLIED, publish(store, access, file, found(legacy, fileLocator)))
            val before = store.snapshot(access)!!.files.single()
            listen(store, access, before, at = 1_000, position = 200_000)
            assertEquals(Mutation.APPLIED, publish(store, access, file, found(canonical, fileLocator, setOf(legacy))))
            val after = store.snapshot(access)!!
            assertEquals(before.copy(objectId = canonical), after.files.single())
            assertEquals(200_000L, store.bookmark(store.captureSource(access, before.id)!!)!!.positionMs)
            assertEquals(emptyList<RetiredDeviceIdentity>(), after.retired)
        }
        // Nothing folded away: still the format older builds read.
        assertTrue(path.readText().startsWith("{\"version\":1,"))
    }

    @Test fun aChangedFileKeepsHistoryButNotAPositionInOtherContent() {
        DeviceListeningStore(target()).use { store ->
            val (access, kept, old) = duplicated(store)
            listen(store, access, old, at = 3_000, position = 300_000)
            val edited = ContentRevision("e".repeat(64), 960100)
            assertEquals(Mutation.APPLIED, publish(store, access, file, found(canonical, fileLocator, setOf(legacy), edited)))
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
        DeviceListeningStore(target()).use { store ->
            val (access, _, _) = duplicated(store)
            val other = ProviderLocator("media", "content://media/external/downloads/99")
            assertEquals(Mutation.APPLIED, publish(store, access, file, found(canonical, fileLocator, setOf(legacy)), found(legacy, other)))
            assertEquals(2, store.snapshot(access)!!.files.size)
        }
    }

    @Test fun theAudioIndexPresentsASharedRowWhicheverScanRanFirst() {
        DeviceListeningStore(target()).use { store ->
            val access = store.unlock()
            assertEquals(Mutation.APPLIED, store.putGrant(access, indexed))
            assertEquals(Mutation.APPLIED, store.putGrant(access, file))
            val viaFile = found(canonical, fileLocator); val viaIndex = found(canonical, indexedLocator)
            assertEquals(Mutation.APPLIED, publish(store, access, file, viaFile))
            assertEquals(viaFile.metadata, store.snapshot(access)!!.files.single().metadata)
            assertEquals(Mutation.APPLIED, publish(store, access, indexed, viaIndex))
            assertEquals(viaIndex.metadata, store.snapshot(access)!!.files.single().metadata)
            // Later refreshes neither alternate the presentation nor rewrite the store.
            assertEquals(Mutation.UNCHANGED, publish(store, access, file, viaFile))
            assertEquals(Mutation.UNCHANGED, publish(store, access, indexed, viaIndex))
            assertEquals(viaIndex.metadata, store.snapshot(access)!!.files.single().metadata)
            // Once the index no longer reaches it, the file grant presents it again.
            assertEquals(Mutation.APPLIED, store.putGrant(access, indexed.copy(state = AccessState.REVOKED)))
            assertEquals(Mutation.APPLIED, publish(store, access, file, viaFile))
            assertEquals(viaFile.metadata, store.snapshot(access)!!.files.single().metadata)
        }
    }

    @Test fun perTrackSpeedIsSharedByBothRowsBecauseItIsKeyedByContent() {
        DeviceListeningStore(target()).use { store ->
            val (_, kept, old) = duplicated(store)
            fun ref(row: DeviceAudio) = PlaybackRef.Device(row.id.value.toString(), row.revision.sha256, row.revision.byteLength, row.incarnation)
            assertNotEquals(kept.id, old.id)
            assertEquals(ListeningSpeedKey.device(ref(kept)), ListeningSpeedKey.device(ref(old)))
        }
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
        DeviceListeningStore(path).use { store ->
            val (access, _, _) = duplicated(store)
            assertEquals(Mutation.APPLIED, publish(store, access, file, found(canonical, fileLocator, setOf(legacy))))
        }
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
