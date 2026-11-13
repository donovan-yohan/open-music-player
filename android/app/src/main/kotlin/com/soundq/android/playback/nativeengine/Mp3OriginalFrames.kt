package com.soundq.android.playback.nativeengine

import java.nio.ByteBuffer
import java.util.TreeMap

/** Exact Layer III packet clock for gapless MP3. Android's Xing TOC seek reports
 * requested time after byte resync, not the selected frame's sample position.
 * Retain bounded exact header checkpoints for overlap/backward reads. A declared
 * Info CBR stream with an integral, unpadded frame size and matching frame/byte
 * counts additionally has an exact arithmetic packet index (not a Xing TOC).
 * Everything else scans from a proven checkpoint within the unchanged lease
 * budget; a cold unindexed VBR seek can still intentionally refuse. No PCM
 * prefix replay, private copy or second decoder/output owner. This object is
 * worker/lease-local: the reader checks the original version before every use.
 */
internal class Mp3OriginalFrames(private val length:Long,private val readAt:(Long,ByteArray,Int,Int)->Int,private val rate:Int,private val channels:Int) {
    private data class Frame(val bytes:Int,val samples:Int,val integralUnpadded:Boolean)
    private data class Checkpoint(val sample:Long,val offset:Long)
    private data class FixedIndex(val frame:Frame,val count:Long)
    // One earliest exact frame per 30-second bucket. At most 2881 entries for
    // the reader's 24-hour seek range; retain an absolute cap even beyond it.
    private val checkpoints=TreeMap<Long,Checkpoint>()
    private val checkpointSpan=rate*30L
    private var fixedIndex:FixedIndex?=null
    private val cache=ByteArray(65536)
    private var cacheAt=-1L
    private var cacheSize=0
    private var audioStart=0L
    private var at=0L
    var sampleFrame=0L;private set
    private var current:Frame?=null
    init {
        // ID3 size is sync-safe and excludes its ten-byte header.
        if(text(0,3)=="ID3") {
            val flags=byte(5)
            var size=0L
            for(n in 6..9) {val b=byte(n.toLong());require(b<128);size=(size shl 7)+b}
            audioStart=10+size+if(flags and 16!=0)10 else 0
        }
        val first=frame(audioStart)
        val version=(byte(audioStart+1) shr 3) and 3
        val crc=if(byte(audioStart+1) and 1==0)2 else 0
        val side=if(version==3) {if(channels==1)17 else 32} else {if(channels==1)9 else 17}
        val tagAt=audioStart+4+crc+side
        val tag=text(tagAt,4)
        require(tag=="Xing" || tag=="Info") {"Gapless MP3 needs a qualified first metadata frame"}
        val metadataStart=audioStart
        audioStart+=first.bytes
        // Info declares constant bitrate, but neither its quantized TOC nor the
        // usual rational CBR padding cadence proves exact frame ordinals. Only
        // the integral/unpadded case with redundant counts/range is arithmetic.
        // Counts exclude the metadata frame; byte size includes it, not ID3.
        if(tag=="Info" && tagAt+16<=audioStart && uint32(tagAt+4) and 3L==3L) {
            val count=uint32(tagAt+8)
            val streamBytes=uint32(tagAt+12)
            val audio=frame(audioStart)
            if(count>0 && audio.integralUnpadded &&
                streamBytes==first.bytes+count*audio.bytes &&
                ended(metadataStart+streamBytes)) {
                require(frame(audioStart+(count-1)*audio.bytes)==audio) {"Inconsistent Info CBR endpoint"}
                fixedIndex=FixedIndex(audio,count)
            }
        }
        checkpoints[0]=Checkpoint(0,audioStart)
        seek(0)
    }
    private fun byte(position:Long):Int {
        require(position in 0 until length) {"Truncated MP3 original"}
        if(position<cacheAt || position>=cacheAt+cacheSize) {
            cacheAt=position
            cacheSize=readAt(position,cache,0,minOf(cache.size.toLong(),length-position).toInt())
            check(cacheSize>0)
        }
        return cache[(position-cacheAt).toInt()].toInt() and 255
    }
    private fun uint32(position:Long):Long {
        var value=0L
        repeat(4) {value=(value shl 8) or byte(position+it).toLong()}
        return value
    }
    private fun text(position:Long,count:Int)=buildString {repeat(count){append(byte(position+it).toChar())}}
    private fun frame(position:Long):Frame {
        val h=(byte(position).toLong() shl 24) or (byte(position+1).toLong() shl 16) or (byte(position+2).toLong() shl 8) or byte(position+3).toLong()
        require(h and 0xffe00000L==0xffe00000L && (h shr 17) and 3==1L) {"Invalid Layer III original frame"}
        val version=((h shr 19) and 3).toInt();require(version!=1)
        val bitrateIndex=((h shr 12) and 15).toInt();require(bitrateIndex in 1..14)
        val rateIndex=((h shr 10) and 3).toInt();require(rateIndex<3)
        val base=intArrayOf(44100,48000,32000)[rateIndex]
        val actualRate=base/(if(version==3)1 else if(version==2)2 else 4)
        val actualChannels=if((h shr 6) and 3==3L)1 else 2
        require(actualRate==rate && actualChannels==channels) {"Changing MP3 format is unsupported"}
        val kbps=(if(version==3)intArrayOf(0,32,40,48,56,64,80,96,112,128,160,192,224,256,320)
            else intArrayOf(0,8,16,24,32,40,48,56,64,80,96,112,128,144,160))[bitrateIndex]
        val numerator=(if(version==3)144000 else 72000)*kbps
        val padding=((h shr 9) and 1).toInt()
        val size=numerator/rate+padding
        require(size>=4 && size<=length-position) {"Truncated MP3 frame"}
        val result=Frame(size,if(version==3)1152 else 576,numerator%rate==0 && padding==0)
        fixedIndex?.let {require(result==it.frame) {"Inconsistent Info CBR frame"}}
        return result
    }
    private fun ended(position:Long):Boolean {
        if(position==length)return true
        // ID3v1 is a fixed-size trailing tag, not decoded source samples.
        return length-position==128L && text(position,3)=="TAG"
    }
    private fun remember() {
        val bucket=sampleFrame/checkpointSpan
        val previous=checkpoints[bucket]
        if(previous!=null) {
            if(sampleFrame<previous.sample)checkpoints[bucket]=Checkpoint(sampleFrame,at)
        } else if(checkpoints.size<4096)checkpoints[bucket]=Checkpoint(sampleFrame,at)
    }
    fun seek(first:Long) {
        require(first>=0)
        current=null
        // Do not let a cached target bypass the positioned lease's current-source
        // validation. No cache/index is shared across reader/original lifetimes.
        cacheAt=-1;cacheSize=0
        fixedIndex?.let {index ->
            val ordinal=minOf(first/index.frame.samples,index.count)
            at=audioStart+ordinal*index.frame.bytes;sampleFrame=ordinal*index.frame.samples
            current=if(ended(at))null else frame(at)
            return
        }
        var entry=checkpoints.floorEntry(first/checkpointSpan)
        if(entry!=null && entry.value.sample>first)entry=checkpoints.lowerEntry(entry.key)
        val checkpoint=entry?.value ?: Checkpoint(0,audioStart)
        at=checkpoint.offset;sampleFrame=checkpoint.sample
        while(!ended(at)) {
            val f=frame(at)
            remember()
            if(sampleFrame+f.samples>first) {current=f;return}
            at+=f.bytes;sampleFrame+=f.samples
        }
    }
    fun read(destination:ByteBuffer):Int {
        val f=current ?: return -1
        require(destination.remaining()>=f.bytes)
        repeat(f.bytes) {destination.put(byte(at+it).toByte())}
        return f.bytes
    }
    fun advance() {
        val f=requireNotNull(current);at+=f.bytes;sampleFrame+=f.samples
        current=if(ended(at))null else frame(at).also {remember()}
    }
}
