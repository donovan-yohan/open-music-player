package com.soundq.android.playback.nativeengine

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

class Mp3OriginalFramesTest {
    private fun frame(version:Int=3,rateIndex:Int=2,bitrate:Int=3,mono:Boolean=true,padding:Int=0,tag:String?=null):ByteArray {
        val rate=intArrayOf(44100,48000,32000)[rateIndex]/if(version==3)1 else if(version==2)2 else 4
        val kbps=if(version==3)intArrayOf(0,32,40,48,56,64,80,96,112,128,160,192,224,256,320)[bitrate] else intArrayOf(0,8,16,24,32,40,48,56,64,80,96,112,128,144,160)[bitrate]
        return ByteArray((if(version==3)144000 else 72000)*kbps/rate+padding).apply {
            this[0]=0xff.toByte();this[1]=(0xe0 or (version shl 3) or 3).toByte()
            this[2]=((bitrate shl 4) or (rateIndex shl 2) or (padding shl 1)).toByte();this[3]=(if(mono)0xc0 else 0).toByte()
            val side=if(version==3) {if(mono)17 else 32} else {if(mono)9 else 17}
            tag?.toByteArray()?.copyInto(this,4+side)
        }
    }
    private fun packets(bytes:ByteArray,rate:Int=32000,channels:Int=1,onRead:()->Unit={}):Mp3OriginalFrames = Mp3OriginalFrames(bytes.size.toLong(),{p,b,o,n ->
        onRead();assertTrue(p>=0 && p+n<=bytes.size);bytes.copyInto(b,o,p.toInt(),p.toInt()+n);n
    },rate,channels)
    private fun rejects(block:()->Unit) {assertTrue(runCatching(block).isFailure)}
    @Test fun metadataFrameIsNotAnAudioPacket() {
        val audio=frame().apply {this[lastIndex]=42}
        val p=packets(frame(tag="Info")+audio);val out=ByteBuffer.allocate(2048)
        assertEquals(0L,p.sampleFrame);assertEquals(audio.size,p.read(out));assertArrayEquals(audio,out.array().copyOf(audio.size))
        p.advance();assertEquals(1152L,p.sampleFrame);out.clear();assertEquals(-1,p.read(out))
    }
    @Test fun indexedSeekCountsVariableBitrateAndPaddingWithoutEstimatingTime() {
        val a=frame();val b=frame(bitrate=4,padding=1);val c=frame(bitrate=5)
        val p=packets(frame(tag="Xing")+a+b+c)
        p.seek(1200);assertEquals(1152L,p.sampleFrame);assertEquals(b.size,p.read(ByteBuffer.allocate(2048)))
        p.seek(2400);assertEquals(2304L,p.sampleFrame);assertEquals(c.size,p.read(ByteBuffer.allocate(2048)))
        p.seek(0);assertEquals(0L,p.sampleFrame);p.seek(100000);assertEquals(-1,p.read(ByteBuffer.allocate(2048)))
    }
    @Test fun mpegTwoHas576SamplesPerFrame() {
        val p=packets(frame(version=2,tag="Info")+frame(version=2)+frame(version=2),16000)
        p.seek(600);assertEquals(576L,p.sampleFrame)
    }
    @Test fun mpegTwoPointFiveStereoIsQualified() {
        val p=packets(frame(version=0,mono=false,tag="Info")+frame(version=0,mono=false),8000,2)
        p.advance();assertEquals(576L,p.sampleFrame)
    }
    @Test fun syncSafeId3HeaderAndFixedTrailingId3v1AreNotSamples() {
        val id3=byteArrayOf(73,68,51,3,0,0,0,0,0,3)+byteArrayOf(1,2,3)
        val tail=ByteArray(128).apply {"TAG".toByteArray().copyInto(this)}
        val p=packets(id3+frame(tag="Info")+frame()+tail);p.advance();assertEquals(-1,p.read(ByteBuffer.allocate(2048)))
    }
    @Test fun malformedSyncSafeTagIsRefused() {rejects {packets(byteArrayOf(73,68,51,3,0,0,0,0,0,0xff.toByte())+frame(tag="Info"))}}
    @Test fun truncatedPacketIsRefused() {rejects {packets(frame(tag="Info")+frame().dropLast(1).toByteArray())}}
    @Test fun missingMetadataFrameIsRefused() {rejects {packets(frame()+frame())}}
    @Test fun sourceFormatChangeIsRefused() {rejects {packets(frame(tag="Info")+frame(mono=false))}}
    @Test fun arbitraryTailBytesCannotBecomeEos() {rejects {val p=packets(frame(tag="Info")+frame()+byteArrayOf(1,2,3));p.advance()}}
    @Test fun originalReadBudgetFailureIsPropagatedWithoutReplay() {
        val failure=IllegalStateException("synthetic original budget");var calls=0
        val bytes=frame(tag="Info")+frame()
        val p=packets(bytes,onRead={calls++;if(calls>2)throw failure})
        assertSame(failure,runCatching {p.seek(10000)}.exceptionOrNull());assertEquals(3,calls)
    }
    @Test fun encodedScanUsesBoundedBlocksInsteadOfOneReadPerHeader() {
        val bytes=frame(tag="Info")+ByteArray(0).let {frame().let {f->ByteArray(f.size*2000) {f[it%f.size]}}}
        var calls=0;val p=packets(bytes,onRead={calls++});p.seek(1152L*1900)
        assertEquals(1152L*1900,p.sampleFrame);assertTrue(calls<20)
    }
}
