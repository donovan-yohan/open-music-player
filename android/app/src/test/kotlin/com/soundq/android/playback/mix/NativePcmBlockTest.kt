package com.soundq.android.playback.mix

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*
import org.junit.Assert.*
import org.junit.Test

/** Actual synchronous JNI/DSP, never a platform decoder or an audio output. */
class NativePcmBlockTest {
    @Test fun everySampleKeepsSourceOriginsAndEqualPowerAcrossBlockBoundaries() {
        val length=144000;val incoming=96000;val total=240000
        val a=FloatArray(length*2) {i -> if(i%2==0)(.22*sin(i/2*.019)).toFloat() else (.14*cos(i/2*.029)).toFloat()}
        val b=FloatArray(length*2) {i -> if(i%2==0)(.12*cos(i/2*.031)).toFloat() else (.23*sin(i/2*.013)).toFloat()}
        var maxError=0.0
        for(origin in 0 until total step 997) {
            val count=minOf(997,total-origin);val clips=mutableListOf<Long>();val windows=mutableListOf<FloatArray>()
            for(i in 0..1) {
                val start=if(i==0)0 else incoming;val end=start+length
                if(end<=origin||start>=origin+count)continue
                val local=maxOf(origin,start)-start;val stop=minOf(origin+count,end)-start
                clips.addAll(listOf(i+11L,start.toLong(),end.toLong(),0,length.toLong(),if(i==0)0 else 48000,if(i==0)48000 else 0,local.toLong()))
                windows+=(if(i==0)a else b).copyOfRange(local*2,stop*2)
            }
            val bytes=ByteArray(count*8)
            NativeMix.renderPcmBlock(origin.toLong(),count,clips.toLongArray(),windows.toTypedArray(),FloatArray(windows.size){1f},bytes)
            val pcm=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
            repeat(count) {offset ->
                val frame=origin+offset;val u=((frame-incoming)/48000.0).coerceIn(0.0,1.0)
                repeat(2) {channel ->
                    val expected=(if(frame<length)a[frame*2+channel]*cos(u*PI/2) else 0.0)+(if(frame>=incoming)b[(frame-incoming)*2+channel]*sin(u*PI/2) else 0.0)
                    maxError=maxOf(maxError,abs(pcm.get()-expected))
                }
            }
        }
        assertTrue("Every-sample maximum error $maxError",maxError<=.000001)
    }
    @Test fun refusedWindowsAndMalformedArraysLeaveOutputUnchanged() {
        val clip=longArrayOf(1,0,10000,0,10000,0,0,0)
        val window=FloatArray(2000){.2f}
        fun refused(clips:LongArray,windows:Array<FloatArray>,gains:FloatArray,frames:Int=1000,bytes:Int=frames*8) {
            val output=ByteArray(bytes){37};val before=output.copyOf()
            try {NativeMix.renderPcmBlock(0,frames,clips,windows,gains,output);fail("Expected invalid candidate refusal")}
            catch(_:IllegalArgumentException) {assertArrayEquals(before,output)}
        }
        refused(clip,arrayOf(window.copyOf(1998)),floatArrayOf(1f))
        refused(clip.copyOf(7),arrayOf(window),floatArrayOf(1f))
        refused(clip,arrayOf(window),floatArrayOf())
        refused(clip,arrayOf(window.copyOf(1999)),floatArrayOf(1f))
        refused(clip,arrayOf(window),floatArrayOf(Float.NaN))
        refused(clip,arrayOf(window),floatArrayOf(1f),bytes=7999)
        refused(clip,arrayOf(FloatArray(4098)),floatArrayOf(1f),frames=2049)
        NativeMix.renderPcmBlock(0,1000,clip,arrayOf(window),floatArrayOf(1f),ByteArray(8000))
    }
    @Test fun emptyBlockAndZeroGainPreserveDeclaredSilenceAndCallerSamples() {
        val bytes=ByteArray(80){11}
        NativeMix.renderPcmBlock(100,10,longArrayOf(),emptyArray(),floatArrayOf(),bytes)
        assertTrue(bytes.all {it==0.toByte()})
        val samples=FloatArray(20){.25f};val original=samples.copyOf()
        NativeMix.renderPcmBlock(0,10,longArrayOf(1,0,10,0,10,0,0,0),arrayOf(samples),floatArrayOf(0f),bytes)
        assertTrue(bytes.all {it==0.toByte()});assertArrayEquals(original,samples,0f)
    }
}
