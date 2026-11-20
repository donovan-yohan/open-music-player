package com.soundq.android.playback.nativeengine

import android.content.ContextWrapper
import android.os.Bundle
import android.os.Looper
import androidx.media3.common.*
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import com.soundq.android.AppGraph
import com.soundq.android.SoundQApplication
import com.soundq.android.data.*
import com.soundq.android.playback.*
import com.soundq.android.playback.system.ServiceTransportPlayer
import kotlinx.coroutines.CoroutineScope
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.*
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/** Real ControllerProjection -> Media3 session admission -> default native Player.
 * Only encoded acquisition and native output are substitutes; no codec/PCM claim. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=QueueMutationApplication::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class NativeQueueMutationContinuityTest {
    private class Fixture:AutoCloseable {
        val app=RuntimeEnvironment.getApplication() as QueueMutationApplication
        val lifecycle=Robolectric.buildService(SoundQLibraryService::class.java).create()
        val service=lifecycle.get()
        fun field(name:String)=SoundQLibraryService::class.java.getDeclaredField(name).apply{isAccessible=true}
        val player=field("player").get(service) as NativeCallbackPlayer
        val transport=field("transport").get(service) as ServiceTransportPlayer
        val session=field("session").get(service) as MediaSession
        val projection=ControllerProjection(app,session.token)
        val hardware get()=app.hardware
        val tracks=(1L..3L).map {Track(TrackId(it),"Fixture $it","Fixture",durationMs=6000)}
        fun nativeField(name:String)=NativeCallbackPlayer::class.java.getDeclaredField(name).apply{isAccessible=true}
        val controller get()=ControllerProjection::class.java.getDeclaredField("controller").apply{isAccessible=true}.get(projection) as MediaController
        init {
            app.graph.rememberTracks(tracks)
            drain{field("account").get(service)!=null&&projection.state.value.connection==PlaybackProjection.Connection.Connected}
            projection.playContext(tracks.take(1),0,localOnly=true)
            drain{player.isPlaying&&player.preparationSettled}
            hardware.position(slot(),1700);drain{player.currentPosition==1700L}
        }
        fun slot()=nativeField("ordinaryDeck").getInt(player)
        fun rows()=(0 until player.mediaItemCount).map(player::getMediaItemAt)
        fun drain(predicate:()->Boolean) {
            val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
            while(true) {
                val owner=nativeField("owner").get(player)
                val thread=owner.javaClass.getDeclaredField("thread").apply{isAccessible=true}.get(owner) as android.os.HandlerThread
                Shadows.shadowOf(thread.looper).idleFor(java.time.Duration.ofMillis(50))
                Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(50))
                if(predicate())return
                check(System.nanoTime()<end){"Queue mutation deadline: ${player.nativeDiagnostics()}"}
                Thread.sleep(2)
            }
        }
        data class Selection(val item:MediaItem,val slot:Int,val deck:QueueMutationHardware.Deck,val epoch:Long,val grant:Any,val requests:Int,val calls:Int)
        fun capture():Selection {
            val item=player.currentMediaItem!!
            return Selection(item,slot(),hardware.deck(slot()),nativeField("epoch").getLong(player),nativeField("activeGrant").get(player)!!,app.requests.count{it==item.mediaId},hardware.calls.size)
        }
        fun retained(before:Selection,playing:Boolean=true) {
            assertEquals(before.item.mediaId,player.currentMediaItem!!.mediaId)
            assertEquals(before.item.localConfiguration,player.currentMediaItem!!.localConfiguration)
            assertEquals(before.epoch,nativeField("epoch").getLong(player))
            assertSame(before.grant,nativeField("activeGrant").get(player))
            val after=hardware.deck(before.slot)
            assertEquals(before.deck.id,after.id);assertEquals(before.deck.generation,after.generation)
            assertEquals(before.deck.position,after.position)
            assertEquals(before.requests,app.requests.count{it==before.item.mediaId})
            assertEquals(playing,player.playWhenReady);assertEquals(playing,after.playing)
            assertEquals(Player.STATE_READY,player.playbackState)
            assertTrue("Retained deck must not be played, paused, sought or unloaded by queue edit",hardware.calls.drop(before.calls).none{it.slot==before.slot&&it.operation in setOf(1,2,3,8)})
        }
        fun enqueue(track:Int,next:Boolean=false) {projection.enqueue(tracks[track],next,localOnly=true)}
        override fun close() {
            projection.close();lifecycle.destroy()
            drain{player.nativeReleased.isDone}
            assertTrue(player.nativeReleased.get())
            assertTrue(app.files.none{it.exists()})
            app.graph.close();assertTrue(app.root.deleteRecursively())
        }
    }

    @Test fun appendPlayNextAndReorderThroughControllerRetainPlayingSourceAndUndo() {
        Fixture().use {f->
            var before=f.capture();f.enqueue(1);f.drain{f.player.mediaItemCount==2&&f.player.preparationSettled};f.retained(before)
            @Suppress("UNCHECKED_CAST") val undo=f.field("undo").get(f.service) as List<MediaItem>
            assertEquals(listOf(before.item.mediaId),undo.map{it.mediaId});assertEquals(1700L,f.field("undoPosition").getLong(f.service))
            before=f.capture();f.enqueue(2,next=true);f.drain{f.player.mediaItemCount==3&&f.player.preparationSettled};f.retained(before)
            assertEquals(listOf(1L,3L,2L),f.rows().map{it.mediaMetadata.extras!!.getLong("trackId")})
            val moved=f.player.getMediaItemAt(2).mediaId
            before=f.capture();f.projection.moveTo(moved,1);f.drain{f.player.getMediaItemAt(1).mediaId==moved&&f.player.preparationSettled};f.retained(before)
            f.hardware.position(f.slot(),1800);f.drain{f.player.currentPosition==1800L};assertTrue(f.player.isPlaying)
        }
    }

    @Test fun pausedQueueEditsNeverPlayIncludingAfterDeferredPlayThenPause() {
        Fixture().use {f->
            f.controller.play();f.controller.pause();f.enqueue(1)
            // Positive timeline commit proves the preceding controller FIFO was consumed.
            f.drain{f.player.mediaItemCount==2&&!f.player.playWhenReady&&f.player.preparationSettled}
            val before=f.capture();f.enqueue(2,next=true);f.drain{f.player.mediaItemCount==3&&f.player.preparationSettled};f.retained(before,playing=false)
        }
    }

    @Test fun explicitReplacementStillPausesBeforeNewSelectionAndDoesNotAutoplay() {
        Fixture().use {f->
            val old=f.player.currentMediaItem!!.mediaId
            val request=MediaItem.Builder().setMediaId("2").setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply{putBoolean("localOnly",true)}).build()).build()
            f.controller.setMediaItems(listOf(request),0,0)
            f.drain{f.player.currentMediaItem?.mediaId!=old&&f.player.preparationSettled}
            assertFalse(f.player.playWhenReady);assertFalse(f.player.isPlaying)
            assertEquals(2L,f.player.currentMediaItem!!.mediaMetadata.extras!!.getLong("trackId"))
            assertTrue(f.hardware.calls.any{it.operation==2})
        }
    }

    @Test fun queueEditRetiresPendingReadAndItsCapturedPlayWithoutInstallingLateRows() {
        Fixture().use {f->
            val read=f.transport.begin{true};f.transport.prepare();f.transport.play()
            assertTrue(f.transport.resolving)
            f.enqueue(1);f.drain{f.player.mediaItemCount==2&&f.player.preparationSettled}
            assertFalse(f.transport.resolving)
            val before=f.capture()
            f.transport.complete(read,listOf(f.player.getMediaItemAt(1)),0,0)
            assertEquals(2,f.player.mediaItemCount);f.retained(before,playing=false)
        }
    }

    @Test fun acceptedUndoStillRestoresExactOccurrenceAndCursorPaused() {
        Fixture().use {f->
            val old=f.player.currentMediaItem!!.mediaId
            f.enqueue(1);f.drain{f.player.mediaItemCount==2}
            val result=f.controller.sendCustomCommand(androidx.media3.session.SessionCommand(SoundQLibraryService.UNDO,Bundle.EMPTY),Bundle.EMPTY)
            f.drain{result.isDone&&f.player.mediaItemCount==1&&f.player.preparationSettled}
            assertEquals(0,result.get().resultCode);assertEquals(old,f.player.currentMediaItem!!.mediaId)
            assertEquals(1700L,f.player.currentPosition);assertFalse(f.player.playWhenReady)
        }
    }

    @Test fun enabledCrossfadeAndNearEofEditsRetireOnlyOptionalOtherDeck() {
        Fixture().use {f->
            val prefs=f.app.graph.crossfadePreferences
            assertTrue(prefs.setSeconds(prefs.capture()!!,2){true})
            f.enqueue(1);f.drain{f.player.mediaItemCount==2&&f.hardware.crossfades.any{it>0}&&f.player.preparationSettled}
            val before=f.capture()
            f.hardware.position(before.slot,5999);f.drain{f.player.currentPosition==5999L}
            val nearEnd=f.capture()
            f.enqueue(2,next=true);f.drain{f.player.mediaItemCount==3&&f.player.preparationSettled&&f.hardware.crossfades.count{it>0}>=2}
            f.retained(nearEnd)
            assertTrue("Optional incoming was actually retired",f.hardware.calls.drop(before.calls).any{it.slot!=before.slot&&it.operation==8})
        }
    }
}

/** One deterministic native-call boundary, not a second playback owner. */
internal class QueueMutationHardware:NativeCallbackCalls {
    data class Deck(var id:Long=0,var generation:Long=0,var position:Long=0,var playing:Boolean=false,var gain:Double=1.0)
    data class Call(val operation:Int,val slot:Int)
    private val decks=Array(4){Deck()}
    val calls=CopyOnWriteArrayList<Call>();val crossfades=CopyOnWriteArrayList<Long>()
    @Synchronized fun deck(slot:Int)=decks[slot].copy()
    @Synchronized fun position(slot:Int,ms:Long){decks[slot].position=ms}
    override fun open()=1L
    override fun recoverOutput(handle: Long): NativeOutputRecovery {
        calls.add(Call(9, 0))
        return NativeOutputRecovery.Healthy
    }
    @Synchronized override fun load(handle:Long,deck:Int,path:String,identity:Long,generation:Long,positionMs:Long):Boolean {
        check(decks[deck].id==0L);decks[deck]=Deck(identity,generation,positionMs);return true
    }
    @Synchronized override fun control(handle:Long,operation:Int,deck:Int,value:Double,eventNanos:Long):Boolean {
        calls.add(Call(operation,deck));val d=decks[deck]
        when(operation){1->d.playing=true;2->d.playing=false;3->d.position=value.toLong();8->decks[deck]=Deck()}
        return true
    }
    @Synchronized override fun crossfade(handle:Long,outgoing:Int,outgoingGeneration:Long,incoming:Int,incomingGeneration:Long,milliseconds:Long):Boolean {
        check(decks[outgoing].generation==outgoingGeneration&&decks[incoming].generation==incomingGeneration)
        crossfades.add(milliseconds);decks[outgoing].gain=1.0
        if(milliseconds==0L)decks[incoming].playing=false else decks[incoming].gain=0.0
        return true
    }
    @Synchronized override fun state(handle:Long)=JSONObject().put("error",0).put("sampleRate",48000).put("decks",JSONArray().apply {
        decks.forEach {d->put(JSONObject().put("identity",d.id).put("generation",d.generation).put("positionMs",d.position).put("durationMs",6000)
            .put("sourceRate",48000).put("sourceFrames",288000).put("ready",d.id!=0L).put("preparing",false).put("playing",d.playing)
            .put("boundaryGain",d.gain).put("eofCount",0).put("openDecoders",if(d.id==0L)0 else 1).put("error",0))}
    }).toString()
    @Synchronized override fun close(handle:Long):Boolean {decks.indices.forEach{decks[it]=Deck()};return true}
}

