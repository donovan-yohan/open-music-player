package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.datasource.*
import com.soundq.android.AppGraph
import com.soundq.android.playback.MediaGrant
import com.soundq.android.data.timeline.TimelineSource
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import org.junit.Assert.*
import org.junit.Test

/** Same actual preparation entrypoint on predecessor and successor. No new API discovery. */
class RollingListeningHostTest {
 @Test fun fixedThreeMetadataPreparationMustNotAcquireTheQueue() {
  Media3ListeningLane.reset()
  val fixtures=File(requireNotNull(System.getProperty("soundq.prepared.fixture")))
  val dir=java.nio.file.Files.createTempDirectory(java.nio.file.Path.of(System.getenv("TMPDIR")),"rolling-red-").toFile()
  val items=(0..2).map {i->MediaItem.Builder().setMediaId("v$i").setUri(Uri.parse("soundq://track/7/v$i")).build()}
  val graph=AppGraph(dir,items.associate {it.localConfiguration!!.uri.toString() to File(fixtures,"stereo.mp3")})
  val schedule=ListeningSchedule.compile((0..2).map{TimelineSource("v$it",7,3000)},1000)
  // Existing public preparation of >2 rows is the tracer. New explicit rolling entry is
  // selected only when present; absence does not count as the behavioral failure.
  val method=PreparedListening.Companion.javaClass.methods.firstOrNull{it.name=="prepareRolling"}
  val prepared=if(method==null)PreparedListening.prepare(graph,ConcurrentHashMap<String,MediaGrant>(),items,schedule){true}
   else method.invoke(PreparedListening.Companion,graph,ConcurrentHashMap<String,MediaGrant>(),items,schedule,{true}) as PreparedListening
  try {
   assertEquals("metadata admission must perform no all-queue acquisition",0,dir.listFiles()!!.size)
   assertEquals("metadata admission must not prime every occurrence",0,Media3ListeningLane.created.size)
  } finally {prepared.close()}
 }
 private data class F(val graph:AppGraph,val prepared:PreparedListening,val schedule:ListeningSchedule,val valid:java.util.concurrent.atomic.AtomicBoolean)
 private fun fixture(n:Int=5,duration:Long=3000,overlap:Long=1000):F {
  Media3ListeningLane.reset();val files=File(System.getProperty("soundq.prepared.fixture"));val dir=java.nio.file.Files.createTempDirectory(java.nio.file.Path.of(System.getenv("TMPDIR")),"rolling-").toFile()
  val items=(0 until n).map{MediaItem.Builder().setMediaId("v$it").setUri(Uri.parse("soundq://track/7/v$it")).build()}
  val schedule=ListeningSchedule.compile((0 until n).map{TimelineSource("v$it",7,duration)},overlap)
  val graph=AppGraph(dir,items.associate{it.localConfiguration!!.uri.toString() to File(files,if(it.mediaId=="v2")"mono.mp3" else "stereo.mp3")})
  val valid=java.util.concurrent.atomic.AtomicBoolean(true)
  return F(graph,PreparedListening.prepareRolling(graph,ConcurrentHashMap<String,MediaGrant>(),items,schedule){valid.get()},schedule,valid)
 }
 private val output=Uri.parse("soundqlistening://rolling")
 private fun all(s:DataSource,chunks:IntArray=intArrayOf(1,3,5,8191,17003)):ByteArray {
  val out=java.io.ByteArrayOutputStream();var i=0
  while(true){val n=chunks[i++%chunks.size];val b=ByteArray(n+4){37};val got=s.read(b,2,n);if(got<0)break;assertTrue(got>0);assertEquals(37,b[1].toInt());assertEquals(37,b[2+got].toInt());out.write(b,2,got)}
  return out.toByteArray()
 }
 private fun clean(f:F){f.prepared.close();val end=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(3);while(f.graph.directory.listFiles()!!.isNotEmpty()&&System.nanoTime()<end)Thread.sleep(1);assertEquals(0,f.graph.directory.listFiles()!!.size)}
 private fun pcm(name:String):FloatArray {val fixtures=File(System.getProperty("soundq.prepared.fixture"));val key=java.security.MessageDigest.getInstance("SHA-256").digest(File(fixtures,name).readBytes()).joinToString(""){"%02x".format(it)};val b=java.nio.ByteBuffer.wrap(File(fixtures,"$key.f32").readBytes()).order(java.nio.ByteOrder.LITTLE_ENDIAN).asFloatBuffer();return FloatArray(b.remaining()).also{b.get(it)}}
 @Test fun fixedFiveOddByteOutputMatchesEveryIndependentSampleAndExactEof() {
  val f=fixture();val s=f.prepared.acquire()
  try {
   assertEquals(44+528000L*8,s.open(DataSpec(output)))
   assertEquals(0,Media3ListeningLane.created.size)
   val bytes=all(s);assertEquals(44+528000*8,bytes.size);assertEquals(-1,s.read(ByteArray(1),0,1));s.close()
   val a=pcm("stereo.mp3");val b=pcm("mono.mp3");val floats=java.nio.ByteBuffer.wrap(bytes,44,bytes.size-44).order(java.nio.ByteOrder.LITTLE_ENDIAN).asFloatBuffer();var error=0.0
   for(frame in 0 until 528000)repeat(2){ch->
    var expected=0.0
    for(i in 0..4){val local=frame-i*96000;if(local in 0 until 144000){val gain=when{ i>0&&local<48000->kotlin.math.sin(local/48000.0*Math.PI/2);i<4&&local>96000->kotlin.math.sin((144000-local)/48000.0*Math.PI/2);else->1.0};expected+=(if(i==2)b else a)[local*2+ch]*gain}}
    error=maxOf(error,kotlin.math.abs(floats.get()-expected))
   }
   assertTrue("full five-source oracle $error",error<0.000001)
   val witness=f.prepared.residency()!!;assertEquals(2,witness.slotHighWater);assertTrue(witness.byteHighWater<=RollingListeningRoot.LIMIT);assertEquals((0..4).map{"v$it"},witness.acquisitions)
   assertTrue(witness.actualByteHighWater>0);assertTrue(witness.actualByteHighWater<=RollingListeningRoot.LIMIT)
   println("ROLLING_ORACLE frames=528000 samples=1056000 maxError=$error slots=${witness.slotHighWater} reservedHigh=${witness.byteHighWater} actualHigh=${witness.actualByteHighWater}")
   for(at in listOf(0L,43L,44L,45L,44+120000L*8+5,44+300000L*8+7,bytes.size-1L,bytes.size.toLong())){
    s.open(DataSpec(output,at,19));assertArrayEquals(bytes.copyOfRange(at.toInt(),minOf(bytes.size,at.toInt()+19)),all(s));s.close()
   }
  }finally{s.close();clean(f)}
 }
 @Test fun lateOpenAcquiresOnlyIntersectionsAndBackwardVisitReacquiresSealedBytes() {
  val f=fixture();val s=f.prepared.acquire()
  try {
   s.open(DataSpec(output,44+408000L*8+5,19));assertEquals(19,all(s).size);s.close()
   assertEquals(listOf("v3","v4"),f.prepared.residency()!!.acquisitions)
   s.open(DataSpec(output,44,8));val got=all(s);s.close();val expected=java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN).putFloat(pcm("stereo.mp3")[0]).putFloat(pcm("stereo.mp3")[1]).array();assertArrayEquals(expected,got)
   assertEquals(listOf("v3","v4","v0"),f.prepared.residency()!!.acquisitions)
  }finally{s.close();clean(f)}
 }
 @Test fun changedRepresentationOnEvictedReacquisitionRefusesWithoutPublishing() {
  val f=fixture();val s=f.prepared.acquire();val uri="soundq://track/7/v0"
  try {
   s.open(DataSpec(output,44,8));all(s);s.close()
   @Suppress("UNCHECKED_CAST") val inputs=f.graph.inputs as MutableMap<String,File>
   inputs[uri]=File(System.getProperty("soundq.prepared.fixture"),"mono.mp3")
   s.open(DataSpec(output,44,8));val bytes=ByteArray(8){37};var failure:Throwable?=null;try{s.read(bytes,0,8)}catch(t:Throwable){failure=t};assertNotNull(failure);assertTrue(bytes.all{it==37.toByte()})
  }finally{s.close();clean(f)}
 }
 @Test fun tinyActiveBoundariesSplitJniAndPreserveEverySourceFrame() {
  val f=fixture(5,1,0);Media3ListeningLane.frameLimit=48;val s=f.prepared.acquire()
  try {s.open(DataSpec(output));val bytes=all(s);s.close();assertEquals(44+240*8,bytes.size);val out=java.nio.ByteBuffer.wrap(bytes,44,bytes.size-44).order(java.nio.ByteOrder.LITTLE_ENDIAN).asFloatBuffer();val a=pcm("stereo.mp3");val b=pcm("mono.mp3");repeat(5){i->repeat(96){ch->assertEquals((if(i==2)b else a)[ch],out.get(),0f)}};assertEquals(1,f.prepared.residency()!!.slotHighWater);assertEquals(5,Media3ListeningLane.created.size)}finally{s.close();clean(f)}
 }
 @Test fun announcedActualUnknownAndCleanupFailuresNeverReleaseBorrowedCapacity() {
  for(mode in listOf("announced","actual","unknown","close")){
   val f=fixture(3);val s=f.prepared.acquire()
   when(mode){"announced"->f.graph.announced=RollingListeningRoot.LIMIT+1;"actual"->{f.graph.announced=1};"unknown"->{f.graph.announced=-1};else->f.graph.closeFailure=true}
   try {
    s.open(DataSpec(output,44));var failure:Throwable?=null;val bytes=ByteArray(8){37};try{s.read(bytes,0,8)}catch(t:Throwable){failure=t}
    if(mode=="unknown")assertNull(failure)else{assertNotNull(failure);assertTrue(bytes.all{it==37.toByte()})}
    s.close();f.prepared.close()
    if(mode=="close"){Thread.sleep(30);assertTrue(f.prepared.residency()!!.slots>0);assertTrue(f.prepared.residency()!!.reservedBytes>0);assertTrue(f.graph.directory.listFiles()!!.isNotEmpty())}
    assertTrue(f.prepared.residency()!!.byteHighWater<=RollingListeningRoot.LIMIT);assertEquals(1,f.graph.opens.size)
   }finally{s.close();if(mode!="close")clean(f)}
  }
 }
 @Test fun heldOutgoingDrainPreventsThirdAdmissionAndDeletion() {
  val f=fixture(3);val s=f.prepared.acquire();s.open(DataSpec(output,44))
  val bytes=ByteArray(16384)
  // Reach overlap without finishing outgoing. Then demand its exact EOF under a held receipt.
  var position=44L
  while(position<44+141000L*8){val n=s.read(bytes,0,minOf(bytes.size.toLong(),44+141000L*8-position).toInt());position+=n}
  assertEquals(2,Media3ListeningLane.created.size);Media3ListeningLane.holdDrain=true
  val pool=java.util.concurrent.Executors.newSingleThreadExecutor();val read=pool.submit<Boolean>{try{while(true){s.read(bytes,0,bytes.size)};false}catch(_:Throwable){true}}
  try {
   val first=Media3ListeningLane.created.first();val end=System.nanoTime()+2_000_000_000;while(!first.retirementRequested&&System.nanoTime()<end)Thread.sleep(1)
   assertTrue(first.retirementRequested);assertFalse(read.isDone);assertEquals(2,f.prepared.residency()!!.slots);assertEquals(2,f.graph.directory.listFiles()!!.size);assertEquals(2,f.graph.opens.size)
   f.prepared.close();assertEquals(2,f.graph.directory.listFiles()!!.size)
   Media3ListeningLane.holdDrain=false;Media3ListeningLane.created.forEach{it.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0))};assertTrue(read.get(2,java.util.concurrent.TimeUnit.SECONDS));assertEquals(2,f.graph.opens.size)
  }finally{Media3ListeningLane.holdDrain=false;Media3ListeningLane.created.forEach{it.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0))};s.close();pool.shutdownNow();clean(f)}
 }
 @Test fun rollingLoaderInterruptionRetiresGenerationNotRootButDecoderFaultDoes() {
  for(fault in listOf(false,true))for(same in listOf(false,true)){
   val f=fixture(3);val a=f.prepared.acquire();a.open(DataSpec(output,44));a.read(ByteArray(8),0,8)
   val held=java.util.concurrent.CompletableFuture<ListeningMemoryOutput.Window?>();Media3ListeningLane.held=held;Media3ListeningLane.entered=java.util.concurrent.CountDownLatch(1)
   val bytes=ByteArray(8){37};var failure:Throwable?=null;val thread=Thread{try{a.read(bytes,0,8)}catch(t:Throwable){failure=t}}
   // Move beyond the retained cursor window so next actually waits.
   a.close();a.open(DataSpec(output,44+4096L*8));thread.start();assertTrue(Media3ListeningLane.entered!!.await(2,java.util.concurrent.TimeUnit.SECONDS))
   if(fault)held.completeExceptionally(InterruptedException("decoder failed"))else thread.interrupt()
   thread.join(2000);assertFalse(thread.isAlive);assertTrue(bytes.all{it==37.toByte()});assertNotNull(failure);assertEquals(!fault,failure is java.io.InterruptedIOException)
   a.close();Media3ListeningLane.held=null;val b=if(same || fault)a else f.prepared.acquire()
   try {if(fault){try{b.open(DataSpec(output));fail("fault root must retire")}catch(_:Exception){}}else{b.open(DataSpec(output,44,8));assertEquals(8,all(b).size)}}finally{b.close();clean(f)}
  }
 }
 @Test fun successfulConcreteDrainCannotDeleteUntilRenderOperationExits() {
  Media3ListeningLane.reset();val files=File(System.getProperty("soundq.prepared.fixture"));val dir=java.nio.file.Files.createTempDirectory(java.nio.file.Path.of(System.getenv("TMPDIR")),"rolling-exit-").toFile()
  val item=MediaItem.Builder().setMediaId("a").setUri(Uri.parse("soundq://track/7/a")).build();val graph=AppGraph(dir,mapOf(item.localConfiguration!!.uri.toString() to File(files,"stereo.mp3")))
  val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1);val armed=java.util.concurrent.atomic.AtomicBoolean(true)
  val prepared=PreparedListening.prepareRolling(graph,ConcurrentHashMap<String,MediaGrant>(),listOf(item),ListeningSchedule.compile(listOf(TimelineSource("a",7,3000)),1000)){
   if(armed.get() && Media3ListeningLane.created.any{it.retirementRequested} && Thread.currentThread().stackTrace.any{it.className.endsWith("RollingListeningPcm")&&it.methodName=="read"}){entered.countDown();check(release.await(2,java.util.concurrent.TimeUnit.SECONDS))};true
  }
  val s=prepared.acquire();s.open(DataSpec(output,44+143999L*8));val bytes=ByteArray(8){37};val pool=java.util.concurrent.Executors.newSingleThreadExecutor();val read=pool.submit<Boolean>{try{s.read(bytes,0,8);false}catch(_:Throwable){true}}
  try{assertTrue(entered.await(2,java.util.concurrent.TimeUnit.SECONDS));assertTrue(Media3ListeningLane.created.single().drain.isDone);prepared.close();assertEquals(1,dir.listFiles()!!.size);assertEquals(1,prepared.residency()!!.slots);assertFalse(read.isDone);armed.set(false);release.countDown();assertTrue(read.get(2,java.util.concurrent.TimeUnit.SECONDS));assertTrue(bytes.all{it==37.toByte()})}finally{armed.set(false);release.countDown();s.close();pool.shutdownNow();clean(F(graph,prepared,ListeningSchedule.compile(emptyList(),0),java.util.concurrent.atomic.AtomicBoolean(true)))}
 }
 @Test fun secondAnnouncedSourceCannotBorrowOverAggregateCap() {
  val f=fixture(3);val s=f.prepared.acquire();s.open(DataSpec(output,44));assertEquals(8,s.read(ByteArray(8),0,8));val firstBytes=f.prepared.residency()!!.reservedBytes
  assertTrue(firstBytes>0);f.graph.announced=RollingListeningRoot.LIMIT
  try{val b=ByteArray(16384);var failed=false;try{while(s.read(b,0,b.size)>=0){}}catch(_:IllegalArgumentException){failed=true};assertTrue(failed);assertEquals(2,f.graph.opens.size);assertTrue(f.prepared.residency()!!.byteHighWater<=RollingListeningRoot.LIMIT)}finally{s.close();clean(f)}
 }
 @Test fun unknownLengthActualBytesCannotExceedReservedAggregateBudget() {
  val f=fixture(3);f.graph.announced=-1;f.graph.extraBytes=(RollingListeningRoot.LIMIT+1).toInt();val s=f.prepared.acquire();val bytes=ByteArray(8){37}
  try{s.open(DataSpec(output,44));var refused=false;try{s.read(bytes,0,8)}catch(_:IllegalArgumentException){refused=true};assertTrue(refused);assertTrue(bytes.all{it==37.toByte()});assertTrue(f.prepared.residency()!!.byteHighWater<=RollingListeningRoot.LIMIT);assertEquals(0,Media3ListeningLane.created.size)}finally{s.close();clean(f)}
 }
 @Test fun failedConcreteDrainRetainsSlotFileAndBudgetAndForbidsSuccessor() {
  for(mode in listOf("invalid","exceptional","cancelled")){
   val f=fixture(3);val s=f.prepared.acquire();s.open(DataSpec(output,44));s.read(ByteArray(8),0,8);Media3ListeningLane.holdDrain=true;s.close();val lane=Media3ListeningLane.created.single()
   when(mode){"invalid"->lane.drain.complete(Media3ListeningLane.DrainReceipt(1,1,1));"exceptional"->lane.drain.completeExceptionally(java.io.IOException("drain failed"));else->lane.drain.cancel(false)}
   try{var refused=false;try{s.open(DataSpec(output,44))}catch(_:Exception){refused=true};assertTrue(refused);assertEquals(1,Media3ListeningLane.created.size);assertEquals(1,f.prepared.residency()!!.slots);assertTrue(f.prepared.residency()!!.reservedBytes>0);assertEquals(1,f.graph.directory.listFiles()!!.size)}finally{Media3ListeningLane.holdDrain=false;s.close();f.prepared.close()}
  }
 }
 @Test fun rootRevocationDuringHeldRollingReadCannotPublishOrReopen() {
  val f=fixture(3);val a=f.prepared.acquire();a.open(DataSpec(output,44+4096L*8));val held=java.util.concurrent.CompletableFuture<ListeningMemoryOutput.Window?>();Media3ListeningLane.held=held;Media3ListeningLane.entered=java.util.concurrent.CountDownLatch(1);val bytes=ByteArray(8){37};var failure:Throwable?=null;val thread=Thread{try{a.read(bytes,0,8)}catch(t:Throwable){failure=t}}
  try{thread.start();assertTrue(Media3ListeningLane.entered!!.await(2,java.util.concurrent.TimeUnit.SECONDS));f.valid.set(false);f.prepared.close();held.completeExceptionally(java.io.IOException("retired"));thread.join(2000);assertFalse(thread.isAlive);assertNotNull(failure);assertTrue(bytes.all{it==37.toByte()});a.close();try{a.open(DataSpec(output));fail("revoked root cannot reopen")}catch(_:Exception){};assertEquals(1,f.graph.opens.size)}finally{Media3ListeningLane.held=null;held.completeExceptionally(java.io.IOException("cleanup"));thread.join(2000);a.close();clean(f)}
 }
 @Test fun fiveHundredMetadataRowsAreIoFreeAndOverflowRefuses() {
  val f=fixture(500,duration=1,overlap=0)
  try {assertEquals(0,f.prepared.residency()!!.slots);assertEquals(0,Media3ListeningLane.created.size);assertEquals(0,f.graph.directory.listFiles()!!.size)}finally{clean(f)}
  try{fixture(501);fail("501 must refuse")}catch(_:IllegalArgumentException){}
  try{fixture(3,duration=604800000);fail("RIFF overflow must refuse before IO")}catch(_:IllegalArgumentException){}
 }
}
