package com.soundq.android.playback.mix

import com.soundq.android.data.mix.SavedMix
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.pow

/** Seekable bounded float WAV projection. ExoPlayer is the ONLY output and transport. */
internal class NativeMixStream(plan: MixRenderPlan): AutoCloseable {
    constructor(plan: SavedMix, paths: Map<Long, String>, stems: Map<String, PreparedMixStems> = emptyMap()): this(plan.renderPlan(paths, stems))
    val frames=Math.multiplyExact(plan.durationMs,48)
    val size=Math.addExact(44,Math.multiplyExact(frames,8))
    private var handle=0L
    private val scratch=ByteArray(2048*8)
    private val header:ByteArray
    init {
        require(size<=0xfffffff0L)
        val sources=plan.sources
        val events=mutableListOf<Long>();val eventGains=mutableListOf<Float>()
        fun frames(ms: Long)=Math.multiplyExact(ms,48)
        val clips=plan.clips.flatMapIndexed {i,c ->
            val indices=c.paths.map {sources.indexOf(it).toLong().also {p->require(p>=0)}}
            c.events.forEach { e ->
                events+=listOf(i.toLong(),frames(e.sourceMs),e.bus.toLong(),frames(e.rampMs))
                eventGains+=e.gain
            }
            listOf(i+1L,frames(c.startMs),frames(c.endMs),frames(c.sourceStartMs),frames(c.fadeInMs),frames(c.fadeOutMs),c.paths.size.toLong())+indices+List(5-indices.size){-1L}
        }.toLongArray()
        header=ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray());putInt((size-8).toInt());put("WAVEfmt ".toByteArray());putInt(16)
            putShort(3);putShort(2);putInt(48000);putInt(384000);putShort(8);putShort(32)
            put("data".toByteArray());putInt((size-44).toInt())
        }.array()
        handle=NativeMix.open(sources.toTypedArray(),clips,plan.clips.map {10.0.pow(it.gainDb/20).toFloat()}.toFloatArray(),events.toLongArray(),eventGains.toFloatArray())
        check(handle!=0L)
    }
    fun read(position:Long,buffer:ByteArray,offset:Int,length:Int):Int {
        check(handle!=0L);require(position in 0..size && offset>=0 && length>=0 && offset+length<=buffer.size)
        if(length==0)return 0
        if(position==size)return -1
        if(position<44) {val n=minOf(length,44-position.toInt());header.copyInto(buffer,offset,position.toInt(),position.toInt()+n);return n}
        val data=position-44;val skip=(data%8).toInt();val frames=minOf(2048L,(length+skip+7L)/8,(size-position+skip)/8).toInt()
        NativeMix.render(handle,data/8,frames,scratch)
        val count=minOf(length,frames*8-skip);scratch.copyInto(buffer,offset,skip,skip+count);return count
    }
    override fun close(){if(handle!=0L){NativeMix.close(handle);handle=0}}
}
