package com.soundq.android.playback.nativeengine

import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Discriminates codec refill progress from MediaStore route validation on the
 * exact retained short B bytes. Generated originals only; no output owner. */
class TaggedShortRefillTest {
    @Test fun borrowedShortBOverlappingPagesProgressThroughTwelveSecondBoundary() = checkPages(false)
    @Test fun providerShortBOverlappingPagesProgressThroughTwelveSecondBoundary() = checkPages(true)
    private fun checkPages(provider:Boolean) {
        val i=InstrumentationRegistry.getInstrumentation();val context=i.targetContext
        assertEquals(android.app.Application::class.java,context.applicationContext.javaClass)
        val encoded=i.context.assets.open("native-song-actions/b.mp3").use {it.readBytes()}
        var uri:android.net.Uri?=null;var file:File?=null;var providerDirectory:File?=null
        val checks=AtomicInteger()
        fun current():Boolean {checks.incrementAndGet();return true}
        var source:OriginalAudioReadLease?=null;var peer:AndroidPlatformWindowReader?=null
        var closed=false;var primary:Throwable?=null
        val records=JSONArray();val report=File(context.filesDir,"tagged-refill-${if(provider)"provider" else "borrowed"}.json")
        try {
            val original=if(provider) {
                require(android.os.Build.VERSION.SDK_INT>=29)
                val values=ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME,"soundq-refill-${UUID.randomUUID()}.mp3")
                    put(MediaStore.MediaColumns.MIME_TYPE,"audio/mpeg")
                    put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/SoundQ refill ${UUID.randomUUID()}")
                    put(MediaStore.MediaColumns.IS_PENDING,1)
                }
                val inserted=checkNotNull(context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values)).also {uri=it}
                checkNotNull(context.contentResolver.openOutputStream(inserted,"w")).use {it.write(encoded)}
                assertEquals(1,context.contentResolver.update(inserted,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null))
                @Suppress("DEPRECATION") val path=context.contentResolver.query(inserted,arrayOf(MediaStore.MediaColumns.DATA),null,null,null)!!.use {check(it.moveToFirst());it.getString(0)}
                providerDirectory=File(path).parentFile
                val scanned=CountDownLatch(1)
                android.media.MediaScannerConnection.scanFile(context,arrayOf(path),arrayOf("audio/mpeg")) {_,_->scanned.countDown()}
                assertTrue(scanned.await(10,TimeUnit.SECONDS))
                OriginalAudioReadLease.open(context.contentResolver,inserted.toString(),::current)
            } else {
                val generated=File.createTempFile("short-refill-",".mp3",context.cacheDir).apply {writeBytes(encoded)}.also {file=it}
                RandomAccessFile(generated,"r").use {OriginalAudioReadLease.borrow(it.fd,0,generated.length(),generated.path,::current)}
            }.also {source=it}
            val reader=AndroidPlatformWindowReader(original).also {peer=it}
            assertEquals(32000,reader.open())
            val pcm=ByteBuffer.allocateDirect(48000*8).order(ByteOrder.nativeOrder())
            for(c in 0L..576000L step 48000L)for(first in listOf(c,c+48000)) {
                val record=JSONObject().put("first",first).put("startNs",System.nanoTime()).put("bytesBefore",original.totalReadBytes).put("checksBefore",checks.get())
                records.put(record);report.writeText(records.toString(2))
                val count=reader.read(first,48000,pcm)
                record.put("elapsedUs",(System.nanoTime()-record.getLong("startNs"))/1000).put("count",count).put("bytesAfter",original.totalReadBytes).put("checks",checks.get()-record.getInt("checksBefore"))
                report.writeText(records.toString(2))
                android.util.Log.i("SoundQCodecFixture","short B provider=$provider $record")
                assertEquals(48000,count)
                repeat(count*2) {assertTrue(pcm.getFloat(it*4).isFinite())}
                assertEquals(0L,reader.endFrames())
            }
        } catch(error:Throwable) {primary=error;report.writeText(JSONObject().put("reads",records).put("failure",error.toString()).toString(2));throw error}
        finally {
            finishDirectCodecFixture(primary,
                {closed=peer?.closeReader() ?: run {source?.close();true};assertTrue(closed)},
                {check(closed);uri?.let {assertEquals(1,context.contentResolver.delete(it,null,null))};file?.let {assertTrue(it.delete())};providerDirectory?.let {if(it.exists())assertTrue(it.delete())}})
        }
    }
}
