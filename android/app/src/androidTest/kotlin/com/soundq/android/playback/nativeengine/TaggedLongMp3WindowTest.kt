package com.soundq.android.playback.nativeengine

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.sqrt

/** Explicitly staged private evidence, never a giant APK asset. Run only with
 * DirectCodecFixtureRunner after generate_tagged_long_fixture.py, staging its
 * output as targetContext.cacheDir/tagged-seek-fixture. No account/server/MediaStore.
 * These tests are source-only until the parent transfers SDK/runtime custody.
 */
class TaggedLongMp3WindowTest {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun fixture():Pair<File,JSONObject> {
        assertEquals(android.app.Application::class.java,context.applicationContext.javaClass)
        val directory=File(context.cacheDir,"tagged-seek-fixture")
        val manifest=JSONObject(File(directory,"manifest.json").readText())
        assertEquals(32000,manifest.getInt("rate"));assertEquals(403200000L,manifest.getLong("frames"))
        val original=File(directory,"tagged-long.mp3")
        assertEquals(manifest.getLong("bytes"),original.length())
        assertEquals(manifest.getString("sha256"),sha(original))
        return original to manifest
    }
    private fun sha(file:File):String {
        val hash=java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use {input->val chunk=ByteArray(65536);while(true) {val n=input.read(chunk);if(n<0)break;hash.update(chunk,0,n)}}
        return hash.digest().joinToString("") {"%02x".format(it)}
    }
    private fun lease(file:File)=RandomAccessFile(file,"r").use {OriginalAudioReadLease.borrow(it.fd,0,file.length(),file.absolutePath,{true})}
    private fun compare(file:File,first:Long,count:Int,pcm:ByteBuffer) {
        val oracle=ByteBuffer.wrap(File(file.parentFile,"window-$first.f32").readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        assertTrue(oracle.remaining()>=count*8)
        val samples=pcm.duplicate().order(ByteOrder.nativeOrder())
        var peak=0.0;var energy=0.0
        repeat(count*2) {sample ->val delta=abs(samples.getFloat(sample*4)-oracle.float).toDouble();peak=maxOf(peak,delta);energy+=delta*delta}
        assertTrue("frame=$first peak=$peak",peak<.02)
        assertTrue("frame=$first RMS=${sqrt(energy/(count*2))}",sqrt(energy/(count*2))<.005)
    }
    @Test fun coldThreeHourAndActualOverlappedPagesMatchFullDecodeOracles() {
        val (file,manifest)=fixture();val source=lease(file);val peer=AndroidPlatformWindowReader(source)
        var primary:Throwable?=null
        try {
            assertEquals(32000,peer.open());assertTrue(peer.longFormConfirmed())
            val pcm=ByteBuffer.allocateDirect(48000*8).order(ByteOrder.nativeOrder())
            val base=179520000L
            val requests=listOf(345600000L to 2048,base to 48000,base+48000 to 48000,
                base+48000 to 48000,base+96000 to 48000,base+96000 to 48000,base+144000 to 48000,
                0L to 2048,48000L to 2048,345600000L to 2048,403199500L to 500,0L to 2048)
            for((first,count) in requests) {
                val before=source.totalReadBytes
                // Request beyond the tail so mapped codec EOS is actually drained,
                // rather than assuming metadata/count proves a decoded endpoint.
                val requested=if(first==403199500L)2048 else count
                assertEquals(count,peer.read(first,requested,pcm));compare(file,first,count,pcm)
                assertTrue("bounded window $first",source.totalReadBytes-before<1024*1024)
            }
            assertEquals(403200000L,peer.endFrames())
            assertEquals(0,peer.read(403200000L,1,pcm))
            peer.revoke()
            assertTrue(runCatching {peer.read(345600000L,2048,pcm)}.isFailure)
        } catch(error:Throwable) {primary=error;throw error}
        finally {finishDirectCodecFixture(primary,{assertTrue(peer.closeReader())},{assertEquals(manifest.getString("sha256"),sha(file))})}
    }
    @Test fun coldTaggedTargetUsesRealWorkerSoleNativeCallbackAndIndependentSamples() {
        val (file,manifest)=fixture()
        var source:OriginalAudioReadLease?=null;var peer:AndroidPlatformWindowReader?=null
        var handle=0L;var primary:Throwable?=null
        val matched=AtomicInteger()
        try {
            val original=lease(file).also {source=it}
            val reader=AndroidPlatformWindowReader(original).also {peer=it}
            val observed=object:NativePcmReader by reader {
                override fun read(first:Long,count:Int,destination:ByteBuffer):Int {
                    val n=reader.read(first,count,destination)
                    if(first==345600000L && n>=2048) {compare(file,first,2048,destination);matched.incrementAndGet()}
                    return n
                }
            }
            handle=NativeCallbackBridge.open();assertTrue(handle>0)
            assertTrue(NativeCallbackBridge.loadReader(handle,0,observed,7,1,10800000,1.0))
            val deadline=System.nanoTime()+15_000_000_000L
            var state=JSONObject(NativeCallbackBridge.state(handle))
            while(!state.getJSONArray("decks").getJSONObject(0).getBoolean("ready")) {
                assertEquals(state.toString(),0,state.getJSONArray("decks").getJSONObject(0).getInt("error"))
                assertTrue(state.toString(),System.nanoTime()<deadline)
                Thread.sleep(10);state=JSONObject(NativeCallbackBridge.state(handle))
            }
            assertTrue("Real worker target matched independent full decode",matched.get()>0)
            assertTrue(NativeCallbackBridge.control(handle,1,0,0.0,0))
            val callbackDeadline=System.nanoTime()+5_000_000_000L
            while(state.optLong("nonSilentCallbacks")==0L) {
                assertTrue(state.toString(),System.nanoTime()<callbackDeadline)
                Thread.sleep(10);state=JSONObject(NativeCallbackBridge.state(handle))
            }
            assertEquals(0L,state.getJSONArray("decks").getJSONObject(0).getLong("naturalEndCount"))
            assertTrue(original.totalReadBytes<32L*1024*1024)
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            finishDirectCodecFixture(primary,
                {if(handle>0)assertTrue(NativeCallbackBridge.close(handle))},
                {assertTrue(peer?.closeReader() ?: run {source?.close();true})},
                {assertEquals(manifest.getString("sha256"),sha(file))})
        }
    }
}
