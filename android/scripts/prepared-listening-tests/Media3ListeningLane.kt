package com.soundq.android.playback.listening
import android.net.Uri
import androidx.media3.datasource.DataSource
import java.util.concurrent.*
import java.io.File
/** Hardware/codec boundary only. All ownership, cursor, WAV and JNI stay production. */
internal class Media3ListeningLane(context:Any,uri:Uri,factory:DataSource.Factory,private val capturedValid:()->Boolean,capacityFrames:Int=32768) {
 data class DrainReceipt(val extractorReleases:Int,val openSources:Int,val readsInFlight:Int)
 private val pcm:ByteArray
 private var frame=0L
 private var retired=false
 val retirementRequested get()=retired
 val drain=CompletableFuture<DrainReceipt>()
 init { val f=File(java.net.URI(uri.toString()));val key=java.security.MessageDigest.getInstance("SHA-256").digest(f.readBytes()).joinToString(""){"%02x".format(it)};pcm=File(System.getProperty("soundq.prepared.fixture"),"$key.f32").readBytes();created.add(this);constructEntered?.countDown();constructRelease?.let { check(it.await(2,TimeUnit.SECONDS)) } }
 fun next(maxFrames:Int):CompletableFuture<ListeningMemoryOutput.Window?> {
  check(!retired && capturedValid());entered?.countDown()
  held?.let { return it }
  val n=minOf(maxFrames.toLong(),(frameLimit ?: (pcm.size/8).toLong())-frame).toInt()
  if(n==0)return CompletableFuture.completedFuture(null)
  val w=ListeningMemoryOutput.Window(frame,pcm.copyOfRange((frame*8).toInt(),((frame+n)*8).toInt()));frame+=n
  return CompletableFuture.completedFuture(w)
 }
 fun retireAndDrain():CompletableFuture<DrainReceipt> {retired=true;if(!holdDrain)drain.complete(DrainReceipt(1,0,0));return drain}
 companion object {var frameLimit:Long?=null;val created=java.util.Collections.synchronizedList(mutableListOf<Media3ListeningLane>());var held:CompletableFuture<ListeningMemoryOutput.Window?>?=null;var entered:CountDownLatch?=null;var holdDrain=false;var constructEntered:CountDownLatch?=null;var constructRelease:CountDownLatch?=null;fun reset(){frameLimit=null;held=null;entered=null;holdDrain=false;constructEntered=null;constructRelease=null;created.clear()}}
}
