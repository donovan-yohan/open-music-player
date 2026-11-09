package com.soundq.android.data.deviceaudio

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class DeviceListeningStoreTest {
    @Test fun realisticTwentyThousandRowIndexCommitsAndReopens() {
        val path=target()
        var ids=emptyList<DeviceFileId>()
        DeviceListeningStore(path).use {store->
            val access=store.unlock();val g=grant()
            assertEquals(Mutation.APPLIED,store.putGrant(access,g))
            val rows=(1..DomainFile.MAX_RECORDS).map {i->
                val uri="content://media/external/audio/media/$i"
                DiscoveredAudio(ProviderObjectId("android-content","media::$uri::$i"),ProviderLocator("media",uri),ContentRevision("a".repeat(64),12345678),OriginalMetadata("Recording-$i-long-original-name.flac","Original recording $i","Original artist","Original album",uri),601000)
            }
            assertEquals(Mutation.APPLIED,store.publishScan(store.beginScan(access,g.id)!!,rows))
            ids=store.snapshot(access)!!.files.map {it.id}
            assertEquals(20000,ids.size)
        }
        assertTrue(path.length()>8L*1024*1024)
        DeviceListeningStore(path).use {store->assertEquals(ids,store.snapshot(store.unlock())!!.files.map {it.id})}
    }
    private fun target(): File {
        val base = System.getProperty("device.domain.fixtures") ?: System.getProperty("java.io.tmpdir")
        return File(Files.createTempDirectory(File(requireNotNull(base)).toPath(), "device-domain-case-").toFile(), "domain.json")
    }
    private fun revision(c: Char = 'a') = ContentRevision(c.toString().repeat(64), 123)
    private fun grant(id: ScanGrantId = ScanGrantId(UUID.randomUUID())) = ScanGrant(id, GrantKind.FOLDER, "Selected folder", ProviderLocator("provider", "folder"), true)
    private fun audio(id: String = "one", rev: ContentRevision = revision()) = DiscoveredAudio(ProviderObjectId("provider", id), ProviderLocator("provider", id), rev, OriginalMetadata("same.mp3", "Original", "Artist", "Album", "private-art-key"), 601000)

    private fun installed(store: DeviceListeningStore, rows: List<DiscoveredAudio> = listOf(audio())): Pair<AccessCapture, List<DeviceAudio>> {
        val access = store.unlock()
        val g = grant()
        assertEquals(Mutation.APPLIED, store.putGrant(access, g))
        assertEquals(Mutation.APPLIED, store.publishScan(store.beginScan(access, g.id)!!, rows))
        return access to store.snapshot(access)!!.files
    }
    private fun traversal(store: DeviceListeningStore, access: AccessCapture, file: DeviceAudio, duration: Long = 601000): TraversalCapture =
        store.beginTraversal(store.captureSource(access, file.id)!!, UUID.randomUUID(), 7, 0, 10, duration)!!
    private fun played(store: DeviceListeningStore, t: TraversalCapture, seq: Long = 1, time: Long = 1234) =
        store.played(SuccessfulPlaybackReceipt(t, seq, time))
    private fun checkpoint(store: DeviceListeningStore, t: TraversalCapture, seq: Long = 2, position: Long = 42000) =
        store.checkpoint(SourcePositionCheckpoint(t, seq, position))

    private fun end(t: TraversalCapture, seq: Long = 3, count: Long = 11) = QualifiedNaturalEnd(t, seq, t.occurrence, t.sourceGeneration, t.seekIdentity, count)

    @Test fun naturalCompletionTombstoneDefeatsLateCheckpointAfterReopen() {
        val path = target()
        var id: DeviceFileId? = null
        DeviceListeningStore(path).use { store ->
            val (access, files) = installed(store); id = files.single().id
            val t = traversal(store, access, files.single())
            assertEquals(Mutation.APPLIED, played(store, t))
            assertEquals(Mutation.APPLIED, checkpoint(store, t))
            assertEquals(Mutation.APPLIED, store.complete(end(t)))
            assertEquals(Mutation.REFUSED, checkpoint(store, t, 99, 123))
            assertNull(store.bookmark(t.source))
            assertEquals(1234L, store.snapshot(access)!!.history.single().playedAtEpochMs)
        }
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            assertNull(store.bookmark(store.captureSource(access, id!!)!!))
        }
    }
    @Test fun seekEndpointPauseAndCancelledPreparationCannotInventCompletionOrZero() {
        DeviceListeningStore(target()).use { store ->
            val (access, files) = installed(store)
            val t = traversal(store, access, files.single())
            played(store, t); checkpoint(store, t)
            val seeking = store.beginSeek(t, 1, 10)!!
            assertEquals(Mutation.APPLIED, checkpoint(store, seeking, 1, 601000))
            assertEquals(Mutation.REFUSED, store.complete(end(t, 99)))
            assertEquals(Mutation.REFUSED, store.complete(end(seeking, 2, 10)))
            assertEquals(601000L, store.bookmark(seeking.source)!!.positionMs)
            assertEquals(Mutation.APPLIED, store.retireTraversal(seeking))
            assertEquals(Mutation.REFUSED, store.complete(end(seeking, 99)))
            val preparing = traversal(store, access, files.single())
            assertEquals(Mutation.REFUSED, checkpoint(store, preparing, 1, 0))
            store.retireTraversal(preparing)
            assertEquals(601000L, store.bookmark(preparing.source)!!.positionMs)
            val playedAgain = traversal(store, access, files.single())
            played(store, playedAgain)
            assertEquals(Mutation.APPLIED, checkpoint(store, playedAgain, 2, 0))
            assertEquals(0L, store.bookmark(playedAgain.source)!!.positionMs)
        }
    }
    @Test fun successorTraversalAndContentReplacementRefuseOldCompletionAndAdmission() {
        DeviceListeningStore(target()).use { store ->
            val (access, files) = installed(store)
            val first = traversal(store, access, files.single())
            played(store, first); checkpoint(store, first)
            val heldSource = store.captureSource(access, files.single().id)!!
            val successor = traversal(store, access, files.single())
            played(store, successor); checkpoint(store, successor, 2, 70000)
            assertEquals(Mutation.REFUSED, store.complete(end(first, 99)))
            assertNull(store.beginTraversal(heldSource, UUID.randomUUID(), 7, 0, 10, 601000))
            val g = store.snapshot(access)!!.grants.single()
            store.publishScan(store.beginScan(access, g.id)!!, listOf(audio(rev = revision('b'))))
            val changed = store.snapshot(access)!!.files.single()
            assertEquals(files.single().id, changed.id)
            assertTrue(changed.incarnation > files.single().incarnation)
            assertEquals(Mutation.REFUSED, store.complete(end(successor, 99)))
            assertEquals(Mutation.REFUSED, checkpoint(store, successor, 100, 500))
            assertNull(store.bookmark(store.captureSource(access, changed.id)!!))
            store.publishScan(store.beginScan(access, g.id)!!, listOf(audio())) // revision ABA
            assertNull(store.bookmark(store.captureSource(access, changed.id)!!))
        }
    }

    @Test fun serverRecencyIsAccountQualifiedAndSortUsesKoiTiesNotPlaySequence() {
        val path = target()
        val a = ServerAccount("https://example.invalid", "account-a")
        val b = ServerAccount("https://example.invalid", "account-b")
        val ka = HistoryKey.Server(a, ServerAudioId(1))
        val kb = HistoryKey.Server(b, ServerAudioId(1))
        var device: HistoryKey? = null
        DeviceListeningStore(path).use { store ->
            val (_, files) = installed(store); device = files.single().owner.key
            val scope = store.unlock(a)
            val local = traversal(store, scope, files.single())
            assertEquals(Mutation.APPLIED, played(store, local, time = 5000))
            val server = store.captureServerHistory(scope, ka)!!
            assertEquals(Mutation.APPLIED, store.playedServer(SuccessfulServerPlaybackReceipt(server, 5000)))
            assertEquals(Mutation.REFUSED, store.playedServer(SuccessfulServerPlaybackReceipt(server, 6000)))
            val never = HistoryKey.Server(a, ServerAudioId(2))
            val items = listOf(RecentItem(never, "A"), RecentItem(ka, "zebra"), RecentItem(device, "ALPHA"))
            assertEquals(listOf(device, ka, never), store.recent(scope, items)!!.map { it.key })
            // Equal timestamps ignore admission order. Case-insensitive equal titles use source identity.
            val ties = listOf(RecentItem(ka, "alpha"), RecentItem(device, "ALPHA"))
            assertEquals(listOf(device, ka), store.recent(scope, ties)!!.map { it.key })
            val stale = store.captureServerHistory(scope, ka)!!
            val scopeB = store.unlock(b)
            assertEquals(Mutation.REFUSED, store.playedServer(SuccessfulServerPlaybackReceipt(stale, 9000)))
            assertNull(store.captureServerHistory(scopeB, ka))
            val fresh = store.captureServerHistory(scopeB, kb)!!
            assertEquals(Mutation.APPLIED, store.playedServer(SuccessfulServerPlaybackReceipt(fresh, 9000)))
            assertEquals(setOf(device, kb), store.snapshot(scopeB)!!.history.map { it.key }.toSet())
            assertNull(store.recent(scopeB, items))
            val guest = store.unlock()
            assertEquals(listOf(device), store.snapshot(guest)!!.history.map { it.key })
        }
        DeviceListeningStore(path).use { store ->
            assertEquals(setOf(device, ka), store.snapshot(store.unlock(a))!!.history.map { it.key }.toSet())
            assertEquals(5000L, store.snapshot(store.unlock(a))!!.history.single { it.key == ka }.playedAtEpochMs)
        }
    }
    @Test fun validatedDownloadBookmarksCannotCrossAccountOrArtifactIncarnation() {
        DeviceListeningStore(target()).use { store ->
            val a = ServerAccount("endpoint", "a"); val b = ServerAccount("endpoint", "b")
            val ka = HistoryKey.Server(a, ServerAudioId(1)); val kb = HistoryKey.Server(b, ServerAudioId(1))
            val access = store.unlock(a)
            val source = store.bindServerContent(access, ka, revision(), 601000)!!
            val t = store.beginTraversal(source, UUID.randomUUID(), 1, 0, 0, 601000)!!
            played(store, t); checkpoint(store, t)
            assertNull(store.bindServerContent(access, kb, revision(), 601000))
            val other = store.unlock(b)
            val bSource = store.bindServerContent(other, kb, revision(), 601000)!!
            assertNull(store.bookmark(bSource))
            assertEquals(Mutation.REFUSED, checkpoint(store, t, 99, 1))
            val returnA = store.unlock(a)
            val replaced = store.bindServerContent(returnA, ka, revision('b'), 601000)!!
            assertNull(store.bookmark(replaced))
            assertEquals(Mutation.REFUSED, store.complete(end(t, 100, 1)))
            assertNull(store.bookmark(store.bindServerContent(returnA, ka, revision(), 601000)!!))
        }
    }
    @Test fun aliasIdentityDistinctSameBytesAndGrantRemovalKeepFilesAndProgress() {
        val path = target()
        val original = File(path.parentFile, "original.mp3").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        val originalBytes = original.readBytes()
        var retained: DeviceFileId? = null
        DeviceListeningStore(path).use { store ->
            val access = store.unlock(); val firstGrant = grant(); val secondGrant = grant()
            store.putGrant(access, firstGrant); store.putGrant(access, secondGrant)
            val first = audio().copy(locator = ProviderLocator("provider", original.toURI().toString()))
            store.publishScan(store.beginScan(access, firstGrant.id)!!, listOf(first, audio("distinct-object")))
            val before = store.snapshot(access)!!.files
            assertEquals(2, before.size); assertNotEquals(before[0].id, before[1].id)
            retained = before[0].id
            store.publishScan(store.beginScan(access, secondGrant.id)!!, listOf(first.copy(locator = ProviderLocator("provider", "proven-alias"))))
            assertEquals(2, store.snapshot(access)!!.files.size)
            val t = traversal(store, access, store.snapshot(access)!!.files.first())
            played(store, t); checkpoint(store, t)
            assertEquals(Mutation.APPLIED, store.removeGrant(access, firstGrant.id))
            assertTrue(store.snapshot(access)!!.files.first().available)
            assertEquals(Mutation.REFUSED, checkpoint(store, t, 99, 10))
            val valid = store.captureSource(access, retained)!!
            assertEquals(42000L, store.bookmark(valid)!!.positionMs)
            assertEquals(Mutation.APPLIED, store.removeGrant(access, secondGrant.id))
            assertFalse(store.snapshot(access)!!.files.first().available)
            assertNull(store.captureSource(access, retained))
            assertEquals(42000L, store.snapshot(access)!!.history.single().bookmark!!.positionMs)
            assertEquals(Mutation.APPLIED, store.putGrant(access, firstGrant))
            assertFalse(store.snapshot(access)!!.files.first().available) // regrant alone is not revalidation
            store.publishScan(store.beginScan(access, firstGrant.id)!!, listOf(first))
            assertNull(store.bookmark(valid)) // old access incarnation cannot revive
            assertEquals(42000L, store.bookmark(store.captureSource(access, retained)!!)!!.positionMs)
            assertArrayEquals(originalBytes, original.readBytes())
        }
        DeviceListeningStore(path).use { store ->
            assertEquals(42000L, store.bookmark(store.captureSource(store.unlock(), retained!!)!!)!!.positionMs)
        }
        assertArrayEquals(originalBytes, original.readBytes())
    }
    @Test fun transientGrantsAreUsableNowButCannotClaimAccessAfterReopen() {
        val path = target(); val g = grant().copy(persisted = false)
        DeviceListeningStore(path).use { store ->
            val access = store.unlock(); store.putGrant(access, g)
            store.publishScan(store.beginScan(access, g.id)!!, listOf(audio()))
            assertTrue(store.snapshot(access)!!.files.single().available)
        }
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            assertFalse(store.snapshot(access)!!.files.single().available)
            assertNull(store.beginScan(access, g.id))
            store.putGrant(access, g)
            assertNotNull(store.beginScan(access, g.id))
        }
    }

    @Test fun observedMissingAndReappearingSourceNeverRevivesOldTraversal() {
        DeviceListeningStore(target()).use { store ->
            val (access, files) = installed(store)
            val t = traversal(store, access, files.single()); played(store, t); checkpoint(store, t)
            val g = store.snapshot(access)!!.grants.single()
            store.publishScan(store.beginScan(access, g.id)!!, emptyList())
            assertFalse(store.snapshot(access)!!.files.single().available)
            assertEquals(Mutation.REFUSED, checkpoint(store, t, 10, 1))
            store.publishScan(store.beginScan(access, g.id)!!, listOf(audio()))
            assertEquals(Mutation.REFUSED, checkpoint(store, t, 11, 2))
            assertEquals(42000L, store.bookmark(store.captureSource(access, files.single().id)!!)!!.positionMs)
        }
    }
    @Test fun providerObjectReplacementAtSameLocatorDoesNotMergeOrDeleteOldRecord() {
        DeviceListeningStore(target()).use { store ->
            val (access, files) = installed(store)
            val t = traversal(store, access, files.single()); played(store, t); checkpoint(store, t)
            val g = store.snapshot(access)!!.grants.single()
            val replacement = audio().copy(objectId = ProviderObjectId("provider", "new-object"))
            assertEquals(Mutation.APPLIED, store.publishScan(store.beginScan(access, g.id)!!, listOf(replacement)))
            val after = store.snapshot(access)!!.files
            assertEquals(2, after.size)
            assertFalse(after.first().available); assertTrue(after.last().available)
            assertNotEquals(after.first().id, after.last().id)
            assertEquals(42000L, store.snapshot(access)!!.history.single().bookmark!!.positionMs)
            assertNull(store.bookmark(store.captureSource(access, after.last().id)!!))
        }
    }
    @Test fun canonicalCorruptFutureOversizeAndPartialBytesArePreservedWithoutWrites() {
        val validPath = target()
        DeviceListeningStore(validPath).use { installed(it) }
        val valid = validPath.readBytes()
        val text = valid.toString(Charsets.UTF_8)
        val invalidUtf8 = valid.copyOf().also { bytes ->
            val offset = text.indexOf("same.mp3")
            assertTrue(offset > 0); bytes[offset] = 0xff.toByte()
        }
        val samples = listOf(
            byteArrayOf(0, 1, 2),
            text.replace("\"version\":1", "\"version\":2").toByteArray(),
            text.replace("\"version\":1", "\"version\":2,\"version\":1").toByteArray(),
            text.replace("\"incarnation\":1", "\"incarnation\":0").toByteArray(),
            invalidUtf8, ByteArray(DomainFile.MAX_BYTES + 1) { 42 },
        )
        for (sample in samples) {
            val path = target(); path.writeBytes(sample)
            DeviceListeningStore(path).use { store ->
                val access = store.unlock()
                assertEquals(LoadState.REJECTED, store.loadState)
                assertNull(store.snapshot(access))
                assertEquals(Mutation.REFUSED, store.putGrant(access, grant()))
                assertNull(store.beginScan(access, grant().id))
                assertArrayEquals(sample, path.readBytes())
            }
            assertArrayEquals(sample, path.readBytes())
        }
        // Independent scope stays writable and the original valid bytes are not rewritten.
        DeviceListeningStore(target()).use { installed(it) }
        assertArrayEquals(valid, validPath.readBytes())
    }
    @Test fun externalReplacementPoisonsOrdinaryWritesAndRetainsExactForeignBytes() {
        val path = target()
        DeviceListeningStore(path).use { store ->
            val (access, files) = installed(store)
            val t = traversal(store, access, files.single()); played(store, t); checkpoint(store, t)
            val scan = store.beginScan(access, store.snapshot(access)!!.grants.single().id)!!
            val foreign = "{\"version\":999,\"retained\":\"do not overwrite\"}".toByteArray()
            path.writeBytes(foreign)
            assertEquals(Mutation.REFUSED, checkpoint(store, t, 9, 10))
            assertEquals(Mutation.REFUSED, store.complete(end(t, 10)))
            assertEquals(Mutation.REFUSED, store.publishScan(scan, listOf(audio())))
            assertEquals(Mutation.REFUSED, store.removeGrant(access, scan.grantId))
            assertEquals(Mutation.REFUSED, store.putGrant(access, grant()))
            assertNull(store.captureSource(access, files.single().id))
            assertNull(store.beginTraversal(t.source, UUID.randomUUID(), 8, 0, 0, 601000))
            assertNull(store.snapshot(access))
            assertArrayEquals(foreign, path.readBytes())
        }
    }
    @Test fun singleFilesystemOwnerAndFaultedAtomicPublicationRequireReopen() {
        val path = target()
        val g = grant()
        DeviceListeningStore(path).use { store ->
            store.putGrant(store.unlock(), g)
            assertThrows(Exception::class.java) { DeviceListeningStore(path) }
        }
        val before = path.readBytes()
        for (boundary in listOf("beforeReplace", "afterReplace")) {
            path.writeBytes(before)
            DeviceListeningStore(path) { if (it == boundary) throw java.io.IOException("injected-$boundary") }.use { store ->
                val access = store.unlock()
                assertThrows(java.io.IOException::class.java) { store.putGrant(access, g.copy(label = "new label")) }
                assertEquals(LoadState.REJECTED, store.loadState)
                assertNull(store.snapshot(access))
            }
            if (boundary == "beforeReplace") assertArrayEquals(before, path.readBytes())
            DeviceListeningStore(path).use { reopened ->
                assertEquals(LoadState.READY, reopened.loadState)
                assertEquals(if (boundary == "beforeReplace") g.label else "new label", reopened.snapshot(reopened.unlock())!!.grants.single().label)
            }
            assertTrue(path.parentFile.listFiles()!!.none { it.name.endsWith(".stage") })
        }
    }
    @Test fun scanLockAndNaturalEvidenceIdentityControlsRefuseHeldObsoleteWork() {
        DeviceListeningStore(target()).use { store ->
            val (access, files) = installed(store)
            val g = store.snapshot(access)!!.grants.single()
            val held = store.beginScan(access, g.id)!!; val latest = store.beginScan(access, g.id)!!
            assertEquals(Mutation.REFUSED, store.publishScan(held, listOf(audio("wrong"))))
            assertEquals(Mutation.UNCHANGED, store.publishScan(latest, listOf(audio())))
            val t = traversal(store, access, files.single()); played(store, t); checkpoint(store, t)
            assertEquals(Mutation.REFUSED, store.complete(end(t).copy(nativeOccurrence = UUID.randomUUID())))
            assertEquals(Mutation.REFUSED, store.complete(end(t).copy(nativeSourceGeneration = 99)))
            assertEquals(Mutation.REFUSED, store.complete(end(t).copy(nativeSeekIdentity = 99)))
            assertEquals(Mutation.REFUSED, store.complete(end(t, 2)))
            assertEquals(Mutation.REFUSED, checkpoint(store, t, 2, 1))
            assertEquals(Mutation.REFUSED, checkpoint(store, t, 3, 601001))
            store.lock()
            assertNull(store.snapshot(access)); assertEquals(Mutation.REFUSED, played(store, t, 10))
            val fresh = store.unlock()
            assertNull(store.snapshot(access))
            assertEquals(Mutation.REFUSED, checkpoint(store, t, 11, 0))
            val restored = store.captureSource(fresh, files.single().id)!!
            assertEquals(42000L, store.bookmark(restored)!!.positionMs)
        }
    }

    @Test fun aliasEnumerationOrderIsIdempotentAndUnreadableAliasDoesNotHideReadableRoute() {
        DeviceListeningStore(target()).use { store ->
            val access = store.unlock(); val g = grant(); store.putGrant(access, g)
            val a = audio().copy(locator = ProviderLocator("provider", "a"))
            val b = a.copy(locator = ProviderLocator("provider", "b"))
            assertEquals(Mutation.APPLIED, store.publishScan(store.beginScan(access, g.id)!!, listOf(a, b)))
            val before = store.snapshot(access)!!
            assertEquals(Mutation.UNCHANGED, store.publishScan(store.beginScan(access, g.id)!!, listOf(b, a)))
            assertEquals(before.revision, store.snapshot(access)!!.revision)
            assertEquals(Mutation.APPLIED, store.publishScan(store.beginScan(access, g.id)!!, listOf(a, b.copy(state = AccessState.UNREADABLE))))
            assertTrue(store.snapshot(access)!!.files.single().available)
            assertEquals(2, store.snapshot(access)!!.files.single().aliases.size)
        }
    }
    @Test fun revokeRegrantAndCancelledServerPreparationKeepHistoryWithoutRevivingCaptures() {
        val path = target()
        DeviceListeningStore(path).use { store ->
            val (access, files) = installed(store)
            val t = traversal(store, access, files.single()); played(store, t); checkpoint(store, t)
            val g = store.snapshot(access)!!.grants.single()
            val held = store.beginScan(access, g.id)!!
            store.putGrant(access, g.copy(state = AccessState.REVOKED))
            assertEquals(Mutation.REFUSED, store.publishScan(held, listOf(audio())))
            assertFalse(store.snapshot(access)!!.files.single().available)
            store.putGrant(access, g)
            store.publishScan(store.beginScan(access, g.id)!!, listOf(audio()))
            assertEquals(Mutation.REFUSED, store.complete(end(t, 99)))
            assertEquals(42000L, store.bookmark(store.captureSource(access, files.single().id)!!)!!.positionMs)
            val account = ServerAccount("a|b", "c")
            val key = HistoryKey.Server(account, ServerAudioId(1))
            val accountAccess = store.unlock(account)
            val cancelled = store.captureServerHistory(accountAccess, key)!!
            assertEquals(Mutation.APPLIED, store.retireServerHistory(cancelled))
            assertEquals(Mutation.REFUSED, store.playedServer(SuccessfulServerPlaybackReceipt(cancelled, 5000)))
            val old = store.captureServerHistory(accountAccess, key)!!
            val fresh = store.captureServerHistory(accountAccess, key)!!
            assertEquals(Mutation.REFUSED, store.playedServer(SuccessfulServerPlaybackReceipt(old, 6000)))
            assertEquals(Mutation.APPLIED, store.playedServer(SuccessfulServerPlaybackReceipt(fresh, 5000)))
            assertNotEquals(stableSourceIdentity(key), stableSourceIdentity(HistoryKey.Server(ServerAccount("a", "b|c"), ServerAudioId(1))))
        }
    }
    @Test fun heldWorkerCheckpointCannotResurrectCommittedCompletionOrSupersedingTraversal() {
        for (completeFirst in listOf(true, false)) {
            DeviceListeningStore(target()).use { store ->
                val (access, files) = installed(store)
                val t = traversal(store, access, files.single()); played(store, t)
                val waiting = java.util.concurrent.CountDownLatch(1)
                val release = java.util.concurrent.CountDownLatch(1)
                val result = java.util.concurrent.atomic.AtomicReference<Mutation>()
                val failure = java.util.concurrent.atomic.AtomicReference<Throwable>()
                val thread = Thread {
                    try { waiting.countDown(); check(release.await(5, java.util.concurrent.TimeUnit.SECONDS)); result.set(checkpoint(store, t, 2, 11111)) }
                    catch (e: Throwable) { failure.set(e) }
                }
                thread.start()
                try {
                    assertTrue(waiting.await(5, java.util.concurrent.TimeUnit.SECONDS))
                    if (completeFirst) assertEquals(Mutation.APPLIED, store.complete(end(t, 3)))
                    else {
                        val successor = traversal(store, access, files.single())
                        played(store, successor); checkpoint(store, successor, 2, 70000)
                    }
                } finally { release.countDown(); thread.join(5000) }
                assertFalse(thread.isAlive)
                failure.get()?.let { throw AssertionError(it) }
                assertEquals(Mutation.REFUSED, result.get())
                val saved = store.bookmark(store.captureSource(access, files.single().id)!!)
                if (completeFirst) assertNull(saved) else assertEquals(70000L, saved!!.positionMs)
            }
        }
    }

    @Test fun serviceObservedAccessFailureRetiresSourceButPreservesCatalogAndBookmark() {
        DeviceListeningStore(target()).use { store ->
            val (access, files) = installed(store)
            val t = traversal(store, access, files.single()); played(store, t); checkpoint(store, t)
            assertEquals(Mutation.APPLIED, store.reportUnavailable(t.source, audio().locator, AccessState.UNREADABLE))
            assertEquals(Mutation.REFUSED, store.complete(end(t, 99)))
            assertFalse(store.snapshot(access)!!.files.single().available)
            assertEquals(files.single().id, store.snapshot(access)!!.files.single().id)
            assertEquals(42000L, store.snapshot(access)!!.history.single().bookmark!!.positionMs)
            assertEquals(Mutation.REFUSED, store.reportUnavailable(t.source, audio().locator, AccessState.AVAILABLE))
        }
    }
    @Test fun removedTransientGrantKeepsRemovedStatusAcrossReopen() {
        val path = target(); val g = grant().copy(persisted = false)
        DeviceListeningStore(path).use { store ->
            val access = store.unlock(); store.putGrant(access, g); store.removeGrant(access, g.id)
        }
        DeviceListeningStore(path).use { store ->
            assertEquals(AccessState.REMOVED, store.snapshot(store.unlock())!!.grants.single().state)
        }
    }

    @Test fun decodedThresholdAndAcknowledgedPositionSurviveFilesystemReopen() {
        val path = target()
        var eligible: DeviceFileId? = null
        var short: DeviceFileId? = null
        DeviceListeningStore(path).use { store ->
            val (access, files) = installed(store, listOf(audio("long"), audio("short").copy(durationMs = 600000)))
            eligible = files[0].id; short = files[1].id
            val longRun = traversal(store, access, files[0])
            assertEquals(Mutation.REFUSED, checkpoint(store, longRun, 1, 0))
            assertEquals(Mutation.APPLIED, played(store, longRun))
            assertEquals(Mutation.APPLIED, checkpoint(store, longRun))
            val shortRun = traversal(store, access, files[1], 600000)
            assertEquals(Mutation.APPLIED, played(store, shortRun))
            assertEquals(Mutation.REFUSED, checkpoint(store, shortRun))
        }
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            assertEquals(42000L, store.bookmark(store.captureSource(access, eligible!!)!!)!!.positionMs)
            assertNull(store.bookmark(store.captureSource(access, short!!)!!))
            assertEquals(2, store.snapshot(access)!!.history.size)
        }
    }

    @Test fun repeatedScanPersistsOneIdentityAndOriginalMetadata() {
        val path = target()
        var id: DeviceFileId? = null
        DeviceListeningStore(path).use { store ->
            val access = store.unlock()
            val g = grant()
            assertEquals(Mutation.APPLIED, store.putGrant(access, g))
            assertEquals(Mutation.APPLIED, store.publishScan(store.beginScan(access, g.id)!!, listOf(audio())))
            id = store.snapshot(access)!!.files.single().id
            assertEquals(Mutation.UNCHANGED, store.publishScan(store.beginScan(access, g.id)!!, listOf(audio())))
            assertEquals(id, store.snapshot(access)!!.files.single().id)
        }
        DeviceListeningStore(path).use { store ->
            val restored = store.snapshot(store.unlock())!!
            assertEquals(id, restored.files.single().id)
            assertEquals(audio().metadata, restored.files.single().metadata)
            assertEquals(1, restored.grants.size)
        }
    }
}
