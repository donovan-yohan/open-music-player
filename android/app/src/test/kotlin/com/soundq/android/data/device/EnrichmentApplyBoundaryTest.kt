package com.soundq.android.data.device

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.product.EnrichmentApplyState
import com.soundq.android.product.LocalEnrichmentVisit
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** The real repository, AccountSession, visit and on-disk store. Only the OS permission result is held. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28], application = EnrichmentApplyBoundaryTest.PermissionApplication::class)
class EnrichmentApplyBoundaryTest {
    class PermissionApplication : Application() {
        @Volatile var allowed = true
        @Volatile var query: (() -> Boolean)? = null
        override fun checkSelfPermission(permission: String): Int {
            if (permission != Manifest.permission.READ_EXTERNAL_STORAGE) return super.checkSelfPermission(permission)
            return if (query?.invoke() ?: allowed) PackageManager.PERMISSION_GRANTED else PackageManager.PERMISSION_DENIED
        }
    }

    @Test fun heldFinalPermissionCannotCommitAfterVisitCloses() = heldFinalPermission { f, visit ->
        visit.close()
        assertFalse(visit.active())
        assertTrue(f.visit().active()) // a replacement visit cannot renew the captured one
    }

    @Test fun heldFinalPermissionCannotCommitAfterSameAccountAba() = heldFinalPermission { f, visit ->
        val session = f.graph.session
        assertTrue(session.lockLocal())
        val ticket = checkNotNull(session.localUnlockTicket())
        assertTrue(session.completeLocalUnlock(ticket))
        assertEquals(visit.account.accountId, session.capture()!!.accountId)
        assertFalse(session.current(visit.account))
    }

    @Test fun editorDenialRetiresOldCaptureAcrossRegrantWithoutScan() = runBlocking {
        Fixture().use { f ->
            val visit = f.visit()
            val old = f.capture(visit)
            val before = f.disk.readBytes()
            val scan = f.repo.state.value.scan
            f.app.allowed = false
            assertFalse(f.repo.enrichmentCurrent(old))
            f.app.allowed = true
            assertSame(scan, f.repo.state.value.scan)
            assertFalse(f.repo.enrichmentCurrent(old))
            assertFalse(f.apply(old, visit))
            assertArrayEquals(before, f.disk.readBytes())
            val fresh = f.visit()
            assertTrue(f.apply(f.capture(fresh), fresh))
            assertEquals("Accepted", f.repo.state.value.snapshot!!.files.single().displayTitle)
            assertEquals("Accepted", decodeDomain(f.disk.readBytes()).files.single().displayTitle)
        }
    }

    @Test fun heldAllowedSampleCannotUndoAnotherEditorsObservedDenial() = heldFinalPermission { f, visit ->
        f.app.allowed = false
        assertFalse(f.repo.enrichmentCurrent(f.heldSource!!))
        f.app.allowed = true
        assertTrue(visit.active())
    }

    @Test fun denialAfterPermissionSampleAndStageSyncStillFencesActualReplace() = runBlocking {
        Fixture().use { f ->
            val visit = f.visit()
            val source = f.capture(visit)
            val bytes = f.disk.readBytes()
            val staged = CountDownLatch(1)
            val release = CountDownLatch(1)
            f.beforeReplace = { staged.countDown(); check(release.await(10, SECONDS)) }
            val apply = async(Dispatchers.IO) { f.repo.applyEnrichment(source, change) { true } }
            try {
                assertTrue(staged.await(10, SECONDS))
                f.app.allowed = false
                assertFalse(f.repo.enrichmentCurrent(source))
                f.app.allowed = true
                assertArrayEquals(bytes, f.disk.readBytes())
            } finally { release.countDown() }
            assertSame(MetadataApplyResult.Refused, apply.await())
            assertArrayEquals(bytes, f.disk.readBytes())
            f.beforeReplace = null
            val fresh = f.visit()
            assertTrue(f.apply(f.capture(fresh), fresh))
        }
    }

