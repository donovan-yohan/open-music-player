package com.soundq.android.playback.nativeengine

import com.soundq.android.data.deviceaudio.*
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class NativeStreamingListeningTest {
    private fun fixture(block:(DeviceListeningStore,AccessCapture,SourceCapture)->Unit) {
        val root=Files.createTempDirectory("streaming-journal-").toFile()
        try {DeviceListeningStore(File(root,"journal.json")).use {store->
            val access=store.unlock()
            val grant=ScanGrant(ScanGrantId(UUID.randomUUID()),GrantKind.INDEXED,"Synthetic",ProviderLocator("fixture","original"),true)
            store.putGrant(access,grant)
            store.publishScan(store.beginScan(access,grant.id)!!,listOf(DiscoveredAudio(ProviderObjectId("fixture","original"),grant.locator,ContentRevision("a".repeat(64),64),OriginalMetadata("podcast.mp3"),12600000)))
            val row=store.snapshot(access)!!.files.single()
            block(store,access,store.captureSource(access,row.id)!!)
        }} finally {root.deleteRecursively()}
    }
    private fun deck(position:Long,playing:Boolean=true,revision:Long=1,end:Long=0,duration:Long=0)=
        NativeCallbackDeck(51,51,position,duration,48000,duration*48,true,false,playing,end,0,rate=1.0,traversalRevision=revision,naturalEnd=if(end==0L)null else NativeNaturalEndReceipt(end,51,51,revision))
    @Test fun unknownEndKeepsEarlyLongFormCheckpointDeepResumeSeekAndSameTraversalCompletion()=fixture {store,access,source->
        val binding=NativeListeningBinding(store,source,UUID.randomUUID(),51,0,0,0,true){true}
        binding.observe(deck(0),1);binding.observe(deck(100),2)
        assertEquals(100L,store.bookmark(source)!!.positionMs)
        binding.fenceSeek();assertTrue(binding.beginSeek(2,0));binding.acknowledgeSeek(2,10800000)
        assertEquals(10800000L,store.bookmark(source)!!.positionMs)
        binding.observe(deck(10800000,revision=2),3)
        binding.observe(deck(10800100,revision=2),4)
        binding.observe(deck(12600000,false,2,1,12600000),5)
        assertNull(store.bookmark(source))
        assertEquals(2L,store.snapshot(access)!!.history.single().playedAtEpochMs)
        binding.finish(deck(12000000,false,2))
        assertNull(store.bookmark(source))
    }
    @Test fun estimateCannotQualifyShortSourceAndChangedOriginalCannotReceiveLateEofOrCursor()=fixture {store,access,source->
        val short=NativeListeningBinding(store,source,UUID.randomUUID(),51,0,0,0,false){true}
        short.observe(deck(0),1);short.observe(deck(100),2)
        assertNull(store.bookmark(source)) // catalog's 3.5h estimate is not eligibility
        short.fenceRetirement();short.finish(null)
        val id=(source.owner.key as HistoryKey.Device).id
        val fresh=store.captureSource(access,id)!!
        val long=NativeListeningBinding(store,fresh,UUID.randomUUID(),51,0,0,0,true){true}
        long.observe(deck(0),3);long.observe(deck(100),4)
        assertEquals(100L,store.bookmark(fresh)!!.positionMs)
        assertEquals(Mutation.APPLIED,store.retireChangedOriginal(fresh))
        long.observe(deck(12600000,false,1,1,12600000),5)
        long.finish(deck(800000,false))
        assertNull(store.bookmark(store.captureSource(access,id)!!))
        assertNull(store.snapshot(access)!!.history.single().bookmark)
    }
}
