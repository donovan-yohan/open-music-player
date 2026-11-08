package com.soundq.android

import android.os.Bundle
import androidx.lifecycle.ViewModelStore
import androidx.media3.common.*
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.*
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.playback.SoundQLibraryService
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Test

/** Native counterparts of the retained exact-source host scheduling probes. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class OwnershipAdmissionTest {
    @Test fun logoutReturnsWithScopeRevokedBeforeRetainedLibraryPlay() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as SoundQApplication
        val graph=app.graph
        assertTrue(graph.api.authenticate("synthetic@example.test","test-only-password"))
        graph.library.refine(LibraryQuery());val rows=graph.library.state.value.rows;val scope=graph.session.capture()!!
        instrumentation.runOnMainSync {
            val model=ProductViewModel(app);val models=ViewModelStore();models.put("ownership",model)
            try {
                synchronized(graph.session) {
                    model.logout();model.play(0,rows)
                    assertFalse(graph.session.current(scope));assertNull(graph.session.capture())
                    assertTrue(graph.session.state.value is AuthState.SignedOut)
                }
            } finally {models.clear()}
        }
    }
    @Test fun actualServiceCallbacksBindUndoBeforeCollectorAndPreserveOccurrences() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val graph=(context.applicationContext as SoundQApplication).graph
        instrumentation.runOnMainSync {
            for(replace in listOf(false,true)) {
                graph.session.accept(graph.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh","A"))
                val scope=graph.session.capture()!!;val service=SoundQLibraryService()
                val output=ExoPlayer.Builder(context).build()
                val player=com.soundq.android.playback.ServiceQueuePlayer(output)
                val session=MediaLibrarySession.Builder(context,player,object:MediaLibrarySession.Callback{}).build()
                fun field(name:String)=SoundQLibraryService::class.java.getDeclaredField(name).apply {isAccessible=true}
                try {
                    field("graph").set(service,graph);field("player").set(service,player);field("account").set(service,scope)
                    val attach=android.content.ContextWrapper::class.java.getDeclaredMethod("attachBaseContext",android.content.Context::class.java).apply{isAccessible=true}
                    attach.invoke(service,context)
                    val jobs=field("jobs").get(service) as kotlinx.coroutines.CoroutineScope
                    val transport=com.soundq.android.playback.system.ServiceTransportPlayer(player){graph.session.current(scope)}
                    val continuation=com.soundq.android.playback.ServiceLibraryContinuation(player,transport,graph,jobs){_,_->error("No continuation in callback probe")}
                    val interruptions=com.soundq.android.playback.system.SystemAudioInterruption(context,player,{graph.session.current(scope)},{transport.retire()})
                    field("transport").set(service,transport);field("continuation").set(service,continuation);field("interruptions").set(service,interruptions)
                    field("session").set(service,session)
                    val items=(1..2).map {i->MediaItem.Builder().setMediaId("occ-$i").setUri("soundq://track/7/occ-$i")
                        .setMediaMetadata(MediaMetadata.Builder().setTitle("A metadata $i").setExtras(Bundle().apply{putLong("trackId",7)}).build()).build()}
                    player.setMediaItems(items,1,1200)
                    val type=Class.forName("com.soundq.android.playback.SoundQLibraryService\$Callback")
                    val callback=type.getDeclaredConstructor(SoundQLibraryService::class.java).apply{isAccessible=true}.newInstance(service) as MediaLibrarySession.Callback
                    val constructor=MediaSession.ControllerInfo::class.java.declaredConstructors.single{it.parameterCount==8}.apply{isAccessible=true}
                    val remote=constructor.parameterTypes[0].getConstructor(String::class.java,Int::class.javaPrimitiveType,Int::class.javaPrimitiveType).newInstance(context.packageName,android.os.Process.myPid(),context.applicationInfo.uid)
                    val controller=constructor.newInstance(remote,1,1,true,null,Bundle.EMPTY,0,true) as MediaSession.ControllerInfo
                    assertEquals(SessionResult.RESULT_SUCCESS,callback.onPlayerCommandRequest(session,controller,Player.COMMAND_CHANGE_MEDIA_ITEMS))
                    player.clearMediaItems()
                    if(replace)graph.session.accept(graph.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh","B"))
                    val result=callback.onCustomCommand(session,controller,SessionCommand(SoundQLibraryService.UNDO,Bundle.EMPTY),Bundle.EMPTY).get()
                    if(replace) {
                        assertEquals(SessionError.ERROR_PERMISSION_DENIED,result.resultCode);assertEquals(0,player.mediaItemCount)
                        assertTrue((field("grants").get(service) as Map<*,*>).isEmpty())
                    } else {
                        assertEquals(SessionResult.RESULT_SUCCESS,result.resultCode);assertFalse(player.playWhenReady)
                        assertEquals(2,player.mediaItemCount);assertEquals("occ-1",player.getMediaItemAt(0).mediaId);assertEquals("occ-2",player.getMediaItemAt(1).mediaId)
                        assertEquals("A metadata 2",player.getMediaItemAt(1).mediaMetadata.title);assertEquals(1,player.currentMediaItemIndex)
                    }
                } finally {
                    (field("continuation").get(service) as? com.soundq.android.playback.ServiceLibraryContinuation)?.close()
                    (field("interruptions").get(service) as? com.soundq.android.playback.system.SystemAudioInterruption)?.close()
                    (field("jobs").get(service) as kotlinx.coroutines.CoroutineScope).coroutineContext[kotlinx.coroutines.Job]!!.cancel()
                    session.release();player.release()
                }
            }
        }
    }
}