    @Test fun beforeReplaceIsARefusalWithExactOldBytesAndExplicitRetry() = runBlocking {
        Fixture().use { f ->
            val visit = f.visit()
            val source = f.capture(visit)
            val before = f.disk.readBytes()
            f.fault = "beforeReplace"
            val refused = EnrichmentApplyState.settled(f.applyResult(source, visit))
            assertSame(EnrichmentApplyState.Refused, refused)
            assertTrue(refused.canApply)
            assertEquals(1, f.faults.get())
            assertArrayEquals(before, f.disk.readBytes())
            assertNull(f.repo.state.value.snapshot!!.files.single().displayOverride)
            f.fault = null
            assertTrue(f.apply(source, visit))
            assertEquals("Accepted", decodeDomain(f.disk.readBytes()).files.single().displayTitle)
        }
    }

    @Test fun afterReplaceStaysUnconfirmedUntilOwnedReadback() = runBlocking {
        Fixture().use { f ->
            val visit = f.visit()
            val source = f.capture(visit)
            val before = f.disk.readBytes()
            f.fault = "afterReplace"
            val unconfirmed = EnrichmentApplyState.settled(f.applyResult(source, visit))
            assertEquals(1, f.faults.get())
            val replaced = f.disk.readBytes()
            assertFalse(before.contentEquals(replaced))
            assertEquals("Accepted", decodeDomain(replaced).files.single().displayTitle)
            assertNull(f.repo.state.value.snapshot!!.files.single().displayOverride)
            f.fault = null
            assertTrue(unconfirmed is EnrichmentApplyState.NeedsReadback)
            assertFalse(unconfirmed.canApply)
            val receipt = (unconfirmed as EnrichmentApplyState.NeedsReadback).receipt

            // Even a caller bypassing the presentation gate cannot dispatch another replace.
            assertSame(MetadataApplyResult.Refused, f.applyResult(source, visit, LocalDisplayText("Blind retry", null, null)))
            assertArrayEquals(replaced, f.disk.readBytes())
            val unrelatedReceipt = MetadataApplyResult.Unconfirmed(source.metadata)
            assertSame(unrelatedReceipt, f.repo.checkEnrichment(source, unrelatedReceipt))
            assertNull(f.repo.state.value.snapshot!!.files.single().displayOverride)
            assertSame(EnrichmentApplyState.Confirmed,
                EnrichmentApplyState.settled(f.repo.checkEnrichment(source, receipt)))
            assertEquals("Accepted", f.repo.state.value.snapshot!!.files.single().displayTitle)
            assertArrayEquals(replaced, f.disk.readBytes())
            assertFalse(f.apply(source, visit))

            val fresh = f.visit()
            val current = f.capture(fresh)
            assertSame(MetadataApplyResult.Applied, f.applyResult(current, fresh, LocalDisplayText("Newer", null, null)))
            val newer = f.disk.readBytes()
            assertEquals("Newer", decodeDomain(newer).files.single().displayTitle)
            assertSame(receipt, f.repo.checkEnrichment(source, receipt))
            assertArrayEquals(newer, f.disk.readBytes())
        }
    }

    @Test fun uncertaintyDoesNotOverwriteAConflictingSuccessorDocument() = runBlocking {
        Fixture().use { f ->
            val visit = f.visit()
            val source = f.capture(visit)
            f.fault = "afterReplace"
            val receipt = f.applyResult(source, visit) as MetadataApplyResult.Unconfirmed
            f.fault = null
            // A noncooperating writer is deliberately outside the OS-lock protocol. An exact
            // receipt must not overwrite or adopt its bytes, even if the document decodes.
            val uncertainBytes = f.disk.readBytes()
            val uncertain = decodeDomain(uncertainBytes)
            val newer = encodeDomain(uncertain.copy(revision = uncertain.revision + 1)).toString().toByteArray()
            f.disk.writeBytes(newer)
            assertSame(receipt, f.repo.checkEnrichment(source, receipt))
            assertFalse(f.apply(source, visit))
            assertArrayEquals(newer, f.disk.readBytes())
            assertNull(f.repo.state.value.snapshot!!.files.single().displayOverride)
        }
    }

