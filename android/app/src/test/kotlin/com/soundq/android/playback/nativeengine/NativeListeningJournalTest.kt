package com.soundq.android.playback.nativeengine

import com.soundq.android.data.deviceaudio.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.UUID

class NativeListeningJournalTest {
    @Test fun ineligiblePollNeverReadsCheckpointStorageButEligiblePollStillFencesForeignBytes() {
        for(duration in listOf(600000L,601000L)) {
            val root=Files.createTempDirectory("journal-short-io-").toFile();val path=java.io.File(root,"journal.json")
            try {DeviceListeningStore(path).use {store->
                val access=store.unlock();val grant=ScanGrant(ScanGrantId(UUID.randomUUID()),GrantKind.FILE,"Source",ProviderLocator("fixture","one"),true)
                store.putGrant(access,grant);store.publishScan(store.beginScan(access,grant.id)!!,listOf(DiscoveredAudio(ProviderObjectId("fixture","one"),grant.locator,ContentRevision("a".repeat(64),32),OriginalMetadata("source.wav"),duration)))
                val row=store.snapshot(access)!!.files.single();val source=store.captureSource(access,row.id)!!
                val journal=NativeListeningBinding(store,source,UUID.randomUUID(),51,0,0,duration){true}
                journal.observe(deck(0,true),10);journal.observe(deck(100,true),11)
                path.appendText("foreign")
                journal.observe(deck(6000,true),12)
                assertEquals(if(duration>600000)LoadState.REJECTED else LoadState.READY,store.loadState)
            }}finally{root.deleteRecursively()}
        }
    }
    @Test fun acknowledgedAdvanceCheckpointSeekFenceAndConsumedEnd() {
        val root=Files.createTempDirectory("service-journal-").toFile()
        try {DeviceListeningStore(java.io.File(root,"journal.json")).use {store->
            val access=store.unlock();val grant=ScanGrant(ScanGrantId(UUID.randomUUID()),GrantKind.FILE,"Recording",ProviderLocator("fixture","fixture:one"),true)
            store.putGrant(access,grant);val scan=store.beginScan(access,grant.id)!!
            store.publishScan(scan,listOf(DiscoveredAudio(ProviderObjectId("fixture","one"),grant.locator,ContentRevision("a".repeat(64),800),OriginalMetadata("one.wav","Original title"),601000)))
            val row=store.snapshot(access)!!.files.single();val source=store.captureSource(access,row.id)!!
            val journal=NativeListeningBinding(store,source,UUID.randomUUID(),51,0,0,601000) {true}
            journal.observe(deck(0,true),1000)
            assertNull(store.snapshot(access)!!.history.singleOrNull()?.playedAtEpochMs)
            journal.observe(deck(100,true),1001)
            journal.observe(deck(30000,false),1002)
            assertEquals(1001L,store.snapshot(access)!!.history.single().playedAtEpochMs)
            assertEquals(30000L,store.bookmark(source)!!.positionMs)
            journal.fenceSeek()
            journal.observe(deck(601000,false,end=1),1003)
            assertEquals(30000L,store.bookmark(source)!!.positionMs)
            journal.beginSeek(2,0)
            journal.acknowledgeSeek(2,600900)
            journal.observe(deck(600950,true,revision=2),1004)
            journal.observe(deck(601000,false,revision=2,end=1),1005)
            assertNull(store.bookmark(source))
            journal.observe(deck(590000,false,revision=2),1006)
            assertNull(store.bookmark(source))
        }} finally {root.deleteRecursively()}
    }
    @Test fun tenMinuteBoundaryGenericEofAndRetiredCallbacksCannotClearOrCreateBookmarks() {
        for(duration in listOf(600000L,601000L)) {
            val root=Files.createTempDirectory("journal-edge-").toFile()
            try {DeviceListeningStore(java.io.File(root,"journal.json")).use {store->
                val access=store.unlock();val grant=ScanGrant(ScanGrantId(UUID.randomUUID()),GrantKind.FILE,"Source",ProviderLocator("fixture","one"),true)
                store.putGrant(access,grant);store.publishScan(store.beginScan(access,grant.id)!!,listOf(DiscoveredAudio(ProviderObjectId("fixture","one"),grant.locator,ContentRevision("b".repeat(64),32),OriginalMetadata("source.wav"),duration)))
                val row=store.snapshot(access)!!.files.single();val source=store.captureSource(access,row.id)!!
                val journal=NativeListeningBinding(store,source,UUID.randomUUID(),51,1,0,duration){true}
                journal.observe(deck(0,true),10);journal.observe(deck(100,true),11)
                journal.observe(deck(duration,false).copy(naturalEnd=null,eofCount=9),12)
                assertEquals(11L,store.snapshot(access)!!.history.single().playedAtEpochMs)
                if(duration==600000L)assertNull(store.bookmark(source))else assertEquals(duration,store.bookmark(source)!!.positionMs)
                val held=journal.stamp();journal.fenceSeek();journal.beginSeek(2,0);journal.acknowledgeSeek(2,1000)
                journal.observe(deck(duration,false,revision=2,end=1),13,held)
                if(duration>600000)assertEquals(1000L,store.bookmark(source)!!.positionMs)
                journal.fenceRetirement();journal.observe(deck(duration,false,revision=2,end=2),14)
                if(duration>600000)assertEquals(1000L,store.bookmark(source)!!.positionMs)
            }}finally{root.deleteRecursively()}
        }
    }
    private fun deck(p:Long,playing:Boolean,revision:Long=1,end:Long=0)=NativeCallbackDeck(51,51,p,601000,48000,28848000,true,false,playing,end,0,rate=1.0,traversalRevision=revision,naturalEnd=if(end==0L)null else NativeNaturalEndReceipt(end,51,51,revision))
}
