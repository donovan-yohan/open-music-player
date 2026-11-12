package com.soundq.android.playback.nativeengine

import com.soundq.android.data.deviceaudio.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.UUID

/** Both real store admissions and real ordinary-deck binding lifecycles. No fake journal. */
class NativeSameSourceListeningTest {
    private class Fixture(val server: Boolean) : AutoCloseable {
        val root = Files.createTempDirectory("same-source-listening-").toFile()
        val file = File(root, "journal.json")
        val store = DeviceListeningStore(file)
        val account = if (server) ServerAccount("fixture", "account") else null
        val access = store.unlock(account)
        val grant = ScanGrant(ScanGrantId(UUID.randomUUID()), GrantKind.INDEXED, "fixture", ProviderLocator("fixture", "one"), true)
        val revision = ContentRevision("a".repeat(64), 64)
        init {
            if (!server) {
                store.putGrant(access, grant)
                store.publishScan(store.beginScan(access, grant.id)!!, listOf("one", "two").map {
                    DiscoveredAudio(ProviderObjectId("fixture", it), ProviderLocator("fixture", it), revision, OriginalMetadata("$it.wav"), 601000)
                })
            }
        }
        fun source(second: Boolean = false): SourceCapture = if (server)
            store.bindServerContent(access, HistoryKey.Server(account!!, ServerAudioId(if (second) 2 else 1)), revision, 601000)!!
        else store.captureSource(access, store.snapshot(access)!!.files[if (second) 1 else 0].id)!!
        fun binding(source: SourceCapture, id: Long) = NativeListeningBinding(store, source, UUID.randomUUID(), id, if (id == 11L) 0 else 1, store.bookmark(source)?.positionMs ?: 0, 601000) { true }
        fun bookmark(key: HistoryKey) = store.snapshot(access)!!.history.singleOrNull { it.key == key }?.bookmark?.positionMs
        fun reopenBookmark(key: HistoryKey): Long? {store.close();return DeviceListeningStore(file).use {it.snapshot(it.unlock(account))!!.history.singleOrNull {h->h.key==key}?.bookmark?.positionMs}}
        override fun close() {store.close();root.deleteRecursively()}
    }
    private fun deck(id: Long, position: Long, playing: Boolean = true, end: Long = 0) = NativeCallbackDeck(id,id,position,601000,48000,28848000,true,false,playing,end,0,rate=1.0,traversalRevision=1,naturalEnd=if(end==0L)null else NativeNaturalEndReceipt(end,id,id,1))
    private fun advance(binding: NativeListeningBinding, id: Long, position: Long, at: Long = 2000) {binding.observe(deck(id,0),at-1);binding.observe(deck(id,position),at)}

