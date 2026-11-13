package com.soundq.android.data.deviceaudio

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/** A row-local IO failure is not an account/access event. Uses the real durable store. */
class UnavailableIsolationTest {
    private fun runCase(reason: AccessState, preload: Boolean) {
        val root = Files.createTempDirectory("unavailable-isolation-").toFile()
        try { DeviceListeningStore(File(root, "domain.json")).use { store ->
            val access = store.unlock()
            val grant = ScanGrant(ScanGrantId(UUID.randomUUID()), GrantKind.INDEXED, "index", ProviderLocator("android", "index"), true)
            assertEquals(Mutation.APPLIED, store.putGrant(access, grant))
            fun row(name: String) = DiscoveredAudio(ProviderObjectId("media", name), ProviderLocator("media", name),
                ContentRevision(name.repeat(64), 123), OriginalMetadata("$name.wav"), 700000)
            assertEquals(Mutation.APPLIED, store.publishScan(store.beginScan(access, grant.id)!!, listOf(row("a"), row("b"))))
            val files = store.snapshot(access)!!.files
            val a = store.captureSource(access, files[0].id)!!
            val b = store.captureSource(access, files[1].id)!!
            fun begin(source: SourceCapture) = store.beginTraversal(source, UUID.randomUUID(), 7, 0, 0, 700000)!!
            val playing = begin(b)
            val queued = if (preload) begin(a) else null
            assertEquals(Mutation.APPLIED, store.played(SuccessfulPlaybackReceipt(playing, 1, 1234)))
            assertEquals(Mutation.APPLIED, store.checkpoint(SourcePositionCheckpoint(playing, 2, 42000)))
            assertEquals(Mutation.APPLIED, store.reportUnavailable(a, files[0].aliases.single().locator, reason))
            assertEquals("B retains its live checkpoint authority ($reason, preload=$preload)", Mutation.APPLIED,
                store.checkpoint(SourcePositionCheckpoint(playing, 3, 43000)))
            assertEquals(43000L, store.bookmark(b)!!.positionMs)
            assertNull(store.captureSource(access, files[0].id))
            assertNull(store.beginTraversal(a, UUID.randomUUID(), 8, 0, 0, 700000))
            if (queued != null) {
                assertEquals(Mutation.REFUSED, store.played(SuccessfulPlaybackReceipt(queued, 1, 9999)))
                assertEquals(Mutation.REFUSED, store.complete(QualifiedNaturalEnd(queued, 2, queued.occurrence, 7, 0, 1)))
            }
            assertEquals(Mutation.APPLIED, store.complete(QualifiedNaturalEnd(playing, 4, playing.occurrence, 7, 0, 1)))
            assertEquals(1234L, store.snapshot(access)!!.history.single().playedAtEpochMs)
            assertNull(store.snapshot(access)!!.history.single().bookmark)
            // The scoped repair must not weaken a genuine grant revoke or a later content revision.
            val fresh = store.captureSource(access, files[1].id)!!
            val next = begin(fresh)
            assertEquals(Mutation.APPLIED, store.putGrant(access, grant.copy(state = AccessState.REVOKED)))
            assertEquals(Mutation.REFUSED, store.played(SuccessfulPlaybackReceipt(next, 1, 9999)))
            assertNull(store.beginTraversal(fresh, UUID.randomUUID(), 9, 0, 0, 700000))
        } } finally { root.deleteRecursively() }
    }
    @Test fun missingUnqueuedFilePreservesOtherTraversal() = runCase(AccessState.MISSING, false)
    @Test fun missingPreparedFilePreservesOutgoingTraversal() = runCase(AccessState.MISSING, true)
    @Test fun unreadableFilePreservesOtherTraversal() = runCase(AccessState.UNREADABLE, true)
    @Test fun unsupportedFilePreservesOtherTraversal() = runCase(AccessState.UNSUPPORTED, false)

