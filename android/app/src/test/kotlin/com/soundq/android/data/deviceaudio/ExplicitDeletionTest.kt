package com.soundq.android.data.deviceaudio

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/** App-confirmed deletion is retained evidence, not active Library membership or a grant revocation. */
class ExplicitDeletionTest {
    private class Fixture : AutoCloseable {
        val root = Files.createTempDirectory("explicit-deletion-").toFile()
        val path = File(root, "domain.json")
        var failCommit = false
        val store = DeviceListeningStore(path) { if (failCommit && it == "beforeReplace") error("test-owned commit refusal") }
        val access = store.unlock()
        val grant = ScanGrant(ScanGrantId(UUID.randomUUID()), GrantKind.INDEXED, "index", ProviderLocator("media", "index"), true)
        val a = audio("a")
        // Same content, different provider-proved physical object. Deletion must never follow the SHA.
        val b = audio("b")
        val alias = a.copy(locator = ProviderLocator("media", "a-alias"))
        init {
            check(store.putGrant(access, grant) == Mutation.APPLIED)
            check(store.publishScan(store.beginScan(access, grant.id)!!, listOf(a, alias, b)) == Mutation.APPLIED)
        }
        fun row(d: DiscoveredAudio) = store.snapshot(access)!!.files.single { it.objectId == d.objectId }
        fun source(d: DiscoveredAudio) = store.captureSource(access, row(d).id)!!
        fun delete(source: SourceCapture = source(a), locator: ProviderLocator = a.locator) =
            store.reportUnavailable(source, locator, AccessState.REMOVED, allAliases = true)
        override fun close() { store.close(); root.deleteRecursively() }
        companion object {
            fun audio(name: String) = DiscoveredAudio(ProviderObjectId("media", name), ProviderLocator("media", name),
                ContentRevision("a".repeat(64), 123), OriginalMetadata("$name.wav"), 700000)
        }
    }

    @Test fun deletionRetainsHistoryAndBookmarkAcrossRestartWithoutResurrectingAliases() = Fixture().use { f ->
        val source = f.source(f.a)
        val traversal = f.store.beginTraversal(source, UUID.randomUUID(), 1, 0, 0, 700000)!!
        assertEquals(Mutation.APPLIED, f.store.played(SuccessfulPlaybackReceipt(traversal, 1, 1234)))
        assertEquals(Mutation.APPLIED, f.store.checkpoint(SourcePositionCheckpoint(traversal, 2, 42000)))
        val history = f.store.snapshot(f.access)!!.history
        assertEquals(Mutation.APPLIED, f.delete(source))
        assertFalse(f.row(f.a).aliases.any { it.state != AccessState.REMOVED })
        assertEquals(setOf(AccessState.REMOVED), f.row(f.a).aliases.map { it.state }.toSet())
        assertTrue(f.row(f.b).aliases.any { it.state != AccessState.REMOVED })
        assertTrue(f.row(f.b).available)
        assertEquals(history, f.store.snapshot(f.access)!!.history)
        assertEquals(Mutation.REFUSED, f.store.checkpoint(SourcePositionCheckpoint(traversal, 3, 43000)))
        f.store.close()
        DeviceListeningStore(f.path).use { reopened ->
            val access = reopened.unlock()
            val snapshot = reopened.snapshot(access)!!
            assertFalse(snapshot.files.single { it.objectId == f.a.objectId }.aliases.any { it.state != AccessState.REMOVED })
            assertEquals(history, snapshot.history)
            // A normal rescan and permission cycle cannot erase app-confirmed deletion evidence.
            assertEquals(Mutation.APPLIED, reopened.putGrant(access, f.grant.copy(state = AccessState.REVOKED)))
            assertFalse(reopened.snapshot(access)!!.files.single { it.objectId == f.a.objectId }.aliases.any { it.state != AccessState.REMOVED })
            reopened.putGrant(access, f.grant)
            reopened.publishScan(reopened.beginScan(access, f.grant.id)!!, listOf(f.b))
            assertFalse(reopened.snapshot(access)!!.files.single { it.objectId == f.a.objectId }.aliases.any { it.state != AccessState.REMOVED })
            assertEquals(history, reopened.snapshot(access)!!.history)
        }
    }

    @Test fun heldScanCannotRestoreAnyPhysicalAliasButFreshReplacementCanBeDiscovered() = Fixture().use { f ->
        val source = f.source(f.a)
        val held = f.store.beginScan(f.access, f.grant.id)!!
        assertEquals(Mutation.APPLIED, f.delete(source))
        assertEquals(Mutation.REFUSED, f.store.publishScan(held, listOf(f.a, f.alias, f.b)))
        assertEquals(Mutation.UNCHANGED, f.store.publishScan(f.store.beginScan(f.access, f.grant.id)!!, listOf(f.b)))
        assertFalse(f.row(f.a).aliases.any { it.state != AccessState.REMOVED })
        // A fresh proof may discover a new replacement even with identical bytes and the same provider key.
        assertEquals(Mutation.APPLIED, f.store.publishScan(f.store.beginScan(f.access, f.grant.id)!!, listOf(f.a, f.b)))
        assertTrue(f.row(f.a).aliases.any { it.state != AccessState.REMOVED })
        assertNotNull(f.source(f.a))
        assertEquals(Mutation.REFUSED, f.delete(source)) // old admission does not revive
    }

    @Test fun deletionIsAllAliasesOnlyAndRequiresCurrentSourceAndCapturedRoute() = Fixture().use { f ->
        val source = f.source(f.a)
        val bytes = f.path.readBytes()
        assertEquals(Mutation.REFUSED, f.store.reportUnavailable(source, f.a.locator, AccessState.REMOVED))
        assertEquals(Mutation.REFUSED, f.delete(source, ProviderLocator("media", "not-captured")))
        assertArrayEquals(bytes, f.path.readBytes())
        f.store.lock(); f.store.unlock(ServerAccount("endpoint", "other-account"))
        assertEquals(Mutation.REFUSED, f.delete(source))
        assertArrayEquals(bytes, f.path.readBytes())
    }

    @Test fun revokedAccessCannotConfirmDeletionOrWeakenGlobalRetirement() = Fixture().use { f ->
        val source = f.source(f.a)
        f.store.putGrant(f.access, f.grant.copy(state = AccessState.REVOKED))
        assertEquals(Mutation.REFUSED, f.delete(source))
        assertTrue(f.row(f.a).aliases.any { it.state != AccessState.REMOVED })
        assertTrue(f.row(f.b).aliases.any { it.state != AccessState.REMOVED })
        assertNull(f.store.captureSource(f.access, f.row(f.b).id))
    }

    @Test fun failedDurableAcknowledgementDoesNotPublishDeletedMembership() = Fixture().use { f ->
        val source = f.source(f.a)
        val before = f.path.readBytes()
        f.failCommit = true
        assertTrue(runCatching { f.delete(source) }.isFailure)
        assertArrayEquals(before, f.path.readBytes())
        assertNull(f.store.snapshot(f.access)) // uncertain storage fails closed, never a fabricated acknowledgement
        f.store.close()
        DeviceListeningStore(f.path).use { reopened ->
            assertTrue(reopened.snapshot(reopened.unlock())!!.files.all { it.aliases.any { it.state != AccessState.REMOVED } })
        }
    }
}
