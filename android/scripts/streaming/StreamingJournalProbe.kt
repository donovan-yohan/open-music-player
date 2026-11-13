package com.soundq.android.data.deviceaudio
import java.io.File
import java.util.UUID
fun main(args:Array<String>) {
    val store=DeviceListeningStore(File(args.single(),"streaming-domain.json"))
    store.use {
        val access=store.unlock()
        val grant=ScanGrant(ScanGrantId(UUID.randomUUID()),GrantKind.INDEXED,"Synthetic",ProviderLocator("android","indexed:test"),true)
        check(store.putGrant(access,grant)==Mutation.APPLIED)
        val row=DiscoveredAudio(ProviderObjectId("provider","original"),ProviderLocator("provider","content://original"),ContentRevision("a".repeat(64),123),OriginalMetadata("podcast.mp3","Podcast",null,null,"test"),12600000)
        check(store.publishScan(store.beginScan(access,grant.id)!!,listOf(row))==Mutation.APPLIED)
        val audio=store.snapshot(access)!!.files.single()
        val source=store.captureSource(access,audio.id)!!
        val t=store.beginStreamingTraversal(source,UUID.randomUUID(),1,1,0,true)!!
        check(store.played(SuccessfulPlaybackReceipt(t,1,100))==Mutation.APPLIED)
        check(store.checkpoint(SourcePositionCheckpoint(t,2,10800000))==Mutation.APPLIED)
        check(store.bookmark(source)!!.positionMs==10800000L)
        check(store.sealStreamingEnd(t,12600000)==Mutation.APPLIED)
        check(store.retireChangedOriginal(source)==Mutation.APPLIED)
        check(store.bookmark(source)==null)
        check(store.checkpoint(SourcePositionCheckpoint(t,99,123))==Mutation.REFUSED)
        check(store.complete(QualifiedNaturalEnd(t,100,t.occurrence,t.sourceGeneration,t.seekIdentity,1))==Mutation.REFUSED)
        val fresh=store.captureSource(access,audio.id)!!
        val short=store.beginStreamingTraversal(fresh,UUID.randomUUID(),2,1,0,false)!!
        check(store.played(SuccessfulPlaybackReceipt(short,1,101))==Mutation.APPLIED)
        check(store.checkpoint(SourcePositionCheckpoint(short,2,100))==Mutation.REFUSED)
        check(store.sealStreamingEnd(short,600000)==Mutation.APPLIED)
        check(store.checkpoint(SourcePositionCheckpoint(short,2,100))==Mutation.REFUSED)
        val longSource=store.captureSource(access,audio.id)!!
        val long=store.beginStreamingTraversal(longSource,UUID.randomUUID(),3,1,0,true)!!
        check(store.played(SuccessfulPlaybackReceipt(long,1,102))==Mutation.APPLIED)
        check(store.checkpoint(SourcePositionCheckpoint(long,2,100))==Mutation.APPLIED)
        check(store.sealStreamingEnd(long,601000)==Mutation.APPLIED)
        println("PASS unknown-end deep checkpoint, strict 600/601-second eligibility, same-traversal seal and permanent changed-source late progress/EOF refusal")
    }
}