    @Test fun closingUnconfirmedVisitWithholdsItsReceiptAndFreshCaptureReadsBackBeforeApply() = runBlocking {
        Fixture().use { f ->
            val visit = f.visit()
            val source = f.capture(visit)
            f.fault = "afterReplace"
            val receipt = f.applyResult(source, visit) as MetadataApplyResult.Unconfirmed
            f.fault = null
            val written = f.disk.readBytes()
            visit.close()
            assertSame(receipt, f.repo.checkEnrichment(source, receipt))
            assertNull(f.repo.state.value.snapshot!!.files.single().displayOverride)

            val oldRowVisit = f.visit()
            assertNull(f.repo.captureEnrichment(oldRowVisit.account, oldRowVisit.row, oldRowVisit.gate))
            assertEquals("Accepted", f.repo.state.value.snapshot!!.files.single().displayTitle)
            assertArrayEquals(written, f.disk.readBytes())
            val fresh = f.visit()
            assertSame(MetadataApplyResult.Applied, f.applyResult(f.capture(fresh), fresh, LocalDisplayText("Fresh", null, null)))
        }
    }

    @Test fun refreshRecoversAbandonedAttemptedBytesAfterUnpublishingTheRow() = runBlocking {
        Fixture().use { f ->
            val visit = f.visit()
            val source = f.capture(visit)
            val before = f.disk.readBytes()
            f.fault = "afterReplace"
            val receipt = f.applyResult(source, visit) as MetadataApplyResult.Unconfirmed
            f.fault = null
            val attempted = f.disk.readBytes()
            assertFalse(before.contentEquals(attempted))
            assertEquals("Accepted", decodeDomain(attempted).files.single().displayTitle)
            f.refreshOnce().also { assertNull(it.snapshot); assertFalse(it.ready) }
            assertTrue(visit.active())
            assertArrayEquals(attempted, f.disk.readBytes())

            // The production dismiss/pause path closes this very visit; there is no row from
            // which to enter Enrich. Use only the ordinary Local audio refresh entry point.
            visit.close()
            assertSame(receipt, f.repo.checkEnrichment(source, receipt))
            assertNull(f.repo.observed(f.repo.reference(visit.row)))
            val recovered = f.refreshOnce()
            assertEquals("Refresh must republish from the same writer without another Enrich entry",
                "Accepted", recovered.snapshot?.files?.single()?.displayTitle)
            assertTrue(recovered.ready && recovered.permission)
            assertEquals(visit.row.owner, recovered.snapshot!!.files.single().owner)
            assertArrayEquals(attempted, f.disk.readBytes())
            assertEquals(1, f.faults.get())
            assertSame(receipt, f.repo.checkEnrichment(source, receipt))
        }
    }

    @Test fun liveVisitKeepsTheOnlyReceiptWhileARefreshIsHeld() = runBlocking {
        Fixture().use { f ->
            val attempt = f.uncertain()
            val other = f.visit()
            assertNull(f.repo.captureEnrichment(other.account, other.row, other.gate))
            assertNull(f.repo.state.value.snapshot!!.files.single().displayOverride)
            f.refreshOnce().also { assertNull(it.snapshot) }
            f.withHeldRefresh {
                assertTrue(attempt.visit.active())
                assertNull(f.repo.state.value.snapshot)
                val forged = MetadataApplyResult.Unconfirmed(attempt.source.metadata)
                assertSame(forged, f.repo.checkEnrichment(attempt.source, forged))
                assertNull(f.repo.state.value.snapshot)
                assertSame(MetadataApplyResult.Applied, f.repo.checkEnrichment(attempt.source, attempt.receipt))
                assertEquals("Accepted", f.repo.state.value.snapshot!!.files.single().displayTitle)
                assertArrayEquals(attempt.attempted, f.disk.readBytes())
            }
        }
    }

