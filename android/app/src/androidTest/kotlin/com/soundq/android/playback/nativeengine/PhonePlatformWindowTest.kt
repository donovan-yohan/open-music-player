package com.soundq.android.playback.nativeengine

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.sqrt

/** Real codecs and the production JNI worker/output. Parent owns emulator execution.
 * Only generated app-private originals are created/deleted by this test.
 */
@RunWith(AndroidJUnit4::class)
class PhonePlatformWindowTest {
    @Before fun requireDirectCodecApplication() {
        assertEquals("Use DirectCodecFixtureRunner; the product runner starts a service-owned native engine",
            android.app.Application::class.java,context.applicationContext.javaClass)
    }
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val assets get()=InstrumentationRegistry.getInstrumentation().context.assets
    private fun lease(file:File,offset:Long=0,length:Long=file.length()-offset)=RandomAccessFile(file,"r").use {
        OriginalAudioReadLease.borrow(it.fd,offset,length,file.absolutePath,{true})
    }
    private fun fixture(name:String)=File.createTempFile("stream-original-",name,context.cacheDir).also {file->
        assets.open("streaming-codecs/$name").use {input->file.outputStream().use {input.copyTo(it)}}
    }
    @Test fun commonCodecsHaveIndependentOutOfOrderSampleOraclesAndNoPcmArtifact() {
        val records=JSONArray(assets.open("streaming-codecs/manifest.json").bufferedReader().use {it.readText()})
        var failure:Throwable?=null
        for(index in 0 until records.length()) {
            try {
                val record=records.getJSONObject(index);val name=record.getString("file")
                val original=fixture(name);val encoded=original.readBytes()
                val before=context.cacheDir.listFiles()!!.map {it.name}.toSet()
                val source=lease(original);val reader=AndroidPlatformWindowReader(source)
                try {
                    val rate=reader.open();assertEquals(record.getInt("rate"),rate)
                    assertFalse(reader.longFormConfirmed())
                    val windows=record.getJSONArray("windows")
                    for(n in listOf(1,0,1)) {
                        val first=windows.getLong(n)
                        val output=ByteBuffer.allocateDirect(1024*8).order(ByteOrder.nativeOrder())
                        android.util.Log.i("SoundQCodecFixture", "$name window=$n first=$first count=1024 before read")
                        val actual=try {reader.read(first,1024,output)} catch(error:Throwable) {
                            throw AssertionError("$name window=$n first=$first count=1024",error)
                        }
                        assertEquals(1024,actual)
                        val expected=assets.open("streaming-codecs/${name.substringAfterLast('.')}-${first}.f32").use {it.readBytes()}
                        val oracle=ByteBuffer.wrap(expected).order(ByteOrder.LITTLE_ENDIAN)
                        var peak=0.0;var energy=0.0
                        repeat(2048) {sample->val delta=abs(output.getFloat(sample*4)-oracle.float).toDouble();peak=maxOf(peak,delta);energy+=delta*delta}
                        assertTrue("$name frame $first peak=$peak",peak<.02)
                        assertTrue("$name frame $first RMS=${sqrt(energy/2048)}",sqrt(energy/2048)<.005)
                    }
                    assertEquals(before,context.cacheDir.listFiles()!!.map {it.name}.toSet())
                    assertArrayEquals(encoded,original.readBytes())
                } finally {assertTrue(reader.closeReader());assertTrue(original.exists());original.delete()}
            } catch(error:Throwable) {
                if(failure==null)failure=error else failure.addSuppressed(error)
            }
        }
        failure?.let {throw it}
    }
    private fun sparseLongWav():File {
        val rate=8000;val frames=rate.toLong()*12600;val bytes=frames*2
        val file=File.createTempFile("original-3-5h-",".wav",context.cacheDir)
        RandomAccessFile(file,"rw").use {out->
            out.setLength(44+bytes)
            out.write(ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).put("RIFF".toByteArray()).putInt((36+bytes).toInt()).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(rate).putInt(rate*2).putShort(2).putShort(16).put("data".toByteArray()).putInt(bytes.toInt()).array())
            val page=ByteBuffer.allocate(rate*2).order(ByteOrder.LITTLE_ENDIAN)
            repeat(rate){page.putShort(if(it%16<8)8192 else -8192)}
            for(second in (0..20)+(598..604)+(10798..10818)+(12598..12599)) {out.seek(44+second.toLong()*rate*2);out.write(page.array())}
        }
        return file
    }
    @Test fun realThreeAndHalfHourOriginalFirstSamplesAndThreeHourSeekUseBoundedReads() {
        val file=sparseLongWav();val originalBytes=file.length();val source=lease(file)
        val reader=AndroidPlatformWindowReader(source)
        try {
            val started=System.nanoTime();assertEquals(8000,reader.open());assertTrue(reader.longFormConfirmed())
            val pcm=ByteBuffer.allocateDirect(256*8).order(ByteOrder.nativeOrder())
            assertEquals(256,reader.read(0,256,pcm))
            repeat(256){assertEquals(if(it%16<8).25f else -.25f,pcm.getFloat(it*8),0f)}
            assertEquals(0L,reader.endFrames())
            assertTrue(source.totalReadBytes<8L*1024*1024)
            val firstUs=(System.nanoTime()-started)/1000
            val seekAt=System.nanoTime();assertEquals(256,reader.read(8000L*10800,256,pcm))
            repeat(256){assertEquals(if(it%16<8).25f else -.25f,pcm.getFloat(it*8),0f)}
            assertTrue(source.totalReadBytes<16L*1024*1024)
            println("REAL WAV 3.5h first PCM=${firstUs}us deep seek=${(System.nanoTime()-seekAt)/1000}us bytes=${source.totalReadBytes}; decoded sample oracle, not acoustic latency")
        } finally {assertTrue(reader.closeReader());assertEquals(originalBytes,file.length());assertTrue(file.exists());file.delete()}
    }
    @Test fun mp3AboveOldCapPrimesDeepTargetThroughSoleNativeCallbackEngine() {
        val frame=assets.open("streaming-codecs/repeatable-mp3-frame.bin").use {it.readBytes()}
        val repeats=12600L*32000/1152
        val file=File.createTempFile("original-3-5h-",".mp3",context.cacheDir)
        var length:Long?=null
        var ownedSource:OriginalAudioReadLease?=null
        var ownedPeer:AndroidPlatformWindowReader?=null
        var handle=0L
        var primary:Throwable?=null
        try {
            file.outputStream().buffered(1024*1024).use {out->repeat(repeats.toInt()){out.write(frame)}}
            assertTrue(file.length()>128L*1024*1024)
            length=file.length()
            val source=lease(file).also {ownedSource=it}
            val peer=AndroidPlatformWindowReader(source).also {ownedPeer=it}
            handle=NativeCallbackBridge.open();assertTrue(handle>0)
            val start=System.nanoTime()
            val observed=object:NativePcmReader by peer {
                override fun open():Int=try {peer.open().also {android.util.Log.i("SoundQCodecFixture","MP3 native open rate=$it")}}catch(error:Throwable) {
                    android.util.Log.e("SoundQCodecFixture","MP3 native open refused",error);throw error
                }
                override fun read(first:Long,count:Int,destination:ByteBuffer):Int=try {peer.read(first,count,destination)}catch(error:Throwable) {
                    android.util.Log.e("SoundQCodecFixture","MP3 native read first=$first count=$count refused",error);throw error
                }
            }
            assertTrue(NativeCallbackBridge.loadReader(handle,0,observed,7,1,10800000,1.0))
            var state=JSONObject(NativeCallbackBridge.state(handle))
            val deadline=System.nanoTime()+15_000_000_000L
            while(!state.getJSONArray("decks").getJSONObject(0).getBoolean("ready")) {
                assertTrue(state.toString(),System.nanoTime()<deadline)
                assertEquals(0,state.getJSONArray("decks").getJSONObject(0).getInt("error"))
                Thread.sleep(10);state=JSONObject(NativeCallbackBridge.state(handle))
            }
            assertTrue(abs(state.getJSONArray("decks").getJSONObject(0).getLong("positionMs")-10800000)<10)
            assertTrue(NativeCallbackBridge.control(handle,1,0,0.0,0))
            val audibleDeadline=System.nanoTime()+5_000_000_000L
            while(state.optLong("nonSilentCallbacks")==0L) {
                assertTrue(state.toString(),System.nanoTime()<audibleDeadline)
                Thread.sleep(10);state=JSONObject(NativeCallbackBridge.state(handle))
            }
            assertTrue(source.totalReadBytes<32L*1024*1024)
            assertEquals(0L,state.getJSONArray("decks").getJSONObject(0).getLong("naturalEndCount"))
            println("REAL MP3 3.5h >128MiB deep first callback=${(System.nanoTime()-start)/1000}us reads=${source.totalReadCalls} bytes=${source.totalReadBytes}")
        } catch(failure:Throwable) {
            primary=failure;throw failure
        } finally {
            var nativeClosed=handle==0L
            var readerClosed=false
            finishDirectCodecFixture(primary,
                {if(handle>0) {nativeClosed=NativeCallbackBridge.close(handle);assertTrue(nativeClosed)}},
                {
                    readerClosed=ownedPeer?.closeReader() ?: run {ownedSource?.close();true}
                    assertTrue(readerClosed)
                },
                {length?.let {assertEquals(it.toLong(),file.length())}},
                {assertTrue(file.exists())},
                {
                    // Never unlink a generated original while concrete custody is retained.
                    check(nativeClosed && readerClosed) {"Generated original retained by failed codec cleanup: $file"}
                    assertTrue(file.delete())
                })
        }
    }
    @Test fun explicitDescriptorSliceAndSamePathReplacementRevokeOldReadsWithoutUnlink() {
        val source=fixture("tone.wav");val data=source.readBytes()
        val ranged=File.createTempFile("original-range-",".bin",context.cacheDir)
        ranged.writeBytes(ByteArray(97)+data+ByteArray(83))
        val descriptor=lease(ranged,97,data.size.toLong());val reader=AndroidPlatformWindowReader(descriptor)
        try {
            assertEquals(32000,reader.open())
            assertEquals(1024,reader.read(2048,1024,ByteBuffer.allocateDirect(8192)))
            val sealedBefore=reader.endFrames()
            val replacement=File.createTempFile("replacement-",".bin",context.cacheDir).apply {writeBytes(ranged.readBytes())}
            assertTrue(replacement.renameTo(ranged))
            assertTrue(runCatching {reader.read(2048,1024,ByteBuffer.allocateDirect(8192))}.isFailure)
            assertEquals(sealedBefore,reader.endFrames()) // failure cannot mint a new endpoint
        } finally {assertTrue(reader.closeReader());assertTrue(ranged.exists());ranged.delete();source.delete()}
    }
}

/** Attempt every owned cleanup without replacing the original test failure. */
internal fun finishDirectCodecFixture(primary:Throwable?,vararg cleanup:()->Unit) {
    var failure=primary
    for(action in cleanup)try {action()}catch(error:Throwable) {
        if(failure==null)failure=error else if(failure!==error)failure.addSuppressed(error)
    }
    if(primary==null)failure?.let {throw it}
}
