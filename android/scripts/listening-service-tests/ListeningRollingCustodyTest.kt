package com.soundq.android.playback.listening

import androidx.media3.common.Player
import java.io.IOException
import java.util.concurrent.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Composition control for the existing release barrier, not the acquisition fault reproduction. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningRollingCustodyTest {
 private fun field(type:Class<*>,name:String)=type.getDeclaredField(name).also{it.isAccessible=true}
 private fun barrier(type:Class<*>)=(field(type,"cleanup").get(null) as ExecutorService).submit{}.get(3,TimeUnit.SECONDS)
 @Test fun stopPrepareCannotPassAConcreteFailedRollingCustodian() {
  ServiceProbe(rolling=true).use{h->
   h.install();h.ready();h.player.pause()
   val player=h.player as ListeningServicePlayer
   val prepared=field(ListeningServicePlayer::class.java,"prepared").get(player) as PreparedListening
   val root=field(PreparedListening::class.java,"rolling").get(prepared) as RollingListeningRoot
   val generation=field(PreparedListening::class.java,"pcm").get(prepared) as RollingListeningPcm
   // Seed the exact sticky failed-slot boundary produced by the host one-shot regression.
   val failure=IOException("retained acquisition close custody")
   val slot=root.reserve(root.schedule.occurrences.first());slot.failure=failure
   @Suppress("UNCHECKED_CAST") val slots=field(RollingListeningPcm::class.java,"slots").get(generation) as MutableMap<String,RollingListeningRoot.Slot>
   slots[slot.occurrence.source.occurrence]=slot
   h.player.stop();barrier(RollingListeningPcm::class.java);barrier(PreparedListening::class.java)
   try{generation.drained.get(1,TimeUnit.SECONDS);fail("failed custodian cannot drain")}catch(t:ExecutionException){assertSame(failure,t.cause)}
   assertFalse(prepared.released.isDone);assertEquals(1,root.snapshot().slots)
   repeat(2){prepared.close()};h.player.prepare()
   // Positive owner task completion after the real 15-second release deadline, not a sleep guess.
   h.settle{!player.preparationSettled}
   val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(20)
   while(!player.preparationSettled && System.nanoTime()<deadline){org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();Thread.yield()}
   assertTrue(player.preparationSettled);assertNotNull(h.player.playerError)
   assertNull(field(ListeningServicePlayer::class.java,"prepared").get(player))
   assertSame(prepared,(field(ListeningServicePlayer::class.java,"retiredRenders").get(player) as List<*>).single())
   assertFalse(prepared.released.isDone);assertEquals(1,root.snapshot().slots);assertEquals(0,h.requestCount)
   assertFalse(h.player.playWhenReady);assertEquals(Player.STATE_IDLE,h.player.playbackState)
  }
 }
}
