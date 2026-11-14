package com.soundq.android.playback.nativeengine

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.sqrt

/** Exact retained tagged originals; independent ffmpeg windows, never fitted to product PCM. */
class TaggedLocalMp3WindowTest {
    @Test fun retainedTaggedAHasMappedStartSeekAndDecodedEos() = checkOriginal("a",60)
    @Test fun retainedTaggedBHasMappedStartSeekAndDecodedEos() = checkOriginal("b",180)
    @Test fun retainedTaggedCHasMappedStartSeekAndDecodedEos() = checkOriginal("c",15)
    private fun checkOriginal(name:String,seconds:Int) {
        val i=InstrumentationRegistry.getInstrumentation();val context=i.targetContext
        assertEquals(android.app.Application::class.java,context.applicationContext.javaClass)
        val encoded=i.context.assets.open("native-song-actions/$name.mp3").use {it.readBytes()}
        val file=File.createTempFile("tagged-original-",".mp3",context.cacheDir).apply {writeBytes(encoded)}
        val before=context.cacheDir.listFiles()!!.map {it.name}.toSet()
        var reader:AndroidPlatformWindowReader?=null
        var ownedSource:OriginalAudioReadLease?=null
        var closed=false
        var primary:Throwable?=null
        try {
            val source=RandomAccessFile(file,"r").use {OriginalAudioReadLease.borrow(it.fd,0,file.length(),file.absolutePath,{true})}.also {ownedSource=it}
            val peer=AndroidPlatformWindowReader(source).also {reader=it}
            assertEquals(32000,peer.open());assertFalse(peer.longFormConfirmed())
            val end=seconds*32000L
            for(first in listOf(0L,48000L,32000L*(seconds/2),end-500,0L)) {
                val expectedCount=if(first==end-500)500 else 2048
                val pcm=ByteBuffer.allocateDirect(2048*8).order(ByteOrder.nativeOrder())
                assertEquals("$name frame $first",expectedCount,peer.read(first,2048,pcm))
                val expected=i.context.assets.open("native-song-actions/$name-$first.f32").use {it.readBytes()}
                assertEquals(expectedCount*8,expected.size)
                val oracle=ByteBuffer.wrap(expected).order(ByteOrder.LITTLE_ENDIAN)
                var peak=0.0;var energy=0.0
                repeat(expectedCount*2) {sample -> val delta=abs(pcm.getFloat(sample*4)-oracle.float).toDouble();peak=maxOf(peak,delta);energy+=delta*delta}
                assertTrue("$name frame $first peak=$peak",peak<.02)
                assertTrue("$name frame $first RMS=${sqrt(energy/(expectedCount*2))}",sqrt(energy/(expectedCount*2))<.005)
                if(first==end-500)assertEquals("Decoded EOS, not metadata duration",end,peer.endFrames())
            }
            assertEquals(0,peer.read(end,1,ByteBuffer.allocateDirect(8)))
            assertTrue(source.totalReadBytes<32L*1024*1024)
            assertEquals(before,context.cacheDir.listFiles()!!.map {it.name}.toSet())
            assertArrayEquals(encoded,file.readBytes())
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            finishDirectCodecFixture(primary,
                {closed=reader?.closeReader() ?: run {ownedSource?.close();true};assertTrue(closed)},
                {check(closed) {"Retain generated original while reader custody remains"};assertTrue(file.delete())})
        }
    }
}