    @Test fun phoneUnplayedPreloadCancelPreservesOutgoingCheckpointAndCompletion() = cancelledPreload(false)
    @Test fun serverUnplayedPreloadCancelPreservesOutgoingCheckpointAndCompletion() = cancelledPreload(true)
    private fun cancelledPreload(server: Boolean) {
        Fixture(server).use {f->
            val source=f.source();val outgoing=f.binding(source,11);advance(outgoing,11,42000)
            val incoming=f.binding(f.source(),12)
            incoming.observe(deck(12,42000,false),2100) // Ready/paused is not successful playback.
            incoming.fenceRetirement();incoming.finish(null)
            outgoing.observe(deck(11,70000),2200)
            assertEquals("preload cannot retire outgoing progress server=$server",70000L,f.bookmark(source.owner.key))
            outgoing.observe(deck(11,601000,false,1),2300)
            assertNull("genuine outgoing completion server=$server",f.bookmark(source.owner.key))
            outgoing.finish(deck(11,500000,false)) // Late final cursor cannot undo the tombstone.
            assertNull(f.reopenBookmark(source.owner.key))
        }
    }
    @Test fun phoneOutgoingCompletesBeforeUnplayedIncomingCancellation() = completionBeforeCancel(false)
    @Test fun serverOutgoingCompletesBeforeUnplayedIncomingCancellation() = completionBeforeCancel(true)
    private fun completionBeforeCancel(server: Boolean) {
        Fixture(server).use {f->
            val source=f.source();val outgoing=f.binding(source,11);advance(outgoing,11,42000)
            val incoming=f.binding(f.source(),12)
            outgoing.observe(deck(11,601000,false,1),2300)
            incoming.fenceRetirement();incoming.finish(null)
            assertNull(f.reopenBookmark(source.owner.key))
        }
    }
    @Test fun differentSourcePreloadCancelKeepsOutgoingCompletion() {
        for (server in listOf(false,true)) Fixture(server).use {f->
            val source=f.source();val outgoing=f.binding(source,11);advance(outgoing,11,42000)
            val incoming=f.binding(f.source(true),12);incoming.fenceRetirement();incoming.finish(null)
            outgoing.observe(deck(11,601000,false,1),2300)
            assertNull(f.reopenBookmark(source.owner.key))
        }
    }
    @Test fun newerActuallyPlayingOccurrenceWinsAgainstOutgoingEndAndLateCursor() {
        for (server in listOf(false,true)) Fixture(server).use {f->
            val source=f.source();val outgoing=f.binding(source,11);advance(outgoing,11,42000)
            val incoming=f.binding(f.source(),12);advance(incoming,12,80000,2200)
            outgoing.observe(deck(11,601000,false,1),2300);outgoing.finish(deck(11,500000,false))
            assertEquals(80000L,f.bookmark(source.owner.key))
            incoming.observe(deck(12,90000,false),2400);incoming.finish(null)
            outgoing.observe(deck(11,601000,false,2),2500)
            assertEquals(90000L,f.reopenBookmark(source.owner.key))
        }
    }
    @Test fun incomingCompletionDefeatsBothBindingsLateCheckpoints() {
        for (server in listOf(false,true)) Fixture(server).use {f->
            val source=f.source();val outgoing=f.binding(source,11);advance(outgoing,11,42000)
            val incoming=f.binding(f.source(),12);advance(incoming,12,80000,2200)
            incoming.observe(deck(12,601000,false,1),2300)
            outgoing.finish(deck(11,500000,false));incoming.finish(deck(12,590000,false))
            assertNull(f.reopenBookmark(source.owner.key))
        }
    }
    @Test fun phoneOptionalSourceCaptureAloneCannotRetireOutgoingCompletion() = captureWithoutBinding(false)
    @Test fun serverOptionalContentBindAloneCannotRetireOutgoingCompletion() = captureWithoutBinding(true)
    private fun captureWithoutBinding(server: Boolean) {
        Fixture(server).use {f->
            val source=f.source();val outgoing=f.binding(source,11);advance(outgoing,11,42000)
            f.source() // Cancellation during staging, before NativeListeningBinding even exists.
            outgoing.observe(deck(11,601000,false,1),2300)
            assertNull(f.reopenBookmark(source.owner.key))
        }
    }
    @Test fun preparationIsMemoryOnlyAndAdmissionsRemainOneShot() {
        for(server in listOf(false,true)) Fixture(server).use {f->
            val source=f.source();val outgoing=f.binding(source,11);advance(outgoing,11,42000)
            val before=f.file.readBytes();val incomingSource=f.source()
            val incoming=f.binding(incomingSource,12)
            assertArrayEquals("Optional preparation must not rewrite durable authority",before,f.file.readBytes())
            assertNull(f.store.beginTraversal(incomingSource,UUID.randomUUID(),13,1,0,601000))
            incoming.fenceSeek();assertTrue(incoming.beginSeek(2,0));incoming.acknowledgeSeek(2,0)
            assertArrayEquals(before,f.file.readBytes())
            incoming.fenceRetirement();incoming.finish(null)
            assertNull(f.store.beginTraversal(incomingSource,UUID.randomUUID(),13,1,0,601000))
            outgoing.observe(deck(11,601000,false,1),2300)
            assertNull(f.reopenBookmark(source.owner.key))
        }
    }
    @Test fun contentRevisionReplacementStillRefusesOldCompletion() {
        for (server in listOf(false,true)) Fixture(server).use {f->
            val source=f.source();val outgoing=f.binding(source,11);advance(outgoing,11,42000)
            if(server) f.store.bindServerContent(f.access,source.owner.key as HistoryKey.Server,ContentRevision("b".repeat(64),64),601000)
            else f.store.publishScan(f.store.beginScan(f.access,f.grant.id)!!,listOf(DiscoveredAudio(ProviderObjectId("fixture","one"),ProviderLocator("fixture","one"),ContentRevision("b".repeat(64),64),OriginalMetadata("one.wav"),601000)))
            outgoing.observe(deck(11,601000,false,1),2300)
            assertEquals(42000L,f.reopenBookmark(source.owner.key))
        }
    }
}
