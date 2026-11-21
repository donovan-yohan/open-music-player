package com.soundq.android.data.deviceaudio

import java.io.File
import java.io.ByteArrayOutputStream
import java.awt.image.BufferedImage
import java.util.UUID
import javax.imageio.ImageIO
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LocalEnrichmentStoreTest {
    @get:Rule val temp = TemporaryFolder()
    private val grant = ScanGrant(ScanGrantId(UUID.randomUUID()), GrantKind.INDEXED, "Index", ProviderLocator("test", "index"), true)
    private val original = DiscoveredAudio(ProviderObjectId("test", "song"), ProviderLocator("test", "original"),
        ContentRevision("a".repeat(64), 400), OriginalMetadata("song.mp3", "Original", "Original artist", "Original album", "original art"), 700_000)
    private val text = LocalDisplayText("Accepted", "Accepted artist", "Accepted album")
    private fun scan(store: DeviceListeningStore, access: AccessCapture, vararg rows: DiscoveredAudio) =
        store.publishScan(checkNotNull(store.beginScan(access, grant.id)), rows.toList())
    private fun path() = File(temp.newFolder(), "listening.json")

    private fun DeviceListeningStore.applyIfActive(capture: DeviceMetadataCapture, changes: LocalDisplayText,
        artwork: LocalAppliedCover? = null, active: () -> Boolean): Boolean = applyMetadata(capture, changes, artwork) { replace ->
        if (!active()) false else { replace(); true }
    } == MetadataApplyResult.Applied

    @Test fun artworkApplyIsAtomicAndOnlyCoverUpgradesToV4() {
        val path = path()
        val pngPixels = BufferedImage(12, 17, BufferedImage.TYPE_INT_RGB)
        val jpeg = ByteArrayOutputStream().also { check(ImageIO.write(pngPixels, "JPEG", it)) }.toByteArray()
        val id = "33333333-2222-4333-8444-555555555555"
        val cover = LocalAppliedCover.encoded(LocalAppliedCover.Kind.RELEASE_GROUP, id, jpeg)
        val empty = LocalDisplayText(null, null, null)
        var retired = false
        var armRetirement = false
        lateinit var baseline: ContentOwner
        DeviceListeningStore(path, commitFault = { if (it == "beforeReplace" && armRetirement) retired = true }).use { store ->
            val access = store.unlock()
            store.putGrant(access, grant)
            scan(store, access, original)
            fun row() = store.snapshot(access)!!.files.single()
            fun capture() = store.captureMetadata(access, row().owner)!!
            baseline = row().owner
            assertTrue(path.readText().startsWith("{\"version\":1,"))
            val old = capture()
            assertTrue(store.applyIfActive(old, text) { true })
            assertTrue(path.readText().startsWith("{\"version\":3,"))
            assertFalse(store.applyIfActive(old, empty, cover) { true })
            val before = path.readBytes()
            val current = capture()
            armRetirement = true
            assertFalse(store.applyIfActive(current, empty, cover) { !retired })
            assertArrayEquals(before, path.readBytes())
            armRetirement = false
            assertTrue(store.applyIfActive(capture(), empty, cover) { true })
            assertTrue(path.readText().startsWith("{\"version\":4,"))
            assertEquals(Mutation.UNCHANGED, scan(store, access, original))
            assertEquals(cover, row().displayOverride?.artwork)
            assertEquals(text, row().displayOverride?.text)
            assertEquals(original.metadata, row().metadata)
        }
        val wire = path.readText()
        assertThrows(IllegalArgumentException::class.java) { decodeDomain(wire.replace(cover.sha256, "0".repeat(64)).toByteArray()) }
        assertThrows(IllegalArgumentException::class.java) { decodeDomain(wire.replace("\"version\":4", "\"version\":3").toByteArray()) }
        assertThrows(IllegalArgumentException::class.java) { LocalAppliedCover.encoded(cover.kind, id, ByteArray(LocalAppliedCover.MAX_IMAGE_BYTES + 1)) }
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            fun row() = store.snapshot(access)!!.files.single()
            assertEquals(baseline, row().owner)
            assertEquals(cover, row().displayOverride?.artwork)
            assertArrayEquals(jpeg, row().displayOverride!!.artwork!!.jpeg())
            assertTrue(store.applyIfActive(store.captureMetadata(access, row().owner)!!, LocalDisplayText(null, "New", null)) { true })
            assertEquals(cover, row().displayOverride?.artwork)
            scan(store, access, original.copy(revision = ContentRevision("b".repeat(64), 400)))
            assertNull(row().displayOverride)
            assertTrue(path.readText().startsWith("{\"version\":1,"))
        }
    }

    @Test fun applyKeepsTagsArtAndActiveJournalAndSurvivesRescanAndReopen() {
        val path = path()
        val unrelated = original.copy(objectId = ProviderObjectId("test", "same bytes elsewhere"), locator = ProviderLocator("test", "other"))
        val id = DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            store.putGrant(access, grant)
            scan(store, access, original, unrelated)
            val row = store.snapshot(access)!!.files.single { it.objectId == original.objectId }
            val source = store.captureSource(access, row.id)!!
            val preview = store.captureMetadata(access, row.owner)!!
            val traversal = store.beginTraversal(source, UUID.randomUUID(), 1, 0, 0, 700_000)!!
            assertEquals(Mutation.APPLIED, store.played(SuccessfulPlaybackReceipt(traversal, 1, 123)))
            val before = path.readBytes()
            val discarded = store.captureMetadata(access, row.owner)!!
            assertEquals(preview.row, discarded.row)
            assertArrayEquals(before, path.readBytes())
            assertTrue(store.applyIfActive(preview, text) { true })
            assertFalse(store.applyIfActive(discarded, LocalDisplayText("Stale", null, null)) { true })
            assertEquals(Mutation.APPLIED, store.checkpoint(SourcePositionCheckpoint(traversal, 2, 658_000)))
            assertEquals(Mutation.UNCHANGED, scan(store, access, original, unrelated))
            val next = store.snapshot(access)!!.files.single { it.id == row.id }
            assertEquals(row.owner, next.owner)
            assertEquals(row.metadata, next.metadata)
            assertEquals(row.aliases, next.aliases)
            assertEquals("Accepted", next.displayTitle)
            row.id
        }
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            store.putGrant(access, grant)
            scan(store, access, original, unrelated)
            val snapshot = store.snapshot(access)!!
            val row = snapshot.files.single { it.id == id }
            assertEquals(text, row.displayOverride?.text)
            assertEquals(original.metadata, row.metadata)
            assertEquals(658_000L, snapshot.history.single().bookmark?.positionMs)
            assertNull(snapshot.files.single { it.id != id }.displayOverride)
        }
    }

    @Test fun sourceContentAndAccountAbaCannotApplyOldPreview() {
        DeviceListeningStore(path()).use { store ->
            val account = ServerAccount("https://fixture.invalid", "a")
            var access = store.unlock(account)
            store.putGrant(access, grant)
            scan(store, access, original)
            fun capture() = store.captureMetadata(access, store.snapshot(access)!!.files.single().owner)!!
            val first = capture()
            store.unlock(ServerAccount(account.endpoint, "b"))
            access = store.unlock(account)
            assertFalse(store.applyIfActive(first, text) { true })
            val prior = capture()
            assertTrue(store.applyIfActive(prior, text) { true })
            val held = capture()
            scan(store, access, original.copy(revision = ContentRevision("b".repeat(64), 400)))
            scan(store, access, original)
            assertFalse(store.applyIfActive(held, text) { true })
            assertNull(store.snapshot(access)!!.files.single().displayOverride)
            assertTrue(store.applyIfActive(capture(), text) { true })
        }
    }

    @Test fun cancelledBeforeAtomicReplacementDoesNotChangeDiskOrRevive() {
        var active = true
        var retireOnStage = false
        val path = path()
        DeviceListeningStore(path, commitFault = { if (retireOnStage && it == "beforeReplace") active = false }).use { store ->
            val access = store.unlock()
            store.putGrant(access, grant)
            scan(store, access, original)
            val before = path.readBytes()
            val preview = store.captureMetadata(access, store.snapshot(access)!!.files.single().owner)!!
            retireOnStage = true
            assertFalse(store.applyIfActive(preview, text) { active })
            assertArrayEquals(before, path.readBytes())
            assertNull(store.snapshot(access)!!.files.single().displayOverride)
            retireOnStage = false
            assertTrue(store.applyIfActive(preview, text) { true })
        }
    }

    @Test fun providerProvenFoldCarriesOnlyExactRevisionOverlayAndRetiresHeldReview() {
        val path = path()
        val peer = original.copy(objectId = ProviderObjectId("test", "new index key"), locator = ProviderLocator("test", "peer"))
        val folded = peer.copy(formerObjectIds = setOf(original.objectId))
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            store.putGrant(access, grant)
            scan(store, access, original, peer)
            val row = store.snapshot(access)!!.files.single { it.objectId == original.objectId }
            assertTrue(store.applyIfActive(store.captureMetadata(access, row.owner)!!, text) { true })
            val held = store.captureMetadata(access, row.owner)!!
            assertEquals(Mutation.APPLIED, scan(store, access, folded))
            assertFalse(store.applyIfActive(held, LocalDisplayText("Wrong", null, null)) { true })
            val replacement = store.snapshot(access)!!.resolve(row.owner)!!
            assertEquals("Accepted", replacement.displayTitle)
            val current = store.captureMetadata(access, replacement.owner)!!
            assertTrue(store.applyIfActive(current, LocalDisplayText(null, "New artist", null)) { true })
        }
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            assertEquals(LocalDisplayText("Accepted", "New artist", "Accepted album"), store.snapshot(access)!!.files.single().displayOverride?.text)
            val grantOff = grant.copy(state = AccessState.REVOKED)
            val held = store.captureMetadata(access, store.snapshot(access)!!.files.single().owner)!!
            store.putGrant(access, grantOff)
            store.putGrant(access, grant)
            scan(store, access, folded)
            assertFalse(store.applyIfActive(held, text) { true })
            scan(store, access, folded.copy(revision = ContentRevision("b".repeat(64), 400)))
            assertNull(store.snapshot(access)!!.files.single().displayOverride)
        }
    }
}
