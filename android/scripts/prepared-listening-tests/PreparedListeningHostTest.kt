package com.soundq.android.playback.listening
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.datasource.*
import com.soundq.android.AppGraph
import com.soundq.android.playback.MediaGrant
import com.soundq.android.data.timeline.TimelineSource
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.*
class PreparedListeningHostTest {
 private val fixtures get()=File(requireNotNull(System.getProperty("soundq.prepared.fixture")))
 private val output=Uri.parse("soundqlistening://mix")
 private class Fixture(val graph:AppGraph,val prepared:PreparedListening,val valid:AtomicBoolean)
 private fun fixture(names:List<String> = listOf("stereo.mp3"), overlap:Long=0,duration:Long=3000):Fixture {
  Media3ListeningLane.reset()
  val dir=java.nio.file.Files.createTempDirectory(java.nio.file.Path.of(System.getenv("TMPDIR")),"prepared-").toFile()
  val uris=names.indices.map{Uri.parse("soundq://track/7/visit-$it")}
  val graph=AppGraph(dir,uris.zip(names.map{File(fixtures,it)}).associate{it.first.toString() to it.second})
  val items=uris.mapIndexed{i,u->MediaItem.Builder().setMediaId("visit-$i").setUri(u).build()}
  val schedule=ListeningSchedule.compile(names.indices.map{TimelineSource("visit-$it",7,duration)},overlap)
  val valid=AtomicBoolean(true)
  return Fixture(graph,PreparedListening.prepare(graph,ConcurrentHashMap<String,MediaGrant>(),items,schedule){valid.get()},valid)
 }
 private fun readAll(source:DataSource, chunks:IntArray=intArrayOf(16384)):ByteArray {
  val out=java.io.ByteArrayOutputStream();var i=0
  while(true){val n=chunks[i++%chunks.size];val b=ByteArray(n+6){37};val got=source.read(b,3,n);if(got<0)break;assertTrue(got>0);assertEquals(37,b[2].toInt());assertEquals(37,b[3+got].toInt());out.write(b,3,got)}
  return out.toByteArray()
 }
 private fun awaitClean(f:Fixture){val until=System.nanoTime()+TimeUnit.SECONDS.toNanos(3);while(f.graph.directory.listFiles()!!.isNotEmpty()&&System.nanoTime()<until)Thread.sleep(2);assertEquals(0,f.graph.directory.listFiles()!!.size)}
 private fun rejected(block:()->Unit){try{block();fail("Expected refusal")}catch(_:IllegalStateException){}catch(_:IllegalArgumentException){}catch(_:ExecutionException){}}
 private fun awaitThread(thread:Thread, method:String) {
  val until=System.nanoTime()+TimeUnit.SECONDS.toNanos(2)
  while(System.nanoTime()<until) {
   if(thread.state==Thread.State.TIMED_WAITING && thread.stackTrace.any{it.methodName==method})return
   Thread.sleep(1)
  }
  fail("loader did not await $method: ${thread.state}")
 }
 private data class CancelledRead(val failure:Throwable?,val reopened:Throwable?,val interrupted:Boolean)
 private fun cancelReadAndReopen(sameFacade:Boolean):CancelledRead {
  val f=fixture();val a=f.prepared.acquire();a.open(DataSpec(output,44+2048L*8))
  // Complete a real cursor/JNI block before holding the next codec demand.
  assertEquals(8,a.read(ByteArray(8),0,8))
  a.close();a.open(DataSpec(output,44+4096L*8))
  val old=Media3ListeningLane.created.last();val before=Media3ListeningLane.created.size
  val held=CompletableFuture<ListeningMemoryOutput.Window?>();Media3ListeningLane.held=held
  Media3ListeningLane.entered=CountDownLatch(1);Media3ListeningLane.holdDrain=true
  val bytes=ByteArray(17){37};var failure:Throwable?=null;var interrupted=false
  val exited=CountDownLatch(1)
  val loader=Thread({try{a.read(bytes,0,bytes.size)}catch(t:Throwable){failure=t}finally{interrupted=Thread.currentThread().isInterrupted;exited.countDown()}},"actual-loader-cancel-read")
  val b=if(sameFacade)a else f.prepared.acquire();var reopened:Throwable?=null
  val openExited=CountDownLatch(1)
  val opener=Thread({try{b.open(DataSpec(output,44))}catch(t:Throwable){reopened=t}finally{openExited.countDown()}},"actual-loader-reopen")
  try {
   loader.start();assertTrue(Media3ListeningLane.entered!!.await(2,TimeUnit.SECONDS));awaitThread(loader,"await")
   loader.interrupt();awaitThread(loader,"awaitDrain")
   assertTrue(old.retirementRequested);assertFalse(old.drain.isDone)
   assertTrue(bytes.all{it==37.toByte()});assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());assertEquals(0,f.graph.closes)
   assertEquals(before,Media3ListeningLane.created.size);assertEquals(1L,exited.count)
   Media3ListeningLane.held=null;Media3ListeningLane.holdDrain=false
   old.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0))
   assertTrue(exited.await(2,TimeUnit.SECONDS));loader.join()
   // Match ExtractingLoadable finally: close only after the interrupted read exits.
   a.close();opener.start();assertTrue(openExited.await(2,TimeUnit.SECONDS));opener.join()
   assertTrue(bytes.all{it==37.toByte()})
   if(reopened==null){assertEquals(before+1,Media3ListeningLane.created.size);val out=ByteArray(17);assertEquals(17,b.read(out,0,17));val expected=ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN);pcm("stereo.mp3").take(6).forEach{expected.putFloat(it)};assertArrayEquals(expected.array().copyOf(17),out)}
   return CancelledRead(failure,reopened,interrupted)
  }finally{
   Media3ListeningLane.held=null;Media3ListeningLane.holdDrain=false;held.completeExceptionally(IllegalStateException("test cleanup"));old.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));loader.join(2000);if(opener.state!=Thread.State.NEW)opener.join(2000);a.close();b.close();f.prepared.close()
  }
 }
 @Test fun interruptedLoaderReadUsesIoBoundaryNotUnexpectedLoaderException() {
  val result=cancelReadAndReopen(true)
  assertTrue("expected InterruptedIOException, got ${result.failure}",result.failure is java.io.InterruptedIOException)
  assertTrue(result.interrupted)
 }
 @Test fun interruptedLoaderReadReopensSameFacadeWithFreshExactPcm() {
  val result=cancelReadAndReopen(true);assertNull("same facade root must survive ${result.failure}",result.reopened)
 }
 @Test fun interruptedLoaderReadReopensNewFacadeWithFreshExactPcm() {
  val result=cancelReadAndReopen(false);assertNull("new facade root must survive ${result.failure}",result.reopened)
 }
 @Test fun interruptedReopenWaitPreservesRootAndPredecessorCustody() {
  val f=fixture();val s=f.prepared.acquire();s.open(DataSpec(output));Media3ListeningLane.holdDrain=true;s.close()
  val old=Media3ListeningLane.created.single();var failure:Throwable?=null
  val loader=Thread({try{s.open(DataSpec(output,44))}catch(t:Throwable){failure=t}},"cancel-reopen-wait")
  try {
   loader.start();awaitThread(loader,"open");loader.interrupt();loader.join(2000);assertFalse(loader.isAlive)
   assertEquals(1,Media3ListeningLane.created.size);assertFalse(old.drain.isDone);assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());assertEquals(0,f.graph.closes)
   Media3ListeningLane.holdDrain=false;old.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));s.close()
   var reopen:Throwable?=null;try{s.open(DataSpec(output,44));assertEquals(8,s.read(ByteArray(8),0,8))}catch(t:Throwable){reopen=t}
   assertNull("interrupted open cannot retire root",reopen);assertTrue("open must use IO boundary: $failure",failure is java.io.InterruptedIOException)
  }finally{Media3ListeningLane.holdDrain=false;old.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));loader.join(2000);s.close();f.prepared.close()};awaitClean(f)
 }
 @Test fun interruptedReopenPrimeRetiresOnlyConstructedGeneration() {
  val f=fixture();val s=f.prepared.acquire();s.open(DataSpec(output));s.close()
  val held=CompletableFuture<ListeningMemoryOutput.Window?>();Media3ListeningLane.held=held;Media3ListeningLane.entered=CountDownLatch(1);Media3ListeningLane.holdDrain=true
  var failure:Throwable?=null;val loader=Thread({try{s.open(DataSpec(output,44))}catch(t:Throwable){failure=t}},"cancel-reopen-prime")
  try {
   loader.start();assertTrue(Media3ListeningLane.entered!!.await(2,TimeUnit.SECONDS));awaitThread(loader,"await");loader.interrupt();awaitThread(loader,"awaitDrain")
   val born=Media3ListeningLane.created.last();assertTrue(born.retirementRequested);assertEquals(2,Media3ListeningLane.created.size);assertTrue(f.graph.directory.listFiles()!!.isNotEmpty())
   Media3ListeningLane.held=null;Media3ListeningLane.holdDrain=false;born.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));loader.join(2000);assertFalse(loader.isAlive);s.close()
   var reopen:Throwable?=null;try{s.open(DataSpec(output,44));assertEquals(8,s.read(ByteArray(8),0,8))}catch(t:Throwable){reopen=t}
   assertNull("interrupted prime cannot retire root",reopen);assertTrue("prime must use IO boundary: $failure",failure is java.io.InterruptedIOException);assertEquals(3,Media3ListeningLane.created.size)
  }finally{Media3ListeningLane.held=null;Media3ListeningLane.holdDrain=false;held.completeExceptionally(IllegalStateException("cleanup"));Media3ListeningLane.created.forEach{it.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0))};loader.join(2000);s.close();f.prepared.close()};awaitClean(f)
 }
 @Test fun decoderReportedInterruptedExceptionIsGenuineFaultNotLoaderCancellation() {
  val f=fixture();val s=f.prepared.acquire();s.open(DataSpec(output,44+4096L*8));val fault=CompletableFuture<ListeningMemoryOutput.Window?>();fault.completeExceptionally(InterruptedException("decoder fault, loader not interrupted"));Media3ListeningLane.held=fault
  try {
   val bytes=ByteArray(8){37};try{s.read(bytes,0,8);fail("fault must refuse")}catch(_:Exception){}
   assertTrue(bytes.all{it==37.toByte()});s.close();Media3ListeningLane.held=null;Thread.interrupted()
   var refused=false;try{s.open(DataSpec(output))}catch(_:Exception){refused=true};assertTrue("genuine decoder failure must remain root-terminal",refused)
  }finally{Thread.interrupted();Media3ListeningLane.held=null;s.close();f.prepared.close()};awaitClean(f)
 }
 @Test fun repeatedInterruptCannotTurnReadExitIntoSuccessfulDrain() {
  val f=fixture();val a=f.prepared.acquire();a.open(DataSpec(output,44+4096L*8));val b=f.prepared.acquire()
  val held=CompletableFuture<ListeningMemoryOutput.Window?>();Media3ListeningLane.held=held;Media3ListeningLane.entered=CountDownLatch(1);Media3ListeningLane.holdDrain=true
  val bytes=ByteArray(8){37};var failure:Throwable?=null;val loader=Thread({try{a.read(bytes,0,8)}catch(t:Throwable){failure=t}},"twice-interrupted-read")
  var opened:Throwable?=null;val opener=Thread({try{b.open(DataSpec(output,44))}catch(t:Throwable){opened=t}},"receipt-gated-reopen")
  try{
   loader.start();assertTrue(Media3ListeningLane.entered!!.await(2,TimeUnit.SECONDS));awaitThread(loader,"await");loader.interrupt();awaitThread(loader,"awaitDrain");loader.interrupt();loader.join(2000);assertFalse(loader.isAlive)
   assertTrue(failure is java.io.InterruptedIOException);assertTrue(bytes.all{it==37.toByte()});val old=Media3ListeningLane.created.single();assertFalse(old.drain.isDone)
   a.close();opener.start();awaitThread(opener,"open");assertEquals(1,Media3ListeningLane.created.size);assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());assertEquals(0,f.graph.closes)
   Media3ListeningLane.held=null;Media3ListeningLane.holdDrain=false;old.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));opener.join(2000);assertFalse(opener.isAlive);assertNull(opened);assertEquals(2,Media3ListeningLane.created.size);assertEquals(8,b.read(ByteArray(8),0,8))
  }finally{Media3ListeningLane.held=null;Media3ListeningLane.holdDrain=false;held.completeExceptionally(IllegalStateException("cleanup"));Media3ListeningLane.created.forEach{it.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0))};loader.join(2000);if(opener.state!=Thread.State.NEW)opener.join(2000);a.close();b.close();f.prepared.close()};awaitClean(f)
 }
 @Test fun interruptedReadCannotBypassFailedCancelledOrInvalidConcreteDrain() {
  for(mode in listOf("exceptional","cancelled","invalid")){
   val f=fixture();val a=f.prepared.acquire();a.open(DataSpec(output,44+4096L*8));val held=CompletableFuture<ListeningMemoryOutput.Window?>();Media3ListeningLane.held=held;Media3ListeningLane.entered=CountDownLatch(1);Media3ListeningLane.holdDrain=true
   val bytes=ByteArray(8){37};var failure:Throwable?=null;val loader=Thread({try{a.read(bytes,0,8)}catch(t:Throwable){failure=t}},"interrupted-$mode-drain")
   try{
    loader.start();assertTrue(Media3ListeningLane.entered!!.await(2,TimeUnit.SECONDS));awaitThread(loader,"await");loader.interrupt();awaitThread(loader,"awaitDrain")
    val old=Media3ListeningLane.created.single();when(mode){"exceptional"->old.drain.completeExceptionally(java.io.IOException("concrete drain failed"));"cancelled"->old.drain.cancel(false);else->old.drain.complete(Media3ListeningLane.DrainReceipt(1,1,1))}
    loader.join(2000);assertFalse(loader.isAlive);assertNotNull(failure);assertFalse("failed cleanup is not ordinary cancellation",failure is java.io.InterruptedIOException);assertTrue(bytes.all{it==37.toByte()});a.close();Media3ListeningLane.held=null;rejected{a.open(DataSpec(output))};f.prepared.close();assertEquals(1,Media3ListeningLane.created.size);assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());assertEquals(0,f.graph.closes)
   }finally{Media3ListeningLane.held=null;Media3ListeningLane.holdDrain=false;held.completeExceptionally(IllegalStateException("cleanup"));loader.join(2000);a.close();f.prepared.close()}
  }
 }
 @Test fun interruptedLoaderStillCannotReopenRevokedAccountRoot() {
  val f=fixture();val a=f.prepared.acquire();a.open(DataSpec(output,44+4096L*8));val held=CompletableFuture<ListeningMemoryOutput.Window?>();Media3ListeningLane.held=held;Media3ListeningLane.entered=CountDownLatch(1);Media3ListeningLane.holdDrain=true
  val loader=Thread({try{a.read(ByteArray(8),0,8)}catch(_:Throwable){}},"revoked-interrupted-loader")
  try{
   loader.start();assertTrue(Media3ListeningLane.entered!!.await(2,TimeUnit.SECONDS));awaitThread(loader,"await");f.valid.set(false);f.prepared.close();loader.interrupt();awaitThread(loader,"awaitDrain");Media3ListeningLane.created.single().drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));loader.join(2000);assertFalse(loader.isAlive);a.close();rejected{a.open(DataSpec(output))};rejected{f.prepared.acquire()};assertEquals(1,Media3ListeningLane.created.size)
  }finally{Media3ListeningLane.held=null;Media3ListeningLane.holdDrain=false;held.completeExceptionally(IllegalStateException("cleanup"));Media3ListeningLane.created.forEach{it.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0))};loader.join(2000);a.close();f.prepared.close()};awaitClean(f)
 }
 @Test fun mp3PreparationFeedsExistingDataSource() {
  val f=fixture();try {val source=f.prepared.acquire();try {assertEquals(44+144000L*8,source.open(DataSpec(output)));val bytes=ByteArray(51);assertEquals(44,source.read(bytes,0,51));assertEquals("RIFF",String(bytes,0,4));assertEquals(7,source.read(bytes,0,7))}finally{source.close()}}finally{f.prepared.close()};awaitClean(f)
 }
 @Test fun partitionedByteReadsAndEverySamplePreserveOverlapOrigins() {
  val f=fixture(listOf("stereo.mp3","mono.mp3"),1000)
  try {val source=f.prepared.acquire();source.open(DataSpec(output));val all=readAll(source);source.close()
   source.open(DataSpec(output));assertArrayEquals(all,readAll(source,intArrayOf(1,3,5,7,8,9,8191,17003)));source.close()
   val a=pcm("stereo.mp3");val b=pcm("mono.mp3");val out=ByteBuffer.wrap(all,44,all.size-44).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer();var max=0.0
   for(frame in 0 until 240000){val u=((frame-96000)/48000.0).coerceIn(0.0,1.0);repeat(2){ch->val expected=(if(frame<144000)a[frame*2+ch]*cos(u*PI/2)else 0.0)+(if(frame>=96000)b[(frame-96000)*2+ch]*sin(u*PI/2)else 0.0);max=maxOf(max,abs(out.get()-expected))}}
   assertTrue("Every sample max error $max",max<=.000001)
   for(at in listOf(0L,43L,44L,45L,51L,44+2048L*8-1,44+120000L*8+5,all.size-1L,all.size.toLong(),44L)){
    source.open(DataSpec(output,at,19));val got=readAll(source,intArrayOf(1,5,17));assertArrayEquals(all.copyOfRange(at.toInt(),minOf(all.size,at.toInt()+19)),got);source.close()
   }
   assertEquals(24,Media3ListeningLane.created.size)
  }finally{f.prepared.close()};awaitClean(f)
 }
 private fun pcm(name:String):FloatArray {val encoded=File(fixtures,name);val key=java.security.MessageDigest.getInstance("SHA-256").digest(encoded.readBytes()).joinToString(""){"%02x".format(it)};val floats=ByteBuffer.wrap(File(fixtures,"$key.f32").readBytes()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer();return FloatArray(floats.remaining()).also{floats.get(it)}}
 @Test fun duplicateRecordingsOwnDistinctCursorsAndReaderSupersession() {
  val f=fixture(listOf("stereo.mp3","stereo.mp3"),1000);try {val a=f.prepared.acquire();a.open(DataSpec(output));assertEquals(2,Media3ListeningLane.created.size);val b=f.prepared.acquire();b.open(DataSpec(output,44+120000L*8));assertEquals(4,Media3ListeningLane.created.size);rejected{a.read(ByteArray(1),0,1)};a.close();b.close()}finally{f.prepared.close()};awaitClean(f)
 }
 @Test fun heldReadCloseRevokesBeforeDrainAndNeverPublishes() {
  val f=fixture();val source=f.prepared.acquire();source.open(DataSpec(output,44+2048L*8));val held=CompletableFuture<ListeningMemoryOutput.Window?>();Media3ListeningLane.held=held;Media3ListeningLane.holdDrain=true;val entered=CountDownLatch(1);Media3ListeningLane.entered=entered
  val pool=Executors.newSingleThreadExecutor();val bytes=ByteArray(17){37};val read=pool.submit<Boolean>{try{source.read(bytes,0,bytes.size);false}catch(_:Throwable){true}}
  try {assertTrue(entered.await(2,TimeUnit.SECONDS));f.valid.set(false);f.prepared.close();assertTrue(Media3ListeningLane.created.all{it.retirementRequested});assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());assertEquals(0,f.graph.closes);held.completeExceptionally(IllegalStateException("source retired"));Media3ListeningLane.created.forEach{it.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0))};assertTrue(read.get(2,TimeUnit.SECONDS));assertTrue(bytes.all{it==37.toByte()})}finally{source.close();f.prepared.close();pool.shutdownNow()};awaitClean(f)
 }
 @Test fun pendingDrainPreventsNewDecoderUntilActualReceipt() {
  val f=fixture();val source=f.prepared.acquire();source.open(DataSpec(output));Media3ListeningLane.holdDrain=true;source.close();val old=Media3ListeningLane.created.single();val pool=Executors.newSingleThreadExecutor();val open=pool.submit<Long>{source.open(DataSpec(output,50))}
  try {Thread.sleep(60);assertFalse(open.isDone);assertEquals(1,Media3ListeningLane.created.size);assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());Media3ListeningLane.holdDrain=false;old.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));assertTrue(open.get(2,TimeUnit.SECONDS)>0);assertEquals(2,Media3ListeningLane.created.size)}finally{source.close();f.prepared.close();pool.shutdownNow()};awaitClean(f)
 }
 @Test fun exceptionalAndCancelledDrainsRetainFilesAndAcquisition() {
  for(cancel in listOf(false,true)){val f=fixture();val source=f.prepared.acquire();source.open(DataSpec(output));Media3ListeningLane.holdDrain=true;source.close();val old=Media3ListeningLane.created.single();if(cancel)old.drain.cancel(false)else old.drain.completeExceptionally(IllegalStateException("close failed"));rejected{source.open(DataSpec(output))};f.prepared.close();Thread.sleep(30);assertEquals(1,Media3ListeningLane.created.size);assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());assertEquals(0,f.graph.closes)}
 }
 @Test fun invalidationBeforePublicationAndMalformedRangesFailClosed() {
  val f=fixture();val source=f.prepared.acquire();try{rejected{source.open(DataSpec(output,-1))};source.open(DataSpec(output));rejected{source.read(ByteArray(4),Int.MAX_VALUE,4)};f.valid.set(false);val bytes=ByteArray(4){37};rejected{source.read(bytes,0,4)};assertTrue(bytes.all{it==37.toByte()})}finally{source.close();f.prepared.close()};awaitClean(f)
 }
 @Test fun opusRemainsNativeAndMixedCodecsFailExplicitly() {
  val f=fixture(listOf("fixture.opus"),duration=12000);try{val s=f.prepared.acquire();s.open(DataSpec(output));val all=readAll(s);s.close();s.open(DataSpec(output,45));assertArrayEquals(all.copyOfRange(45,all.size),readAll(s,intArrayOf(3,7,8192)));s.close();assertEquals(0,Media3ListeningLane.created.size)}finally{f.prepared.close()};awaitClean(f)
  try{fixture(listOf("fixture.opus","stereo.mp3"),duration=12000);fail("mixed must refuse")}catch(e:IllegalArgumentException){assertTrue(e.message!!.contains("Mixed MP3/Opus"))};assertEquals(0,Media3ListeningLane.created.size)
 }
 @Test fun unsupportedIncomingSourceRefusesBeforeReadiness() {
  var failure:Throwable?=null
  try{fixture(listOf("stereo.mp3","unsupported.bin"))}catch(t:Throwable){failure=t}
  assertNotNull("unsupported must refuse",failure);assertTrue(Media3ListeningLane.created.all{it.retirementRequested})
 }
 @Test fun supersededHeldReadCannotRetireReplacement() {
  val f=fixture();val a=f.prepared.acquire();a.open(DataSpec(output,44+4096L*8));val held=CompletableFuture<ListeningMemoryOutput.Window?>();Media3ListeningLane.held=held;Media3ListeningLane.entered=CountDownLatch(1);Media3ListeningLane.holdDrain=true
  val pool=Executors.newFixedThreadPool(2);val read=pool.submit<Boolean>{try{a.read(ByteArray(8),0,8);false}catch(_:Throwable){true}};assertTrue(Media3ListeningLane.entered!!.await(2,TimeUnit.SECONDS))
  val b=f.prepared.acquire();val reopen=pool.submit<Long>{b.open(DataSpec(output,44))}
  try {Thread.sleep(50);Media3ListeningLane.held=null;Media3ListeningLane.holdDrain=false;held.completeExceptionally(IllegalStateException("superseded"));Media3ListeningLane.created.first().drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));assertTrue(read.get(2,TimeUnit.SECONDS));assertTrue(reopen.get(2,TimeUnit.SECONDS)>0);assertEquals(8,b.read(ByteArray(8),0,8))}finally{a.close();b.close();f.prepared.close();pool.shutdownNow()};awaitClean(f)
 }
 @Test fun closingFacadeDuringRestartRevokesPendingOpen() {
  val f=fixture();val s=f.prepared.acquire();s.open(DataSpec(output));Media3ListeningLane.holdDrain=true;s.close();val pool=Executors.newSingleThreadExecutor();val opened=pool.submit<Boolean>{try{s.open(DataSpec(output));true}catch(_:Throwable){false}}
  try{Thread.sleep(60);assertFalse(opened.isDone);s.close();Media3ListeningLane.holdDrain=false;Media3ListeningLane.created.first().drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));assertFalse("closed pending facade cannot publish open",opened.get(2,TimeUnit.SECONDS));assertEquals(1,Media3ListeningLane.created.size)}finally{s.close();f.prepared.close();pool.shutdownNow()};awaitClean(f)
 }
 @Test fun drainReceiptMustActuallyHaveNoBorrowedIo() {
  val f=fixture();val s=f.prepared.acquire();s.open(DataSpec(output));Media3ListeningLane.holdDrain=true;s.close();Media3ListeningLane.created.first().drain.complete(Media3ListeningLane.DrainReceipt(1,1,1));rejected{s.open(DataSpec(output))};f.prepared.close();Thread.sleep(30);assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());assertEquals(0,f.graph.closes)
 }
 @Test fun completedDrainCannotBypassReceiptValidationWhileCallbackIsHeld() {
  val f=fixture();val s=f.prepared.acquire();s.open(DataSpec(output));Media3ListeningLane.holdDrain=true;s.close();val lane=Media3ListeningLane.created.first();val entered=CountDownLatch(1);val release=CountDownLatch(1);lane.drain.whenComplete{_,_->entered.countDown();check(release.await(2,TimeUnit.SECONDS))};val pool=Executors.newFixedThreadPool(2);val completion=pool.submit<Boolean>{lane.drain.complete(Media3ListeningLane.DrainReceipt(1,1,1))};assertTrue(entered.await(2,TimeUnit.SECONDS))
  val opened=pool.submit<Boolean>{try{s.open(DataSpec(output));true}catch(_:Throwable){false}}
  try{assertFalse("unvalidated concrete receipt cannot admit successor",opened.get(1,TimeUnit.SECONDS));assertEquals(1,Media3ListeningLane.created.size)}finally{release.countDown();completion.get(2,TimeUnit.SECONDS);s.close();f.prepared.close();pool.shutdownNow()}
 }
 @Test fun reopenTimeoutRetainsPredecessorUntilLateSuccessfulDrain() {
  val f=fixture();val s=f.prepared.acquire();s.open(DataSpec(output));Media3ListeningLane.holdDrain=true;s.close();val lane=Media3ListeningLane.created.single()
  try{try{s.open(DataSpec(output));fail("pending predecessor must time out")}catch(_:TimeoutException){};assertEquals(1,Media3ListeningLane.created.size);assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());assertEquals(0,f.graph.closes);lane.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0))}finally{s.close();f.prepared.close()};awaitClean(f)
 }
 @Test fun invalidationAfterSynchronousJniDiscardsPrivateBytesBeforePublication() {
  Media3ListeningLane.reset();val dir=java.nio.file.Files.createTempDirectory(java.nio.file.Path.of(System.getenv("TMPDIR")),"post-jni-").toFile();val uri=Uri.parse("soundq://track/7/post-jni");val graph=AppGraph(dir,mapOf(uri.toString() to File(fixtures,"stereo.mp3")));val valid=AtomicBoolean(true);val armed=AtomicBoolean(false);val calls=java.util.concurrent.atomic.AtomicInteger();val entered=CountDownLatch(1);val release=CountDownLatch(1)
  val prepared=PreparedListening.prepare(graph,ConcurrentHashMap<String,MediaGrant>(),listOf(MediaItem.Builder().setMediaId("a").setUri(uri).build()),ListeningSchedule.compile(listOf(TimelineSource("a",7,3000)),0)){
   // This block is read entirely from the retained primed cursor window. The five
   // PrivateListeningPcm.read validity fences end immediately after synchronous JNI.
   if(armed.get() && Thread.currentThread().stackTrace.any{it.className.endsWith("PrivateListeningPcm") && it.methodName=="read"} && calls.incrementAndGet()==5){entered.countDown();check(release.await(2,TimeUnit.SECONDS))};valid.get()
  }
  val source=prepared.acquire();source.open(DataSpec(output,44));armed.set(true);val pool=Executors.newSingleThreadExecutor();val bytes=ByteArray(8){37};val read=pool.submit<Boolean>{try{source.read(bytes,0,8);false}catch(_:Throwable){true}}
  try{assertTrue(entered.await(2,TimeUnit.SECONDS));valid.set(false);prepared.close();assertTrue(Media3ListeningLane.created.all{it.retirementRequested});assertTrue(dir.listFiles()!!.isNotEmpty());release.countDown();assertTrue(read.get(2,TimeUnit.SECONDS));assertTrue(bytes.all{it==37.toByte()})}finally{armed.set(false);release.countDown();source.close();prepared.close();pool.shutdownNow()};awaitClean(Fixture(graph,prepared,valid))
 }
 @Test fun rootCloseDuringLaneConstructionRetainsAcquisitionUntilOperationExit() {
  val f=fixture();val s=f.prepared.acquire();s.open(DataSpec(output));s.close();Media3ListeningLane.constructEntered=CountDownLatch(1);Media3ListeningLane.constructRelease=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor();val open=pool.submit<Boolean>{try{s.open(DataSpec(output));true}catch(_:Throwable){false}}
  try{assertTrue(Media3ListeningLane.constructEntered!!.await(2,TimeUnit.SECONDS));f.prepared.close();assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());assertEquals(0,f.graph.closes);Media3ListeningLane.constructRelease!!.countDown();assertFalse(open.get(2,TimeUnit.SECONDS));assertTrue(Media3ListeningLane.created.all{it.retirementRequested})}finally{Media3ListeningLane.constructRelease!!.countDown();s.close();f.prepared.close();pool.shutdownNow()};awaitClean(f)
 }
 @Test fun rootCloseDuringFinalEosDrainCannotPublishTail() {
  val f=fixture();val s=f.prepared.acquire();s.open(DataSpec(output,44+143999L*8));Media3ListeningLane.holdDrain=true;val pool=Executors.newSingleThreadExecutor();val bytes=ByteArray(8){37};val read=pool.submit<Boolean>{try{s.read(bytes,0,8);false}catch(_:Throwable){true}};val lane=Media3ListeningLane.created.single()
  try{val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(2);while(!lane.retirementRequested&&System.nanoTime()<deadline)Thread.sleep(1);assertTrue(lane.retirementRequested);f.prepared.close();assertTrue(f.graph.directory.listFiles()!!.isNotEmpty());lane.drain.complete(Media3ListeningLane.DrainReceipt(1,0,0));assertTrue(read.get(2,TimeUnit.SECONDS));assertTrue(bytes.all{it==37.toByte()})}finally{s.close();f.prepared.close();pool.shutdownNow()};awaitClean(f)
 }
 @Test fun repeatedCloseAfterSuccessfulCleanupCannotReacquireCustody() {
  val f=fixture();f.prepared.close();awaitClean(f);f.prepared.close();Thread.sleep(20)
  val field=PreparedListening::class.java.getDeclaredField("custodians").also{it.isAccessible=true};val owners=field.get(null) as Set<*>;assertFalse("disposed owner must not reenter retained custody",owners.contains(f.prepared))
 }
 @Test fun shortAndExcessExtentsAreNotPaddedOrCropped() {
  for(duration in listOf(2999L,3001L)){val f=fixture(duration=duration);val s=f.prepared.acquire();try{s.open(DataSpec(output));rejected{readAll(s)}}finally{s.close();f.prepared.close()};awaitClean(f)}
 }
}
