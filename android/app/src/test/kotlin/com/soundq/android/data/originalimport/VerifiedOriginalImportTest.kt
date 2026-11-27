package com.soundq.android.data.originalimport

import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.QueueSnapshot
import com.soundq.android.playback.SavedOccurrence
import com.soundq.android.product.LibrarySource
import com.soundq.android.product.unifiedLibraryRows
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID

class VerifiedOriginalImportTest {
    @get:Rule val temp = TemporaryFolder()

    @Test fun definitiveAckRequiresExactReadbackAndProjectsOneRowWithAcceptedDisplay() {
        val f = fixture()
        f.peer.readback = { it.copy(original = it.original.copy(track = TrackId(it.original.track.value + 1))) }
        assertEquals(OriginalImportRepository.Action.ReadbackRequired, f.repo.confirm(f.choose()))
        val pending = f.repo.entries(f.scope).single()
        assertEquals(OriginalImportPhase.ReadbackRequired, pending.phase)
        assertEquals(0, f.rows(listOf()).count { it.server != null })
        assertEquals(0, f.added)
        f.peer.readback = { it }
        assertEquals(OriginalImportRepository.Action.Added, f.repo.check(f.scope, pending.intent.operation) { true })
        assertEquals(1, f.peer.writes.size)
        assertEquals(0, f.peer.checks.size) // known commit: missing readback never replays or needs a POST
        assertEquals(2, f.peer.membershipReads)
        assertArrayEquals(f.bytes, f.peer.writes.single().second)
        assertEquals(1, f.added)
        val rows = f.rows(listOf(f.server), downloads = listOf(f.server))
        assertEquals(1, rows.size)
        assertEquals(f.display.title, rows.single().title)
        assertEquals(f.selected, rows.single().originalRow)
        assertEquals(f.peer.track, rows.single().server?.id)
        assertEquals(1, f.rows(listOf(f.server), source = LibrarySource.Local).size)
        assertEquals(1, f.rows(emptyList()).size) // filtered/partial server page cannot suppress the only visible original
    }