internal class QueueMutationApplication:SoundQApplication() {
    lateinit var root:File
    val hardware=QueueMutationHardware();val files=CopyOnWriteArrayList<File>();val requests=CopyOnWriteArrayList<String>()
    override fun onCreate() {
        root=java.nio.file.Files.createTempDirectory(File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"queue-mutation-").toFile()
        graph=AppGraph(object:ContextWrapper(this){override fun getNoBackupFilesDir()=root},ApiEndpoint.parse("https://fixture.invalid/api/v1"),store=object:SessionStore {
            override fun load(endpoint:ApiEndpoint):SecretTokens?=null
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
            override fun clear(){}
        })
        check(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture","fixture","fixture")))
        graph.crossfadePreferences.load();check(graph.crossfadePreferences.setSeconds(graph.crossfadePreferences.capture()!!,0){true})
    }
    override fun createCallbackLibraryPlayer(grants:ConcurrentHashMap<String,MediaGrant>,jobs:CoroutineScope):Player =
        NativeCallbackPlayer(graph,grants,jobs,hardware,NativeCallbackSource {item,current->
            check(current());requests.add(item.mediaId)
            File.createTempFile("queue-", ".encoded",graph.directory).apply {writeBytes(byteArrayOf(1,2,3));files.add(this)}
        })
}
