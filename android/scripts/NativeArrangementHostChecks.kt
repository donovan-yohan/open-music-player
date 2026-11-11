package com.soundq.android.playback.nativeengine

import androidx.media3.common.MediaItem
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.arrangementPlan
import java.io.File

/** Executed host check with real metadata/compiler and real owned encoded files. */
internal object NativeArrangementHostChecks {
    @JvmStatic fun main(args: Array<String>) {
        val root = File(args.single()).apply { mkdirs() }
        fun item(id: String) = MediaItem.Builder().setMediaId(id).setUri("soundq://track/7/$id").build()
        fun clip(id: String, start: Long = 0) = TimelineClip(id,7,"Fixture",10000,100,2100,start,QueueSegment.Context,fadeInMs=250,fadeOutMs=250)
        var ordinal = 0
        val source = NativeCallbackSource { _, current -> check(current()); File(root,"file-${++ordinal}").apply { writeBytes(ByteArray(16)) } }
        val d = TimelineDocument(1,listOf(clip("a"),clip("b",1000)))
        val prepared = NativeCallbackArrangement.prepare(d,21,listOf(item("a"),item("b")),source) { true }
        check(prepared.values.contentEquals(longArrayOf(0,100,2100,250,250,0,1000,100,2100,250,250,0)))
        check(prepared.files.size==2 && prepared.paths().size==2)
        check(prepared.files.all { it.exists() })
        prepared.close();check(prepared.files.none { it.exists() })
        val full=d.copy(clips=d.clips.map{it.copy(sourceOutMs=it.sourceDurationMs)})
        val fullCandidate=NativeCallbackArrangement.prepare(full,25,listOf(item("a"),item("b")),source){true}
        check(fullCandidate.document===full)
        check(fullCandidate.values.contentEquals(longArrayOf(0,100,10000,250,250,10000,1000,100,10000,250,250,10000)))
        fullCandidate.close()
        val long = TimelineDocument(2,(0 until 500).map {clip("occ-$it",it*2000L)})
        val longCandidate=NativeCallbackArrangement.prepare(long,22,long.clips.map {item(it.occurrence)},source) { true }
        check(longCandidate.paths().size==500 && longCandidate.values.size==3000);longCandidate.close()
        val before=root.listFiles()!!.toSet()
        check(runCatching { NativeCallbackArrangement.prepare(d,23,listOf(item("a"),item("b")),source,budget=20) { true } }.isFailure)
        check(root.listFiles()!!.toSet()==before)
        var live=true
        val retiring=NativeCallbackSource { _, _ -> File(root,"retired").apply {writeBytes(byteArrayOf(1));live=false} }
        check(runCatching {NativeCallbackArrangement.prepare(d,24,listOf(item("a"),item("b")),retiring) {live}}.isFailure)
        check(!File(root,"retired").exists())
        val rate=d.copy(clips=d.clips.map {it.copy(rates=RateAutomation(1.25),fadeInMs=0,fadeOutMs=0)})
        check(runCatching {rate.arrangementPlan()}.isFailure)
        val five=d.copy(clips=(0..4).map {clip("five-$it")})
        check(runCatching {five.arrangementPlan()}.isFailure)
        println("PASS actual Kotlin candidate: trims/fades, 500 occurrences, bounded encoded budget cleanup, revocation during source return, non-one rate and fifth overlap refusals")
    }
}
