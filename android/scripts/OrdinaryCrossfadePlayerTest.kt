package com.soundq.android.playback.nativeengine

import android.content.ContextWrapper
import android.net.Uri
import android.os.Bundle
import android.os.Looper
import androidx.media3.common.*
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.playback.MediaGrant
import kotlinx.coroutines.*
import org.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.*
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.*

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class OrdinaryCrossfadePlayerTest {
    /** Hardware state is explicitly supplied; this fixture never claims PCM mixing. */
    internal class Hardware:NativeCallbackCalls {
        data class Deck(var id:Long=0,var gen:Long=0,var pos:Long=0,var play:Boolean=false,var gain:Double=1.0,var eof:Long=0,var retiring:Boolean=false,var error:Int=0)
        val d=Array(4){Deck()};val pairs=CopyOnWriteArrayList<List<Long>>();val loads=CopyOnWriteArrayList<Int>()
        @Volatile var allowRetire=true
        @Volatile var failIncoming=false
        @Volatile var refuseIncomingLoad=false
        @Volatile var replayState:String?=null
        @Volatile var replays=0
        @Volatile var observations=0
        @Synchronized override fun open()=1L
        @Synchronized override fun load(handle:Long,deck:Int,path:String,identity:Long,generation:Long,positionMs:Long):Boolean {
            check(d[deck].id==0L);loads.add(deck)
            if(deck==1&&refuseIncomingLoad)return false
            d[deck]=Deck(identity,generation,positionMs,error=if(deck==1&&failIncoming)7 else 0);return true
        }
        @Synchronized override fun control(handle:Long,operation:Int,deck:Int,value:Double,eventNanos:Long):Boolean {
            val slot=d[deck]
            when(operation){1->d.filter{it.id!=0L&&!it.retiring}.forEach{it.play=true};2->d.forEach{it.play=false};3->slot.pos=value.toLong();8->{slot.retiring=true;if(allowRetire)d[deck]=Deck(gen=slot.gen)}}
            return true
        }
        @Synchronized override fun crossfade(handle:Long,outgoing:Int,outgoingGeneration:Long,incoming:Int,incomingGeneration:Long,milliseconds:Long):Boolean {
            check(d[outgoing].gen==outgoingGeneration&&d[incoming].gen==incomingGeneration)
            pairs.add(listOf(outgoing.toLong(),incoming.toLong(),milliseconds))
            if(milliseconds==0L){d[incoming].play=false;d[outgoing].gain=1.0}else {d[outgoing].gain=1.0;d[incoming].gain=0.0}
            return true
        }
        @Synchronized fun sample(outPosition:Long,inPosition:Long,outGain:Double,inGain:Double,eof:Boolean=false) {
            d[0].pos=outPosition;d[1].pos=inPosition;d[0].gain=outGain;d[1].gain=inGain;d[0].play=!eof;d[1].play=true;if(eof)d[0].eof++
        }
        @Synchronized override fun state(handle:Long):String {
            observations++
            replayState?.let{replayState=null;replays++;return it}
            if(allowRetire)d.indices.filter{d[it].retiring}.forEach{d[it]=Deck(gen=d[it].gen)}
            return JSONObject().put("error",0).put("sampleRate",48000).put("decks",JSONArray().apply{d.forEach{v->put(JSONObject().put("identity",v.id).put("generation",v.gen).put("positionMs",v.pos).put("durationMs",6000).put("sourceRate",48000).put("sourceFrames",288000).put("ready",v.id!=0L&&!v.retiring&&v.error==0).put("preparing",false).put("playing",v.play).put("boundaryGain",v.gain).put("eofCount",v.eof).put("openDecoders",if(v.id!=0L)1 else 0).put("error",v.error))}}).toString()
        }
        @Synchronized override fun close(handle:Long):Boolean {d.indices.forEach{d[it]=Deck()};return true}
    }
    private class Fixture(val count:Int=3,val seconds:Int=2):AutoCloseable {
        val root=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")!!).toPath(),"ordinary-crossfade-").toFile()
        val graph=AppGraph(object:ContextWrapper(RuntimeEnvironment.getApplication()){override fun getNoBackupFilesDir()=root},ApiEndpoint.parse("https://fixture.invalid/api/v1"),store=object:SessionStore{
            override fun load(endpoint:ApiEndpoint):SecretTokens?=null
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
            override fun clear(){}
        })
        val hardware=Hardware();val grants=ConcurrentHashMap<String,MediaGrant>();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        val files=CopyOnWriteArrayList<File>();val requests=CopyOnWriteArrayList<String>()
        @Volatile var holdIncoming=false
        @Volatile var failIncomingAcquisition=false
        val entered=CountDownLatch(1);val permit=CountDownLatch(1)
        val player:NativeCallbackPlayer
        val items:List<MediaItem>
        init {
            check(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture","fixture","fixture")))
            graph.crossfadePreferences.load();check(graph.crossfadePreferences.setSeconds(graph.crossfadePreferences.capture()!!,seconds){true})
            items=listOf("a-first","b","a-second").take(count).map {id->val uri=Uri.parse("soundq://track/7/$id");grants[uri.toString()]=MediaGrant(graph.session.capture()!!,TrackId(7));MediaItem.Builder().setMediaId(id).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setExtras(Bundle().apply{putLong("trackId",7);putLong("durationMs",6000)}).build()).build()}
            player=NativeCallbackPlayer(graph,grants,jobs,hardware,NativeCallbackSource{item,current->
                requests.add(item.mediaId)
                if(holdIncoming&&item.mediaId=="b"){entered.countDown();check(permit.await(10,TimeUnit.SECONDS))}
                check(!(failIncomingAcquisition&&item.mediaId=="b")){"controlled acquisition failure"}
                check(current());File.createTempFile(item.mediaId.padEnd(3,'_'),".encoded",root).apply{writeBytes(byteArrayOf(1,2,3));files.add(this)}
            })
            player.setMediaItems(items)
        }
        fun drain(predicate:()->Boolean) {
            val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(8)
            while(true){
                val owner=NativeCallbackPlayer::class.java.getDeclaredField("owner").apply{isAccessible=true}.get(player)
                val thread=owner.javaClass.getDeclaredField("thread").apply{isAccessible=true}.get(owner) as android.os.HandlerThread
                Shadows.shadowOf(thread.looper).idleFor(java.time.Duration.ofMillis(50));Shadows.shadowOf(Looper.getMainLooper()).idle()
                if(predicate())return;check(System.nanoTime()<end){"Player deadline: ${player.nativeDiagnostics()} requests=$requests"};Thread.sleep(5)
            }
        }
        fun armed(){player.prepare();drain{hardware.pairs.any{it[2]>0}&&player.preparationSettled}}
        fun poll(count:Int=40){val start=hardware.observations;drain{hardware.observations>=start+count}}
        override fun close(){permit.countDown();hardware.allowRetire=true;player.release();drain{player.nativeReleased.isDone};assertTrue(player.nativeReleased.get());assertTrue(files.none{it.exists()});jobs.cancel();graph.close();root.deleteRecursively()}
    }
    @Test fun gainDominanceCompletionAndHeldDecoderRetirement() {
        Fixture().use {f->
            val completed=CopyOnWriteArrayList<String>();f.player.addCompletionListener{completed.add(it.mediaId)}
            f.armed();assertFalse(f.player.playWhenReady);assertFalse(f.player.isPlaying)
            assertEquals(listOf("a-first","b"),f.requests.toList());assertEquals(listOf(0,1),f.hardware.loads.toList())
            f.player.play();f.drain{f.player.isPlaying}
            f.hardware.sample(4500,500,.9,.4);f.drain{f.player.currentPosition==4500L};assertEquals("a-first",f.player.currentMediaItem!!.mediaId)
            f.hardware.sample(5000,1000,.707,.707);f.drain{f.player.currentMediaItem!!.mediaId=="b"}
            assertEquals(1000L,f.player.currentPosition);assertEquals(6000L,f.player.duration);assertTrue(completed.isEmpty())
            f.hardware.allowRetire=false;f.hardware.sample(6000,2000,0.0,1.0,true)
            f.drain{completed.size==1};assertEquals(listOf("a-first"),completed.toList());assertTrue(f.files[0].exists());assertTrue(f.files[1].exists())
            f.hardware.allowRetire=true;f.drain{!f.files[0].exists()&&f.requests.size==3&&f.player.preparationSettled}
            assertEquals("b",f.player.currentMediaItem!!.mediaId);assertTrue(f.files[1].exists());assertEquals(listOf(0,1,0),f.hardware.loads.toList());assertEquals(1,completed.size)
        }
    }
    @Test fun pauseWhileIncomingAcquiresNeverAutoplaysAndAccountRevokesBoth() {
        Fixture().use {f->
            f.holdIncoming=true;f.player.prepare();f.player.play();f.drain{f.entered.count==0L};f.player.pause();f.permit.countDown()
            f.drain{f.player.preparationSettled&&f.hardware.pairs.any{it[2]>0}}
            assertFalse(f.player.playWhenReady);assertFalse(f.player.isPlaying);assertTrue(f.hardware.d.none{it.play})
            f.graph.session.revoke();f.drain{f.player.mediaItemCount==0&&f.files.none{it.exists()}}
            assertFalse(f.player.playWhenReady)
        }
    }
    @Test fun sourceLocalSeekAndModesCancelThePairWithoutReplacingCurrent() {
        Fixture().use {f->
            f.armed();f.player.play();f.drain{f.player.isPlaying};f.hardware.sample(5100,1100,.6,.8);f.drain{f.player.currentMediaItem!!.mediaId=="b"}
            f.player.pause();f.player.seekTo(5500);f.drain{f.player.currentPosition==5500L&&f.player.preparationSettled}
            assertEquals("b",f.player.currentMediaItem!!.mediaId);assertEquals(6000L,f.player.duration);assertFalse(f.player.playWhenReady)
            assertTrue(f.hardware.pairs.any{it[0]==1L&&it[1]==0L&&it[2]==0L})
            f.player.repeatMode=Player.REPEAT_MODE_ONE;f.drain{f.player.preparationSettled};assertEquals("b",f.player.currentMediaItem!!.mediaId)
            f.player.shuffleModeEnabled=true;f.player.seekToNextMediaItem();f.drain{f.player.preparationSettled};assertFalse(f.player.playWhenReady)
        }
    }
    @Test fun eofRacingNativeArmReusesPreparedSourceWithoutRevivingPause() {
        for(playing in listOf(false,true))Fixture(count=2).use {f->
            val completed=CopyOnWriteArrayList<String>();f.player.addCompletionListener{completed.add(it.mediaId)}
            f.armed()
            if(playing){f.player.play();f.drain{f.player.isPlaying}}
            synchronized(f.hardware){f.hardware.sample(6000,0,1.0,0.0,true);f.hardware.d[1].play=false}
            f.drain{f.player.currentMediaItem!!.mediaId=="b"&&f.player.preparationSettled&&f.player.isPlaying==playing}
            assertEquals(listOf("a-first"),completed.toList());assertEquals(listOf("a-first","b"),f.requests.toList())
            assertEquals(playing,f.player.playWhenReady);assertEquals(0L,f.player.currentPosition)
        }
    }
    @Test fun cancelledIncomingAcquisitionDrainsBeforeFreshPreparation() {
        Fixture().use {f->
            f.holdIncoming=true;f.player.prepare();f.drain{f.entered.count==0L}
            f.player.repeatMode=Player.REPEAT_MODE_ONE;f.player.pause()
            assertFalse(f.player.preparationSettled)
            f.permit.countDown();f.drain{f.player.preparationSettled}
            assertEquals(listOf("a-first","b"),f.requests.toList());assertEquals(listOf(0),f.hardware.loads.toList())
            f.holdIncoming=false;f.player.repeatMode=Player.REPEAT_MODE_OFF
            f.drain{f.hardware.pairs.any{it[2]>0}&&f.player.preparationSettled}
            assertEquals(listOf("a-first","b","b"),f.requests.toList());assertFalse(f.player.playWhenReady)
        }
    }
    @Test fun repeatAllPreparesTraversalHeadAtTailButRepeatOffDoesNot() {
        Fixture().use {f->
            f.player.seekTo(2,0);f.player.prepare();f.drain{f.player.playbackState==Player.STATE_READY&&f.player.preparationSettled}
            assertEquals(listOf("a-second"),f.requests.toList());assertTrue(f.hardware.pairs.isEmpty())
            f.player.repeatMode=Player.REPEAT_MODE_ALL;f.drain{f.hardware.pairs.any{it[2]>0}&&f.player.preparationSettled}
            assertEquals(listOf("a-second","a-first"),f.requests.toList());assertFalse(f.player.playWhenReady)
        }
    }
    @Test fun offAndRepeatOneDoNotAcquireAnIncomingSource() {
        for(seconds in listOf(0,2))Fixture(seconds=seconds).use {f->
            if(seconds!=0)f.player.repeatMode=Player.REPEAT_MODE_ONE
            f.player.prepare();f.drain{f.player.playbackState==Player.STATE_READY&&f.player.preparationSettled}
            assertEquals(listOf("a-first"),f.requests.toList());assertTrue(f.hardware.pairs.isEmpty());assertFalse(f.player.playWhenReady)
        }
    }
    @Test fun asynchronousIncomingFailureLatchesPausedAndPlayingUntilExplicitPreferenceRetry() {
        for(playing in listOf(false,true))Fixture(count=2).use {f->
            f.hardware.failIncoming=true
            f.hardware.allowRetire=false
            val completed=CopyOnWriteArrayList<String>();f.player.addCompletionListener{completed.add(it.mediaId)}
            f.player.prepare()
            if(playing)f.player.play()
            f.drain{f.hardware.d[1].retiring&&f.player.isPlaying==playing}
            assertEquals(listOf("a-first","b"),f.requests.toList())
            assertTrue("Borrowed incoming file must survive held decoder retirement",f.files[1].exists())
            val outgoing=f.hardware.d[0].id
            f.hardware.allowRetire=true
            f.drain{!f.files[1].exists()}
            val start=f.hardware.observations
            f.drain{f.hardware.observations>=start+40}
            println("RETRY_RECEIPT playing=$playing observations=${f.hardware.observations-start} requests=${f.requests} loads=${f.hardware.loads}")
            assertEquals("Optional failed decoder must not be reacquired by polling",listOf("a-first","b"),f.requests.toList())
            assertEquals(listOf(0,1),f.hardware.loads.toList())
            assertEquals(outgoing,f.hardware.d[0].id);assertTrue(f.files[0].exists())
            assertEquals("a-first",f.player.currentMediaItem!!.mediaId)
            assertEquals(playing,f.player.playWhenReady);assertEquals(playing,f.player.isPlaying)
            assertNull(f.player.playerError);assertTrue(completed.isEmpty())
            // Transport changes alone are not a fresh source/preference retry.
            f.player.playWhenReady=!playing;f.drain{f.player.isPlaying==!playing};f.poll()
            assertEquals(listOf("a-first","b"),f.requests.toList());assertEquals(listOf(0,1),f.hardware.loads.toList())
            f.player.playWhenReady=playing;f.drain{f.player.isPlaying==playing};f.poll()
            assertEquals(listOf("a-first","b"),f.requests.toList());assertEquals(listOf(0,1),f.hardware.loads.toList())
            f.hardware.failIncoming=false
            check(f.graph.crossfadePreferences.setSeconds(f.graph.crossfadePreferences.capture()!!,3){true})
            f.drain{f.hardware.pairs.any{it[2]>0}&&f.player.preparationSettled}
            assertEquals(listOf("a-first","b","b"),f.requests.toList())
            assertEquals(listOf(0,1,1),f.hardware.loads.toList())
            assertEquals(outgoing,f.hardware.d[0].id)
            assertEquals(playing,f.player.playWhenReady)
        }
    }
    @Test fun synchronousAcquisitionAndLoadFailureShareLatchAndExplicitSeekRecovery() {
        for(acquisition in listOf(false,true))Fixture(count=2).use {f->
            f.failIncomingAcquisition=acquisition;f.hardware.refuseIncomingLoad=!acquisition
            f.player.prepare();f.drain{f.requests.size==2&&f.player.preparationSettled}
            f.poll()
            f.player.play();f.drain{f.player.isPlaying};f.poll()
            assertEquals(listOf("a-first","b"),f.requests.toList())
            assertEquals(if(acquisition)listOf(0) else listOf(0,1),f.hardware.loads.toList())
            assertTrue(f.files[0].exists());assertTrue(f.files.drop(1).none{it.exists()})
            assertEquals("a-first",f.player.currentMediaItem!!.mediaId);assertNull(f.player.playerError)
            val outgoing=f.hardware.d[0].id
            f.failIncomingAcquisition=false;f.hardware.refuseIncomingLoad=false
            f.player.seekTo(1000)
            f.drain{f.player.currentPosition==1000L&&f.hardware.pairs.any{it[2]>0}&&f.player.preparationSettled}
            assertEquals(listOf("a-first","b","b"),f.requests.toList())
            assertEquals(if(acquisition)listOf(0,1) else listOf(0,1,1),f.hardware.loads.toList())
            assertEquals(outgoing,f.hardware.d[0].id);assertTrue(f.player.playWhenReady)
        }
    }
    @Test fun staleIncomingErrorAfterSelectionOrAccountChangeCannotRetireOrLatchFreshWork() {
        for(account in listOf(false,true))Fixture().use {f->
            f.armed()
            val stale=synchronized(f.hardware){f.hardware.d[1].error=7;f.hardware.state(1).also{f.hardware.d[1].error=0}}
            if(account){
                f.graph.session.revoke();f.drain{f.player.mediaItemCount==0&&f.files.none{it.exists()}}
                f.hardware.replayState=stale;f.drain{f.hardware.replays==1};f.poll(3)
                assertEquals(listOf("a-first","b"),f.requests.toList());assertEquals(0,f.player.mediaItemCount)
                check(f.graph.session.accept(f.graph.session.beginIntent(),SecretTokens("fresh","fresh","fresh")))
                f.items.forEach{item->f.grants[item.localConfiguration!!.uri.toString()]=MediaGrant(f.graph.session.capture()!!,TrackId(7))}
                f.player.setMediaItems(f.items);f.player.prepare()
            }else{
                f.player.seekTo(2,0);f.drain{f.player.currentMediaItem?.mediaId=="a-second"&&f.player.preparationSettled&&f.player.playbackState==Player.STATE_READY}
                val requests=f.requests.toList();val identity=f.hardware.d[0].id
                f.hardware.replayState=stale;f.drain{f.hardware.replays==1};f.poll(3)
                assertEquals(requests,f.requests.toList());assertEquals(identity,f.hardware.d[0].id)
                assertEquals("a-second",f.player.currentMediaItem!!.mediaId);assertNull(f.player.playerError)
                f.player.seekTo(0,0)
            }
            f.drain{f.requests.count{it=="b"}==2&&f.player.preparationSettled&&f.hardware.pairs.count{it[2]>0}>=2}
            val requests=f.requests.toList();val outgoing=f.hardware.d[0].id;val incoming=f.hardware.d[1].id
            // Replay the old accepted identity again with a new live successor in that slot.
            val replays=f.hardware.replays
            f.hardware.replayState=stale;f.drain{f.hardware.replays>replays};f.poll()
            assertEquals(requests,f.requests.toList());assertEquals(outgoing,f.hardware.d[0].id);assertEquals(incoming,f.hardware.d[1].id)
            assertEquals("a-first",f.player.currentMediaItem!!.mediaId);assertNull(f.player.playerError);assertFalse(f.player.playWhenReady)
        }
    }
}