    @Test fun refreshRepublishesExactPriorBytesWithoutReportingApplySuccess() = runBlocking {
        Fixture().use { f ->
            val attempt = f.uncertain()
            f.refreshOnce().also { assertNull(it.snapshot) }
            // Model the exact previous image being visible after an ambiguous replacement.
            f.disk.writeBytes(attempt.prior)
            attempt.visit.close()
            val recovered = f.refreshOnce()
            assertEquals(attempt.visit.row, recovered.snapshot?.files?.single())
            assertTrue(recovered.ready && recovered.permission)
            assertArrayEquals(attempt.prior, f.disk.readBytes())
            assertSame(attempt.receipt, f.repo.checkEnrichment(attempt.source, attempt.receipt))
            assertEquals(1, f.writerOpens.get())
            assertEquals(1, f.replaces.get())
        }
    }

    @Test fun liveCheckAlsoRepublishesThePriorRowAfterARefreshUnpublishesIt() = runBlocking {
        Fixture().use { f ->
            val attempt = f.uncertain()
            f.refreshOnce().also { assertNull(it.snapshot) }
            f.disk.writeBytes(attempt.prior)
            val read = f.repo.checkEnrichment(attempt.source, attempt.receipt)
            assertSame(EnrichmentApplyState.Refused, EnrichmentApplyState.settled(read))
            assertEquals(attempt.visit.row, f.repo.state.value.snapshot?.files?.single())
            assertArrayEquals(attempt.prior, f.disk.readBytes())
            assertEquals(1, f.replaces.get())
        }
    }

    @Test fun refreshNeverAdoptsOrOverwritesAConflictingDocumentAfterClose() = runBlocking {
        Fixture().use { f ->
            val attempt = f.uncertain()
            f.refreshOnce().also { assertNull(it.snapshot) }
            attempt.visit.close()
            val state = decodeDomain(attempt.attempted)
            val conflict = encodeDomain(state.copy(revision = state.revision + 1)).toString().toByteArray()
            f.disk.writeBytes(conflict)
            repeat(2) {
                f.refreshOnce().also { assertNull(it.snapshot); assertFalse(it.ready) }
                assertArrayEquals(conflict, f.disk.readBytes())
            }
            // Rejecting foreign bytes did not discard the pending evidence or adopt a new base.
            f.disk.writeBytes(attempt.attempted)
            assertEquals("Accepted", f.refreshOnce().snapshot?.files?.single()?.displayTitle)
            assertEquals(1, f.writerOpens.get())
            assertEquals(1, f.replaces.get())
            assertArrayEquals(attempt.attempted, f.disk.readBytes())
        }
    }

    @Test fun replacementAccountRefreshUsesItsOwnHistoryWithoutInheritingTheOldReceipt() = runBlocking {
        Fixture(history = true).use { f ->
            assertEquals(listOf(f.serverKey("fixture")), f.repo.state.value.snapshot!!.history.map { it.key })
            val attempt = f.uncertain()
            f.refreshOnce().also { assertNull(it.snapshot) }
            val session = f.graph.session
            // Leave the old visit gate open: account retirement itself removes its Check authority.
            f.withHeldRefresh {
                assertTrue(session.lockLocal())
                withTimeout(10_000) { f.repo.state.first { it == PhoneAudioState() } }
                assertTrue(attempt.visit.active())
                assertSame(attempt.receipt, f.repo.checkEnrichment(attempt.source, attempt.receipt))
                assertArrayEquals(attempt.attempted, f.disk.readBytes())
                assertTrue(session.accept(session.beginIntent(), SecretTokens("other-access", "other-refresh", "other")))
            }
            val published = withTimeout(10_000) { f.repo.state.first { it.scan != null && !it.refreshing && it.snapshot != null } }
            val snapshot = published.snapshot!!
            assertEquals(listOf(f.serverKey("other")), snapshot.history.map { it.key })
            assertEquals("Accepted", snapshot.files.single().displayTitle)
            assertTrue(published.permission)
            assertSame(attempt.receipt, f.repo.checkEnrichment(attempt.source, attempt.receipt))
            assertArrayEquals(attempt.attempted, f.disk.readBytes())
            assertEquals(1, f.writerOpens.get())
            assertEquals(1, f.replaces.get())
        }
    }

