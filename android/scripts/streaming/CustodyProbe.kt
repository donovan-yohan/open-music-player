package com.soundq.android.playback.nativeengine
import java.io.File
import java.nio.ByteBuffer
fun main(args:Array<String>) {
    val root=File(args.single()).apply {mkdirs()}
    val original=File(root,"original.fixture").apply {writeText("original bytes")}
    val stage=File(root,"private.stage").apply {writeText("owned bytes")}
    var closes=0
    val peer=object:NativePcmReader {
        override fun open()=48000
        override fun read(first:Long,count:Int,destination:ByteBuffer)=error("No codec in lifetime test")
        override fun endFrames()=0L
        override fun revoke(){}
        override fun closeReader():Boolean {closes++;return true}
    }
    val lease=NativePlaybackSource.BorrowedOriginal(peer,10800000,12600000,versionCurrent={true})
    check(lease.release() && original.readText()=="original bytes" && closes==1)
    check(NativePlaybackSource.OwnedTemporary(stage).release() && !stage.exists())
    val file=File(root,"versions.properties")
    val versions=LiveOriginalVersions(file)
    check(versions.observe("provider:1","dev:1/inode:2/version:3")==LiveOriginalVersions.Observation.First)
    check(LiveOriginalVersions(file).observe("provider:1","dev:1/inode:2/version:3")==LiveOriginalVersions.Observation.Matching)
    check(versions.observe("provider:1","dev:1/inode:4/version:3")==LiveOriginalVersions.Observation.Changed)
    check(versions.observe("provider:1","dev:1/inode:2/version:3")==LiveOriginalVersions.Observation.Changed)
    check(original.readText()=="original bytes")
    println("PASS original release closes only; owned cleanup; durable live version and same-path ABA observation (not SHA equality)")
}
