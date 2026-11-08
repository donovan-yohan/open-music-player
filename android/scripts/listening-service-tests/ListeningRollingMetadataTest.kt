package com.soundq.android.playback.listening

import android.os.Bundle
import androidx.media3.common.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningRollingMetadataTest {
 @Test fun completeFixedRowsRetainOriginsAndAtomicFiniteExtentAdmission() {
  ServiceProbe(rolling=true).use {h->
   val rows=(0 until 500).map{i->h.items[i%2].buildUpon().setMediaId("rolling-$i").setMediaMetadata(h.items[i%2].mediaMetadata.buildUpon().setExtras(Bundle(h.items[i%2].mediaMetadata.extras).apply{putLong("durationMs",1);putString("origin",if(i==4)"Continuation" else if(i%2==1)"Manual" else "Context")}).build()).build()}
   h.player.setMediaItems(rows,4,0)
   assertEquals(500,h.player.mediaItemCount);assertEquals("Continuation",h.player.getMediaItemAt(4).mediaMetadata.extras!!.getString("origin"));assertEquals(0,h.requestCount);assertEquals(0,h.privateFiles())
   val selected=h.player.currentMediaItem
   for(bad in listOf(rows+rows[0].buildUpon().setMediaId("501").build(),rows.take(3).map{it.buildUpon().setMediaMetadata(it.mediaMetadata.buildUpon().setExtras(Bundle(it.mediaMetadata.extras).apply{putLong("durationMs",604800000)}).build()).build()})){
    try{h.player.setMediaItems(bad);fail("must reject atomically")}catch(_:IllegalArgumentException){}
    assertEquals(selected,h.player.currentMediaItem);assertEquals(500,h.player.mediaItemCount);assertEquals(0,h.requestCount)
   }
   h.player.setMediaItems(rows.take(5),0,0);h.player.seekToNextMediaItem();assertEquals(1,h.player.currentMediaItemIndex);h.player.seekToPreviousMediaItem();assertEquals(0,h.player.currentMediaItemIndex)
   h.player.repeatMode=Player.REPEAT_MODE_ALL;h.player.seekTo(4,0);h.player.seekToNextMediaItem();assertEquals(0,h.player.currentMediaItemIndex)
   h.player.repeatMode=Player.REPEAT_MODE_ONE;h.player.seekTo(4,0);h.player.seekToNextMediaItem();assertEquals(4,h.player.currentMediaItemIndex)
   h.player.play();try{h.player.addMediaItems(rows.take(1));fail("on-air edits remain unsupported")}catch(_:IllegalArgumentException){}
   assertFalse(h.player.availableCommands.contains(Player.COMMAND_SET_SHUFFLE_MODE))
  }
 }
}