    @Test fun deniedRefreshRecoversLocallyButPublishesTheObservedRevokedGrant() = runBlocking {
        Fixture().use { f ->
            val attempt = f.uncertain()
            f.refreshOnce().also { assertNull(it.snapshot) }
            f.app.allowed = false
            val denied = f.refreshOnce()
            assertTrue(denied.ready)
            assertFalse(denied.permission)
            assertEquals(PhoneScanObservation(false, true, false), denied.scan)
            val revoked = denied.snapshot!!.files.single()
            assertEquals("Accepted", revoked.displayTitle)
            assertFalse(revoked.available)
            assertEquals(AccessState.REVOKED, denied.snapshot.grants.single().state)
            f.app.allowed = true
            assertSame(attempt.receipt, f.repo.checkEnrichment(attempt.source, attempt.receipt))
            val beforeGrant = decodeDomain(attempt.attempted)
            val afterGrant = decodeDomain(f.disk.readBytes())
            assertEquals(beforeGrant.revision + 1, afterGrant.revision)
            assertEquals(beforeGrant, afterGrant.copy(revision = beforeGrant.revision, grants = beforeGrant.grants,
                files = listOf(afterGrant.files.single().copy(aliases = beforeGrant.files.single().aliases))))
            assertEquals(2, f.replaces.get()) // one Apply and the normal grant revocation, not another Apply
        }
    }

    @Test fun unrelatedGrantReplacementFaultStaysFailClosedDuringOrdinaryRefresh() = runBlocking {
        Fixture().use { f ->
            val bytes = f.disk.readBytes()
            f.refreshOnce().also { assertTrue(it.ready && it.permission); assertNotNull(it.scan) }
            assertArrayEquals(bytes, f.disk.readBytes())
            assertEquals(0, f.replaces.get())
            f.app.allowed = false
            f.fault = "afterReplace"
            f.refreshOnce().also { assertNull(it.snapshot); assertFalse(it.permission) }
            assertEquals(1, f.faults.get())
            val replaced = f.disk.readBytes()
            assertFalse(bytes.contentEquals(replaced))
            assertEquals(AccessState.REVOKED, decodeDomain(replaced).grants.single().state)
            f.app.allowed = true
            f.fault = null
            f.refreshOnce().also { assertNull(it.snapshot); assertFalse(it.ready) }
            assertArrayEquals(replaced, f.disk.readBytes())
            assertEquals(1, f.replaces.get())
            assertEquals(1, f.writerOpens.get())
        }
    }

    @Test fun permissionProbeDoesNotHoldJournalAndOriginalAbaCannotCommit() = runBlocking {
        Fixture().use { f ->
            val visit = f.visit()
            val source = f.capture(visit)
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val calls = AtomicInteger()
            f.app.query = {
                if (calls.incrementAndGet() == 1) {
                    entered.countDown()
                    check(release.await(10, SECONDS))
                }
                true
            }
            val result = async(Dispatchers.IO) { f.repo.applyEnrichment(source, change) { true } }
            val afterAba = try {
                assertTrue(entered.await(10, SECONDS))
                withTimeout(5_000) {
                    assertEquals(Mutation.APPLIED, f.rescan(f.original.copy(revision = ContentRevision("b".repeat(64), 123))))
                    assertEquals(Mutation.APPLIED, f.rescan(f.original))
                }
                val successor = f.repo.state.value.snapshot!!.files.single()
                assertEquals(source.metadata.row.owner.revision, successor.owner.revision)
                assertNotEquals(source.metadata.row.owner, successor.owner)
                f.disk.readBytes()
            } finally { release.countDown() }
            assertSame(MetadataApplyResult.Refused, result.await())
            assertArrayEquals(afterAba, f.disk.readBytes())
            val fresh = f.visit()
            assertTrue(f.apply(f.capture(fresh), fresh))
        }
    }