    @Test fun lostResponseAcrossReconstructionRecoversSameOperationWithoutAnotherUpload() {
        val f = fixture()
        f.peer.dropResponse = true
        val choice = f.choose()
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repo.confirm(choice))
        assertEquals(OriginalImportPhase.Unconfirmed, f.repo.entries(f.scope).single().phase)
        assertEquals(OriginalImportRepository.Action.Retired, f.repo.confirm(choice))
        f.reconstruct()
        assertEquals(OriginalImportRepository.Action.AlreadyInProgress, f.repo.confirm(f.choose()))
        assertTrue(f.repo.associations(f.scope).isEmpty())
        assertEquals(OriginalImportRepository.Action.Added, f.repo.check(f.scope, choice.intent.operation) { true })
        assertEquals(listOf(choice.intent.operation), f.peer.checks)
        assertEquals(listOf(choice.intent), f.peer.writes.map { it.first })
        f.reconstruct()
        assertTrue(f.repo.associations(f.scope).isEmpty())
        assertEquals(OriginalImportRepository.Action.Added, f.repo.check(f.scope, choice.intent.operation) { true })
        assertEquals(choice.intent, f.repo.associations(f.scope).single().intent)
    }

    @Test fun wrongScopeOrDigestDoesNotAcknowledgeEvenWhenTrackIdMatches() {
        val f = fixture()
        val choice = f.choose()
        f.peer.receipt = { it.copy(destination = ServerAccount(it.destination.endpoint, "foreign")) }
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repo.confirm(choice))
        f.peer.receipt = { receipt -> receipt.copy(status = OriginalReceiptStatus.Committed(CommittedOriginal(f.peer.track, ContentRevision("0".repeat(64), f.bytes.size.toLong())))) }
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repo.check(f.scope, choice.intent.operation) { true })
        assertEquals(0, f.peer.membershipReads)
        f.peer.receipt = { it }
        f.peer.readback = { it.copy(destination = ServerAccount(it.destination.endpoint, "foreign")) }
        assertEquals(OriginalImportRepository.Action.ReadbackRequired, f.repo.check(f.scope, choice.intent.operation) { true })
        assertTrue(f.repo.associations(f.scope).isEmpty())
        f.peer.readback = { it }
        assertEquals(OriginalImportRepository.Action.Added, f.repo.check(f.scope, choice.intent.operation) { true })
        val a = f.scope
        val b = signIn(f.session, "B")
        assertTrue(f.repo.associations(a).isEmpty())
        assertTrue(f.repo.associations(b).isEmpty())
        assertEquals(OriginalImportRepository.Action.Retired, f.repo.check(b, choice.intent.operation) { true })
        val foreign = session("https://other.invalid/api/v1")
        assertTrue(f.newRepository(foreign).associations(signIn(foreign, "A")).isEmpty())
        val freshA = signIn(f.session, "A")
        assertTrue(f.repo.associations(freshA).isEmpty())
        assertEquals(OriginalImportRepository.Action.Added, f.repo.check(freshA, choice.intent.operation) { true })
        assertEquals(1, f.repo.associations(freshA).size)
    }

    @Test fun uncertainAndClosedNeverAuthorizeAnotherMutation() {
        val f = fixture()
        f.peer.dropResponse = true
        val choice = f.choose()
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repo.confirm(choice))
        f.peer.receipt = { it.copy(status = OriginalReceiptStatus.Unconfirmed) }
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repo.check(f.scope, choice.intent.operation) { true })
        assertEquals(OriginalImportRepository.Action.AlreadyInProgress, f.repo.confirm(f.choose()))
        f.peer.receipt = { it.copy(status = OriginalReceiptStatus.Closed) }
        assertEquals(OriginalImportRepository.Action.Closed, f.repo.check(f.scope, choice.intent.operation) { true })
        f.reconstruct()
        assertEquals(OriginalImportRepository.Action.Closed, f.repo.confirm(f.choose(ImportDisplay("different", "", ""))))
        assertEquals(listOf(choice.intent), f.peer.writes.map { it.first })
    }

    @Test fun grantLossAndDifferentFileIncarnationCannotInheritOfflineAssociation() {
        val f = fixture()
        val choice = f.choose()
        assertEquals(OriginalImportRepository.Action.Added, f.repo.confirm(choice))
        assertEquals(1, f.rows(emptyList(), deviceOnly = true).size)
        assertEquals(f.selected, f.rows(emptyList(), deviceOnly = true).single().phone)
        val revoked = f.selected.copy(aliases = f.selected.aliases.map { it.copy(state = AccessState.REVOKED) })
        f.available = false
        assertNull(f.repo.playbackTrack(f.scope, f.peer.track, choice.intent.operation.toString()))
        val offline = f.rows(emptyList(), selected = revoked, deviceOnly = true)
        assertTrue(offline.none { it.original != null || it.server != null })
        assertEquals(1, f.rows(listOf(f.server), selected = revoked).count { it.server == f.server })
        val renamedCopy = f.selected.copy(id = DeviceFileId(UUID.randomUUID()), metadata = OriginalMetadata("other-name.wav"))
        assertEquals(2, f.rows(listOf(f.server), selected = renamedCopy).size)
        assertTrue(f.rows(listOf(f.server), selected = renamedCopy).none { it.originalRow != null })
        val replacement = f.selected.copy(incarnation = f.selected.incarnation + 1)
        assertTrue(f.rows(listOf(f.server), selected = replacement).none { it.originalRow != null })
        f.available = true
        assertEquals(f.display.title, f.repo.playbackTrack(f.scope, f.peer.track, choice.intent.operation.toString())?.title)
    }

    @Test fun boundedOriginalReadRejectsSameSizedChangedBytesAndNoMutationStarts() {
        val f = fixture()
        val selected = f.choose()
        val changed = f.bytes.copyOf().also { it[80] = (it[80].toInt() xor 1).toByte() }
        f.file.writeBytes(changed)
        assertEquals(OriginalImportRepository.Action.Unavailable, f.repo.confirm(selected))
        assertEquals(0, f.peer.writes.size)
        assertTrue(f.repo.entries(f.scope).isEmpty())
        assertArrayEquals(changed, f.file.readBytes())
        f.file.writeBytes(f.bytes)
        assertEquals(OriginalImportRepository.Action.Added, f.repo.confirm(f.choose()))
        assertArrayEquals(f.bytes, f.file.readBytes())
    }

    @Test fun scopeRetirementDuringSendLeavesReadOnlyRecoveryAndNoProjection() {
        val f = fixture()
        val choice = f.choose()
        f.peer.afterSend = { signIn(f.session, "B"); signIn(f.session, "A") }
        assertEquals(OriginalImportRepository.Action.Retired, f.repo.confirm(choice))
        val current = f.session.capture()!!
        assertEquals(0, f.added)
        assertEquals(OriginalImportPhase.Unconfirmed, f.repo.entries(current).single().phase)
        assertEquals(OriginalImportRepository.Action.Added, f.repo.check(current, choice.intent.operation) { true })
        assertEquals(1, f.peer.writes.size)
    }

    @Test fun dismissingBeforeDispatchSendsNothingButAnEnteredUploadKeepsItsBody() {
        val f = fixture()
        var mounted = true
        fun select() = requireNotNull(f.repo.choose(f.scope, f.selected.owner, f.display) { mounted })
        val retired = select()
        mounted = false
        assertEquals(OriginalImportRepository.Action.Unavailable, f.repo.confirm(retired))
        assertTrue(f.repo.entries(f.scope).isEmpty())
        assertEquals(0, f.peer.writes.size)
        mounted = true
        f.peer.beforeBody = { mounted = false }
        assertEquals(OriginalImportRepository.Action.Added, f.repo.confirm(select()))
        assertArrayEquals(f.bytes, f.peer.writes.single().second)
    }

    @Test fun rejectedJournalPreservesUnknownBytesAndBlocksDispatch() {
        val f = fixture()
        val text = "{\"version\":99,\"rows\":[]}"
        f.journal.writeText(text)
        f.reconstruct()
        assertTrue(f.repo.state.value.rejected)
        assertNull(f.repo.choose(f.scope, f.selected.owner, f.display) { true })
        assertEquals(text, f.journal.readText())
        assertTrue(f.peer.writes.isEmpty())
    }

    @Test fun exactOriginalIntentRoundTripsSeparatelyFromManagedDownloadIntent() {
        val id = UUID.randomUUID().toString()
        val items = listOf(SavedOccurrence("original", 1, "one", "", false, true, originalOperation = id),
            SavedOccurrence("download", 1, "one", "", false, true))
        val saved = QueueSnapshot("endpoint", "A", items, 0, 21)
        assertEquals(saved, QueueSnapshot.decode(saved.encode(), "endpoint", "A"))
        assertNull(QueueSnapshot.decode(saved.encode(), "endpoint", "B"))
        assertNull(QueueSnapshot.decode(saved.encode().replace(id, "1234"), "endpoint", "A"))
    }

    @Test fun offlineRouteReadsExactOriginalWithoutDescriptorOrDownloadFallback() {
        val qa = System.getenv("SOUNDQ_ORIGINAL_IMPORT_QA")?.let(::File)
        val f = Fixture(temp.newFolder(), qa?.resolve("original.mp3")?.readBytes())
        val choice = f.choose()
        assertEquals(0, f.peer.writes.size) // choosing or inspecting does not send
        assertEquals(OriginalImportRepository.Action.Added, f.repo.confirm(choice))
        var alternate = 0
        var originalOpens = 0
        fun play(operation: String?, scope: ServerAccount = choice.intent.destination, downloadOnly: Boolean = true): ByteArray =
            originalPlayback(scope, f.peer.track, operation, downloadOnly,
                { if (operation == null) f.repo.admitOnlinePlayback(f.scope, f.peer.track)
                    else f.repo.admitExplicitOriginal(f.scope, f.peer.track, operation) }, { f.available }, { binding ->
                originalOpens++
                FileRead(f.file) { f.available }.use { opened ->
                    val out = ByteArrayOutputStream()
                    verifyBytes(opened, binding.intent.original.revision, { f.available }, out)
                    out.toByteArray()
                }
            }, { alternate++; byteArrayOf(77) })
        val id = choice.intent.operation.toString()
        assertEquals(1, f.peer.membershipReads)
        assertArrayEquals(f.bytes, play(id))
        assertEquals("explicit offline original never reads membership over the wire", 1, f.peer.membershipReads)
        assertArrayEquals(f.bytes, play(null, downloadOnly = false))
        assertEquals("ordinary online borrowing reads exact membership", 2, f.peer.membershipReads)
        assertEquals(2, originalOpens); assertEquals(0, alternate)
        f.available = false
        assertTrue(runCatching { play(id) }.exceptionOrNull() is SafeFailure)
        assertTrue(runCatching { play(id, ServerAccount(choice.intent.destination.endpoint, "B")) }.exceptionOrNull() is SafeFailure)
        assertEquals(2, originalOpens); assertEquals(0, alternate)
        f.available = true
        if (qa != null) {
            assertEquals(ContentRevision("bf83725946603791eace9c56d16c97dfedd79f28f64145171d7595180fc5e20b", 97157), choice.intent.original.revision)
            for (variant in listOf("different-same-length.mp3", "retagged.mp3", "reencoded.mp3")) {
                f.file.writeBytes(qa.resolve(variant).readBytes())
                assertTrue(variant, runCatching { play(id) }.exceptionOrNull() is IOException)
                assertEquals(0, alternate)
            }
            // Content proof is about bytes. A renamed second catalog identity remains unbound
            // (grant/replacement regression above), even though its file bytes verify here.
            assertArrayEquals(f.bytes, qa.resolve("renamed-copy.mp3").readBytes())
        }
        f.file.writeBytes(f.bytes)
        assertArrayEquals(f.bytes, play(id))
        assertArrayEquals(byteArrayOf(77), play(null)) // explicit managed download keeps its own resolver
        assertEquals(2, f.peer.membershipReads)
        assertEquals(1, alternate)
        assertEquals(1, f.peer.writes.size)
        f.reconstruct()
        assertTrue(runCatching { play(id) }.exceptionOrNull() is SafeFailure)
        assertEquals(f.selected, f.rows(emptyList(), deviceOnly = true).single().phone)
        assertEquals(1, alternate)
    }

    @Test fun observedPermissionRevokeAndRegrantDoesNotReviveConsentForEqualRow() {
        val f = fixture()
        val stale = f.choose()
        val original = f.selected
        f.available = false
        assertNull(f.repo.choose(f.scope, original.owner, f.display) { true }) // consume the access observation
        f.available = true
        assertEquals(original.owner, stale.intent.original)
        assertEquals(OriginalImportRepository.Action.Unavailable, f.repo.confirm(stale))
        assertTrue(f.repo.entries(f.scope).isEmpty()); assertTrue(f.peer.writes.isEmpty())
        val fresh = f.choose()
        assertNotEquals(stale.intent.operation, fresh.intent.operation)
        assertEquals(OriginalImportRepository.Action.Added, f.repo.confirm(fresh))
        assertEquals(listOf(fresh.intent), f.peer.writes.map { it.first })
    }

    private fun fixture() = Fixture(temp.newFolder())
    private class Peer : OriginalImportTransport {
        val track = TrackId(17)
        val writes = mutableListOf<Pair<OriginalImportIntent, ByteArray>>()
        val checks = mutableListOf<UUID>()
        var membershipReads = 0
        var dropResponse = false
        var beforeBody: () -> Unit = {}
        var afterSend: () -> Unit = {}
        var receipt: (OriginalImportReceipt) -> OriginalImportReceipt = { it }
        var readback: (OriginalMembership) -> OriginalMembership = { it }
        override fun upload(scope: AccountScope, intent: OriginalImportIntent, body: VerifiedOriginalBody, current: () -> Boolean): OriginalImportReceipt {
            check(current())
            beforeBody()
            val stream = ByteArrayOutputStream(); body.writeTo(stream); writes.add(intent to stream.toByteArray()); afterSend()
            if (dropResponse) throw IOException("synthetic typed response loss")
            return statusOf(intent)
        }
        override fun status(scope: AccountScope, intent: OriginalImportIntent, admit: () -> Boolean): OriginalImportReceipt {
            check(admit()); checks.add(intent.operation); return statusOf(intent)
        }
        private fun statusOf(intent: OriginalImportIntent) = receipt(OriginalImportReceipt(intent.destination, intent.operation,
            OriginalReceiptStatus.Committed(CommittedOriginal(track, intent.original.revision))))
        override fun membership(scope: AccountScope, track: TrackId): OriginalMembershipResult {
            membershipReads++
            val intent = writes.last().first
            return OriginalMembershipResult.Present(readback(OriginalMembership(intent.destination, CommittedOriginal(track, intent.original.revision), intent.display, 55)))
        }
    }
    private class Fixture(dir: File, supplied: ByteArray? = null) {
        val journal = File(dir, "journal.json")
        val bytes = supplied ?: ByteArray(142_000) { (it * 13).toByte() }
        val file = File(dir, "local-original.wav").apply { writeBytes(bytes) }
        val display = ImportDisplay("Accepted title", "Accepted artist", "Accepted album")
        val selected = DeviceAudio(DeviceFileId(UUID.randomUUID()), ProviderObjectId("media", "selected"), revision(bytes), 1, OriginalMetadata("scan.wav", "Scanned title"), 55,
            listOf(LocatorAccess(ScanGrantId(UUID.randomUUID()), ProviderLocator("media", "content://secret/path"), AccessState.AVAILABLE)))
        val session = session()
        var scope = signIn(session, "A")
        val peer = Peer()
        val server get() = Track(peer.track, display.title, display.artist, display.album, 55)
        var added = 0
        var available = true
        private val permission = OriginalAccessEpoch()
        var repo = newRepository(session)
        fun reconstruct() { repo = newRepository(session); scope = session.capture()!! }
        fun choose(display: ImportDisplay = this.display) = requireNotNull(repo.choose(scope, selected.owner, display) { true })
        fun newRepository(session: AccountSession) = OriginalImportRepository(session, OriginalImportJournal(journal), { owner, current ->
            if (available && owner == selected.owner) FileRead(file, current) else null
        }, { available && it == selected.owner },
            sourceStamp = { owner -> permission.observe { available }?.takeIf { owner == selected.owner }?.let { OriginalSourceStamp(1, it) } },
            onAdded = { _, _ -> added++ }).also { it.installTransport(peer); it.load() }
        fun rows(server: List<Track>, downloads: List<Track> = emptyList(), source: LibrarySource = LibrarySource.All, selected: DeviceAudio = this.selected, deviceOnly: Boolean = false) =
            unifiedLibraryRows(session.endpoint.identity, scope.accountId, server, downloads, DeviceListeningSnapshot(0, listOf(selected), emptyList(), emptyList()),
                LibraryQuery(), source, false, repo.associations(scope), deviceOnly)
    }
    private class FileRead(file: File, private val current: () -> Boolean) : ImportOriginalRead {
        private val fd = RandomAccessFile(file, "r")
        override val length get() = fd.length()
        override fun checkCurrent() { check(current()) }
        override fun readAt(position: Long, bytes: ByteArray, count: Int): Int { fd.seek(position); return fd.read(bytes, 0, count) }
        override fun close() = fd.close()
    }
    private companion object {
        fun revision(bytes: ByteArray) = ContentRevision(MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }, bytes.size.toLong())
        fun signIn(session: AccountSession, account: String): AccountScope {
            check(session.accept(session.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", account)))
            return session.capture()!!
        }
        fun session(url: String = "https://fixture.invalid/api/v1") = AccountSession(ApiEndpoint.parse(url), object : SessionStore {
            override fun load(endpoint: ApiEndpoint): SecretTokens? = null
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {}
            override fun clear() {}
        })
    }
}
