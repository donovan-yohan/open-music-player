package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.datasource.DataSpec
import com.soundq.android.AppGraph
import com.soundq.android.data.timeline.TimelineSource
import com.soundq.android.playback.MediaGrant
import com.soundq.android.playback.SignedAudioDataSource
import java.io.File
import java.io.IOException
import java.util.concurrent.*
import org.junit.Assert.*
import org.junit.Test

class RollingAcquisitionCloseTest {
 private val output=Uri.parse("soundqlistening://close-failure")
 private fun graph():AppGraph {
  val dir=java.nio.file.Files.createTempDirectory(java.nio.file.Path.of(System.getenv("TMPDIR")),"rolling-one-shot-").toFile()
  return AppGraph(dir,mapOf("soundq://track/7/a" to File(requireNotNull(System.getProperty("soundq.prepared.fixture")),"stereo.mp3")))
 }
 private fun barrier(type:Class<*>) {
  val field=type.getDeclaredField("cleanup").also{it.isAccessible=true}
  (field.get(null) as ExecutorService).submit{}.get(3,TimeUnit.SECONDS)
 }
 @Test fun oneShotFacadeClearsHandleInFinallyAndSecondCloseIsNotAReceipt() {
  val graph=graph();val first=IOException("one-shot acquisition close");graph.oneShotCloseFailure=first
  val source=SignedAudioDataSource(graph,ConcurrentHashMap<String,MediaGrant>())
  source.open(DataSpec(Uri.parse("soundq://track/7/a")))
  try{source.close();fail("first close must fail")}catch(t:IOException){assertSame(first,t)}
  source.close();assertEquals(2,graph.closeAttempts);assertEquals(1,graph.closeNoops);assertEquals(0,graph.closes);assertSame(first,graph.closeFailures.single())
 }
 @Test fun oneShotAcquisitionCloseRetainsOriginalFailureFileCapacityAndReleaseBarrier() {
  Media3ListeningLane.reset()
  val graph=graph();val first=IOException("one-shot acquisition close");graph.oneShotCloseFailure=first
  val item=MediaItem.Builder().setMediaId("a").setUri(Uri.parse("soundq://track/7/a")).build()
  val prepared=PreparedListening.prepareRolling(graph,ConcurrentHashMap<String,MediaGrant>(),listOf(item),ListeningSchedule.compile(listOf(TimelineSource("a",7,3000)),0)){true}
  val field=PreparedListening::class.java.getDeclaredField("pcm").also{it.isAccessible=true}
  val generation=field.get(prepared) as ListeningPcmGeneration
  val source=prepared.acquire();source.open(DataSpec(output,44))
  val bytes=ByteArray(12){37}
  try{source.read(bytes,2,8);fail("acquisition close must refuse PCM")}catch(t:IOException){assertSame(first,t)}
  assertTrue(bytes.all{it==37.toByte()});source.close();prepared.close()
  // The actual cleanup executors have passed the submitted work. No timing guess.
  barrier(RollingListeningPcm::class.java);barrier(PreparedListening::class.java)
  val file=graph.directory.listFiles()!!.singleOrNull()
  val snapshot=prepared.residency()!!
  println("ONE_SHOT_CUSTODY dir=${graph.directory} slots=${snapshot.slots} reserved=${snapshot.reservedBytes} actual=${snapshot.actualBytes} released=${prepared.released.isDone} drainExceptional=${generation.drained.isCompletedExceptionally} closeAttempts=${graph.closeAttempts} noops=${graph.closeNoops}")
  assertEquals("failed acquisition must retain its slot",1,snapshot.slots)
  assertNotNull("failed acquisition must retain its encoded file",file)
  val expected=graph.inputs.values.single().length()
  assertEquals(expected,file!!.length());assertEquals(expected,snapshot.reservedBytes);assertEquals(expected,snapshot.actualBytes)
  assertTrue(generation.drained.isCompletedExceptionally)
  try{generation.drained.get(1,TimeUnit.SECONDS);fail("failed custody cannot drain successfully")}catch(t:ExecutionException){assertSame(first,t.cause)}
  assertFalse("failed root cannot release",prepared.released.isDone)
  repeat(3){source.close();prepared.close()}
  barrier(RollingListeningPcm::class.java);barrier(PreparedListening::class.java)
  assertEquals(snapshot,prepared.residency());assertTrue(file.exists());assertFalse(prepared.released.isDone)
  try{source.open(DataSpec(output,44));fail("no successor decoder generation")}catch(_:IllegalStateException){}
  try{prepared.acquire();fail("no fresh root reader")}catch(_:IllegalStateException){}
  assertEquals(1,graph.opens.size);assertEquals(0,Media3ListeningLane.created.size);assertSame(first,graph.closeFailures.single())
  // Retain the failed source as a real strong custodian, including file and byte charges.
  val custodians=PreparedListening::class.java.getDeclaredField("custodians").also{it.isAccessible=true}.get(null) as Set<*>
  assertTrue(custodians.contains(prepared))
 }
}