    private fun heldFinalPermission(retire: suspend (Fixture, LocalEnrichmentVisit) -> Unit) = runBlocking {
        Fixture().use { f ->
            val visit = f.visit()
            val source = f.capture(visit)
            f.heldSource = source
            val before = f.disk.readBytes()
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val count = AtomicInteger()
            f.app.query = {
                val sampled = f.app.allowed
                if (count.incrementAndGet() == FINAL_APPLY_QUERY) {
                    entered.countDown()
                    check(release.await(10, SECONDS))
                }
                sampled
            }
            val result = async(Dispatchers.IO) { f.apply(source, visit) }
            try {
                assertTrue("final permission never entered", entered.await(10, SECONDS))
                retire(f, visit)
                assertArrayEquals(before, f.disk.readBytes())
            } finally { release.countDown() }
            val applied = result.await()
            f.app.query = null
            assertArrayEquals(before, f.disk.readBytes())
            assertFalse(applied)
            // Both the repository and the store remain usable for a fresh explicit edit.
            withTimeout(10_000) { f.repo.state.first { f.repo.current(f.graph.session.version()) && it.scan != null && !it.refreshing } }
            val fresh = f.visit()
            assertTrue(f.apply(f.capture(fresh), fresh))
        }
    }

    private suspend fun Fixture.apply(source: PhoneEnrichmentSource, visit: LocalEnrichmentVisit) =
        applyResult(source, visit) == MetadataApplyResult.Applied
    private suspend fun Fixture.applyResult(source: PhoneEnrichmentSource, visit: LocalEnrichmentVisit, proposed: LocalDisplayText = change) =
        repo.applyEnrichment(source, proposed) { visit.active() }

    private data class Uncertain(val visit: LocalEnrichmentVisit, val source: PhoneEnrichmentSource,
        val receipt: MetadataApplyResult.Unconfirmed, val prior: ByteArray, val attempted: ByteArray)

    private suspend fun Fixture.uncertain(): Uncertain {
        val visit = visit()
        val source = capture(visit)
        val prior = disk.readBytes()
        fault = "afterReplace"
        val receipt = applyResult(source, visit) as MetadataApplyResult.Unconfirmed
        fault = null
        val attempted = disk.readBytes()
        assertFalse(prior.contentEquals(attempted))
        assertEquals("Accepted", decodeDomain(attempted).files.single().displayTitle)
        assertEquals(1, faults.get())
        return Uncertain(visit, source, receipt, prior, attempted)
    }