    @Test fun scanStartedBeforeDeletionCannotRestoreMissingFileOrRetireOtherTraversal() {
        val root = Files.createTempDirectory("unavailable-scan-").toFile()
        try { DeviceListeningStore(File(root, "domain.json")).use { store ->
            val access = store.unlock()
            val grant = ScanGrant(ScanGrantId(UUID.randomUUID()), GrantKind.INDEXED, "index", ProviderLocator("media", "index"), true)
            store.putGrant(access, grant)
            fun row(name: String) = DiscoveredAudio(ProviderObjectId("media", name), ProviderLocator("media", name),
                ContentRevision(name.repeat(64), 123), OriginalMetadata("$name.wav"), 700000)
            val a = row("a"); val b = row("b")
            store.publishScan(store.beginScan(access, grant.id)!!, listOf(a, b))
            val files = store.snapshot(access)!!.files
            val deleted = store.captureSource(access, files.single { it.objectId == a.objectId }.id)!!
            val playing = store.captureSource(access, files.single { it.objectId == b.objectId }.id)!!
            val traversal = store.beginTraversal(playing, UUID.randomUUID(), 7, 0, 0, 700000)!!
            assertEquals(Mutation.APPLIED, store.played(SuccessfulPlaybackReceipt(traversal, 1, 1234)))
            assertEquals(Mutation.APPLIED, store.checkpoint(SourcePositionCheckpoint(traversal, 2, 42000)))
            val heldScan = store.beginScan(access, grant.id)!!
            assertEquals(Mutation.APPLIED, store.reportUnavailable(deleted, a.locator, AccessState.MISSING, allAliases = true))
            assertEquals("A proof collected before deletion cannot publish after it", Mutation.REFUSED,
                store.publishScan(heldScan, listOf(a, b)))
            assertFalse(store.snapshot(access)!!.files.single { it.objectId == a.objectId }.available)
            assertEquals(Mutation.APPLIED, store.checkpoint(SourcePositionCheckpoint(traversal, 3, 43000)))
            assertEquals(Mutation.UNCHANGED, store.publishScan(store.beginScan(access, grant.id)!!, listOf(b)))
            assertEquals(Mutation.APPLIED, store.complete(QualifiedNaturalEnd(traversal, 4, traversal.occurrence, 7, 0, 1)))
        } } finally { root.deleteRecursively() }
    }

    @Test fun reportingOneAliasRetiresAllOldCapturesOfThatObjectButNotOtherObjects() {
        val root = Files.createTempDirectory("unavailable-alias-").toFile()
        try { DeviceListeningStore(File(root, "domain.json")).use { store ->
            val access = store.unlock()
            val g = ScanGrant(ScanGrantId(UUID.randomUUID()), GrantKind.INDEXED, "index", ProviderLocator("media", "index"), true)
            store.putGrant(access, g)
            val a = DiscoveredAudio(ProviderObjectId("media", "a"), ProviderLocator("media", "a1"), ContentRevision("a".repeat(64), 123), OriginalMetadata("a.wav"), 700000)
            store.publishScan(store.beginScan(access, g.id)!!, listOf(a, a.copy(locator = ProviderLocator("media", "a2"))))
            val file = store.snapshot(access)!!.files.single()
            val old = store.captureSource(access, file.id)!!
            val t = store.beginTraversal(old, UUID.randomUUID(), 1, 0, 0, 700000)!!
            assertEquals(Mutation.APPLIED, store.reportUnavailable(old, a.locator, AccessState.MISSING))
            assertTrue(store.snapshot(access)!!.files.single().available) // another route is still usable
            assertEquals(Mutation.REFUSED, store.played(SuccessfulPlaybackReceipt(t, 1, 1234)))
            assertNull(store.beginTraversal(old, UUID.randomUUID(), 2, 0, 0, 700000))
            assertNotNull(store.captureSource(access, file.id)) // only a fresh admission may use that route
        } } finally { root.deleteRecursively() }
    }
}