    internal class Fixture(history: Boolean = false, start: Boolean = true) : AutoCloseable {
        val app = RuntimeEnvironment.getApplication() as PermissionApplication
        @Volatile var fault: String? = null
        @Volatile var beforeReplace: (() -> Unit)? = null
        val faults = AtomicInteger()
        val writerOpens = AtomicInteger()
        val replaces = AtomicInteger()
        val requests = AtomicInteger()
        private val client = okhttp3.OkHttpClient.Builder().addInterceptor {
            requests.incrementAndGet()
            throw IOException("Network is out of scope for this phone-owner fixture")
        }.build()
        val graph = AppGraph(app, ApiEndpoint.parse("https://fixture.invalid/api/v1"), client, store = object : SessionStore {
            override fun load(endpoint: ApiEndpoint): SecretTokens? = null
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) = Unit
            override fun clear() = Unit
        }, openPhoneAudioStore = { file ->
            writerOpens.incrementAndGet()
            DeviceListeningStore(file) { phase ->
                if (phase == "beforeReplace") beforeReplace?.invoke()
                if (phase == "afterReplace") replaces.incrementAndGet()
                if (phase == fault) { faults.incrementAndGet(); throw IOException("fixture fault at $phase") }
            }
        })
        val repo = graph.phoneAudio
        val disk = File(graph.directory, "phone-listening.v1.json")
        var heldSource: PhoneEnrichmentSource? = null
        private val grant = ScanGrantId(UUID.nameUUIDFromBytes("indexed:external-audio".toByteArray()))
        val original = DiscoveredAudio(ProviderObjectId("android-content", "fixture"), ProviderLocator("media", "content://media/fixture"),
            ContentRevision("a".repeat(64), 123), OriginalMetadata("original.flac", "Original"), 602_000L)
        init {
            DeviceListeningStore(disk).use { store ->
                val access = store.unlock()
                check(store.putGrant(access, ScanGrant(grant, GrantKind.INDEXED, "Android audio index",
                    ProviderLocator("android", "indexed:external-audio"), false, AccessState.AVAILABLE)) == Mutation.APPLIED)
                check(store.publishScan(checkNotNull(store.beginScan(access, grant)), listOf(original)) == Mutation.APPLIED)
                if (history) for (account in listOf("fixture", "other")) {
                    val key = serverKey(account)
                    val capture = checkNotNull(store.captureServerHistory(store.unlock(key.scope), key))
                    check(store.playedServer(SuccessfulServerPlaybackReceipt(capture, 42L)) == Mutation.APPLIED)
                }
            }
            check(graph.session.accept(graph.session.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", "fixture")))
            if (start) {
                repo.start()
                runBlocking { withTimeout(10_000) { repo.state.first { it.scan != null && !it.refreshing } } }
            }
        }
        suspend fun rescan(row: DiscoveredAudio) = repo.journal(publishState = true) { store, access ->
            store.publishScan(checkNotNull(store.beginScan(access, grant)), listOf(row))
        }
        suspend fun refreshOnce(): PhoneAudioState = coroutineScope {
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            app.query = {
                if (repo.state.value.refreshing) {
                    entered.countDown()
                    check(release.await(10, SECONDS))
                }
                app.allowed
            }
            try {
                repo.refresh()
                withContext(Dispatchers.IO) { assertTrue("refresh never reached its running permission sample", entered.await(10, SECONDS)) }
                assertTrue(repo.state.value.refreshing)
            } finally { release.countDown(); app.query = null }
            withTimeout(10_000) { repo.state.first { !it.refreshing } }
        }
        suspend fun withHeldRefresh(block: suspend () -> Unit) {
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val calls = AtomicInteger()
            val version = graph.session.version()
            repo.refresh {
                // The first validity check is before refreshLock and the ordinary store transaction.
                if (calls.incrementAndGet() == 1) {
                    entered.countDown()
                    check(release.await(10, SECONDS))
                }
                repo.current(version)
            }
            try {
                withContext(Dispatchers.IO) { assertTrue("held refresh never entered", entered.await(10, SECONDS)) }
                block()
            } finally { release.countDown() }
        }
        fun serverKey(account: String) = HistoryKey.Server(ServerAccount(graph.endpoint.identity, account), ServerAudioId(1))
        fun visit() = LocalEnrichmentVisit(graph.session.capture()!!, repo.state.value.snapshot!!.files.single())
        suspend fun capture(visit: LocalEnrichmentVisit) = checkNotNull(repo.captureEnrichment(visit.account, visit.row, visit.gate))
        override fun close() { app.query = null; graph.close() }
    }

    companion object {
        private const val FINAL_APPLY_QUERY = 1
        private val change = LocalDisplayText("Accepted", null, null)
    }
}
