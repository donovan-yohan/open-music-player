package com.soundq.android.playback.nativeengine

import android.content.ContextWrapper
import android.net.Uri
import android.os.Bundle
import android.os.Looper
import androidx.media3.common.*
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.MediaGrant
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import org.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class NativeArrangementPlayerTest {
    internal class Hardware : NativeCallbackCalls {
        val ops=CopyOnWriteArrayList<Int>()
        @Volatile var ready=false
        @Volatile var holdPauseAck=false
        @Volatile var pausePending=false
        var expectedClips=2
        @Volatile var allowRetire=false
        @Volatile var allowOrdinaryRetire=true
        @Volatile var holdSeekAck=false
        @Volatile var scheduleDurationMs=3000L
        private var retiringOrdinary=false
        private var pendingSeek:Long?=null
        @Volatile var holdProbe=false
        val probeEntered=java.util.concurrent.CountDownLatch(1)
        val probePermit=java.util.concurrent.CountDownLatch(1)
        private var candidate=0L
        private var revision=0L
        private var retiringGraph=false
        private var position=0L
        private var playing=false
        private var identity=0L
        private var generation=0L
        override fun open()=1L
        override fun load(handle:Long,deck:Int,path:String,identity:Long,generation:Long,positionMs:Long):Boolean {this.identity=identity;this.generation=generation;position=positionMs;retiringOrdinary=false;return true}
        override fun control(handle:Long,operation:Int,deck:Int,value:Double,eventNanos:Long):Boolean {ops.add(100+operation);if(operation==8){retiringOrdinary=true;if(allowOrdinaryRetire)identity=0};if(operation==1){playing=true;pausePending=false};if(operation==3)pendingSeek=value.toLong();if(operation==2){pausePending=true;if(!holdPauseAck)playing=false};return true}
        override fun prepareSchedule(handle:Long,revision:Long,paths:Array<String>,values:LongArray):Boolean {candidate=revision;check(paths.size==expectedClips&&values.size==expectedClips*6);if(holdProbe){probeEntered.countDown();check(probePermit.await(5,TimeUnit.SECONDS))};return true}
        override fun arrangement(handle:Long,operation:Int,value:Long):Boolean {
            ops.add(operation)
            when(operation){1->{if(!ready)return false;playing=true;pausePending=false};2->{pausePending=true;if(!holdPauseAck)playing=false};3->{pendingSeek=minOf(value,scheduleDurationMs);playing=false};4->{revision=candidate;retiringGraph=false;playing=false;position=0};5->{retiringGraph=true;if(allowRetire){revision=0;playing=false}else return true};6->candidate=0}
            return true
        }
        override fun state(handle:Long):String {
            if(holdState){stateEntered.countDown();check(statePermit.await(5,TimeUnit.SECONDS));holdState=false}
            if(!holdTempoAck)tempoCalls.lastOrNull()?.takeIf {it.revision==revision&&!refuseTempo&&it.tag!=tempoRefused}?.let {
                tempoApplied=it.tag;tempoInstance=it.instance;tempoBpm=it.target
            }
            if(pausePending&&!holdPauseAck){playing=false;pausePending=false}
            globalOverride?.let {position=it}
            if(retiringOrdinary && allowOrdinaryRetire)identity=0
            if(!holdSeekAck)pendingSeek?.let{position=it;pendingSeek=null}
            if(allowRetire && revision!=0L && retiringGraph){revision=0;playing=false}
            val decks=JSONArray()
            repeat(4){i->val instance=if(slotSwap&&i<2)2-i else i+1;decks.put(JSONObject().put("identity",if(revision!=0L&&i<expectedClips)instance else if(i==0)identity else 0)
                .put("sourceFrame",actualFrame).put("nominalSourceFrame",position*48.0).put("rate",actualRate)
                .put("tempoGeneration",if(instance.toLong()==tempoInstance)tempoApplied else 0L).put("effectiveBpm",if(instance.toLong()==tempoInstance)tempoBpm else 120.0)
                .put("scratching",scratchInstance==instance.toLong()).put("gesture",scratchGesture)
                .put("lastMoveEventNanos",moveEvent).put("lastMoveAppliedNanos",moveEvent+5).put("lastMoveSequence",moveSequence)
                .put("heldZero",actualRate==0.0).put("syncReference",if(instance==2)syncReference else 0)
                .put("syncBeats",if(instance==2)syncBeats else 0).put("syncState",if(instance==2)syncState else 0).put("syncPhaseErrorFrames",0.25)
                .put("generation",if(revision!=0L)revision else generation).put("positionMs",position).put("durationMs",3000)
                .put("sourceRate",48000).put("sourceFrames",144000).put("ready",if(revision!=0L)ready else identity!=0L)
                .put("preparing",false).put("playing",playing&&(revision!=0L&&i<expectedClips||identity!=0L&&i==0)).put("eofCount",0).put("openDecoders",0).put("error",0))}
            return JSONObject().put("error",0).put("tempoApplied",tempoApplied).put("tempoRefused",tempoRefused).put("decks",decks).put("sampleRate",48000).put("scheduleRevision",revision)
                .put("globalFrame",position*48).put("durationFrames",scheduleDurationMs*48).put("scheduleReady",ready&&revision!=0L&&pendingSeek==null)
                .put("schedulePlaying",playing&&revision!=0L).put("scheduleRetiring",revision!=0L&&retiringGraph).toString()
        }
        data class TempoCall(val revision:Long,val instance:Long,val tag:Long,val source:Double,val target:Double,val glide:Long)
        val tempoCalls=CopyOnWriteArrayList<TempoCall>()
        @Volatile var reservationAvailable=true
        @Volatile var previewSlots=Int.MAX_VALUE
        @Volatile var restoreCalls=0
        @Volatile var holdState=false
        val stateEntered=java.util.concurrent.CountDownLatch(1)
        val statePermit=java.util.concurrent.CountDownLatch(1)
        val reservationCalls=CopyOnWriteArrayList<Long>()
        @Volatile var holdTempoAck=false
        @Volatile var refuseTempo=false
        @Volatile var tempoApplied=0L
        @Volatile var tempoRefused=0L
        @Volatile var tempoInstance=0L
        @Volatile var tempoBpm=120.0
        @Volatile var globalOverride:Long?=null
        override fun liveTempo(handle:Long,revision:Long,instance:Long,tag:Long,sourceBpm:Double,targetBpm:Double,glideFrames:Long,reservation:Long):Boolean {
            check(reservation==nativeReservation && reservation>0)
            check(android.os.Looper.myLooper()!=android.os.Looper.getMainLooper())
            tempoCalls.add(TempoCall(revision,instance,tag,sourceBpm,targetBpm,glideFrames))
            if(refuseTempo)return false
            if(previewSlots<=0){tempoRefused=tag;return true}
            previewSlots--
            return this.revision==revision
        }
        private var nativeReservation=0L
        private var nativeReservationRevision=0L
        private var nativeReservationInstance=0L
        private var nativeReservationSource=0.0
        private var nativeReservationOrigin=0.0
        override fun reserveTempo(handle:Long,revision:Long,instance:Long,sourceBpm:Double,originBpm:Double):Long {
            check(Looper.myLooper()!=Looper.getMainLooper())
            reservationCalls.add(revision)
            if(!reservationAvailable || nativeReservation!=0L)return 0
            nativeReservation=reservationCalls.size.toLong();nativeReservationRevision=revision;nativeReservationInstance=instance
            nativeReservationSource=sourceBpm;nativeReservationOrigin=originBpm
            return nativeReservation
        }
        override fun restoreTempo(handle:Long,reservation:Long,tag:Long):Boolean {
            if(reservation!=nativeReservation || reservation==0L)return false
            restoreCalls++
            // Native terminal consumes reserved capacity, not the preview budget.
            val ordinary=previewSlots;previewSlots=Int.MAX_VALUE
            val accepted=liveTempo(handle,nativeReservationRevision,nativeReservationInstance,tag,nativeReservationSource,nativeReservationOrigin,0,reservation)
            previewSlots=ordinary
            if(accepted)nativeReservation=0
            return accepted
        }
        override fun releaseTempo(handle:Long,reservation:Long):Boolean {
            if(reservation!=nativeReservation)return false
            nativeReservation=0;return true
        }
        val scratchCalls=CopyOnWriteArrayList<List<Number>>()
        val syncCalls=CopyOnWriteArrayList<List<Number>>()
        @Volatile var scratchInstance=0L
        @Volatile var scratchGesture=0L
        @Volatile var actualFrame=48000.25
        @Volatile var actualRate=1.0
        @Volatile var holdSyncAck=false
        @Volatile var holdUnlinkAck=false
        @Volatile var syncState=0
        @Volatile var syncReference=0L
        @Volatile var syncBeats=0
        @Volatile var moveEvent=0L
        @Volatile var moveSequence=0L
        @Volatile var slotSwap=false
        @Volatile var holdMove=false
        val moveEntered=java.util.concurrent.CountDownLatch(1)
        val movePermit=java.util.concurrent.CountDownLatch(1)
        @Volatile var terminalRefusals=0
        override fun scratch(handle:Long,operation:Int,instance:Long,gesture:Long,eventNanos:Long,rate:Double):Boolean {
            scratchCalls.add(listOf(operation,instance,gesture,eventNanos,rate))
            if(operation in 3..4&&terminalRefusals>0){terminalRefusals--;return false}
            if(operation==2&&holdMove){moveEntered.countDown();check(movePermit.await(5,TimeUnit.SECONDS))}
            if(revision==0L || instance !in 1L..expectedClips.toLong() || !ready)return false
            when(operation) {
                1->{if(scratchInstance!=0L)return false;scratchInstance=instance;scratchGesture=gesture;actualRate=0.0}
                2->{if(scratchInstance!=instance || scratchGesture!=gesture)return false;actualRate=rate;moveEvent=eventNanos;moveSequence++}
                3,4->{if(scratchInstance!=instance || scratchGesture!=gesture)return false;scratchInstance=0;actualRate=1.0;if(syncState!=0)syncState=4}
                else->return false
            }
            return true
        }
        override fun sync(handle:Long,incoming:Long,reference:Long,beats:Int,referenceBpm:Double,referenceAnchorMs:Double,referenceOriginMs:Double,incomingBpm:Double,incomingAnchorMs:Double,incomingOriginMs:Double):Boolean {
            syncCalls.add(listOf(incoming,reference,beats,referenceBpm,referenceAnchorMs,referenceOriginMs,incomingBpm,incomingAnchorMs,incomingOriginMs))
            if(revision==0L || !ready)return false
            if(if(beats==0)holdUnlinkAck else holdSyncAck)return true
            syncReference=if(beats==0)0 else reference;syncBeats=beats;syncState=if(beats==0)0 else 1
            return true
        }
        override fun close(handle:Long)=true
    }
    private class Fixture(private val count:Int=2):AutoCloseable {
        val root=java.nio.file.Files.createTempDirectory(File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"native-arrangement-").toFile()
        val graph=AppGraph(object:ContextWrapper(RuntimeEnvironment.getApplication()) {override fun getNoBackupFilesDir()=root},ApiEndpoint.parse("https://fixture.invalid/api/v1"),store=object:SessionStore {
            override fun load(endpoint:ApiEndpoint):SecretTokens?=null
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
            override fun clear(){}
        })
        val hardware=Hardware().apply{expectedClips=count}
        val grants=ConcurrentHashMap<String,MediaGrant>()
        val files=CopyOnWriteArrayList<File>()
        val jobs=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        val player:NativeCallbackPlayer
        val items:List<MediaItem>
        val document:TimelineDocument
        init {
            check(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture","fixture","fixture")))
            items=listOf("a","b","c","d").take(count).map {id->val uri=Uri.parse("soundq://track/7/$id");grants[uri.toString()]=MediaGrant(graph.session.capture()!!,TrackId(7));MediaItem.Builder().setMediaId(id).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setExtras(Bundle().apply {putLong("trackId",7);putLong("durationMs",3000)}).build()).build()}
            document=TimelineDocument(1,items.mapIndexed {i,m->TimelineClip(m.mediaId,7,"Fixture",3000,0,3000,i*500L,QueueSegment.Context)})
            player=NativeCallbackPlayer(graph,grants,jobs,hardware,NativeCallbackSource {item,current->check(current());File(root,item.mediaId+".encoded").apply{writeBytes(byteArrayOf(1,2,3));files.add(this)}})
            player.setMediaItems(items)
        }
        fun drain(predicate:()->Boolean) {
            val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
            while(true){
                val owner=NativeCallbackPlayer::class.java.getDeclaredField("owner").apply{isAccessible=true}.get(player)
                val thread=owner.javaClass.getDeclaredField("thread").apply{isAccessible=true}.get(owner) as android.os.HandlerThread
                Shadows.shadowOf(thread.looper).idleFor(java.time.Duration.ofMillis(50))
                Shadows.shadowOf(Looper.getMainLooper()).idle();if(predicate())return;check(System.nanoTime()<deadline){"Native player acknowledgement deadline"};Thread.sleep(5)}
        }
        fun prepare():NativeCallbackArrangement {
            var result:NativeCallbackArrangement?=null;var failure:Throwable?=null
            jobs.launch {try{result=player.prepareArrangement(document,items){true}}catch(t:Throwable){failure=t}}
            drain {result!=null||failure!=null};failure?.let{throw it};return result!!
        }
        fun install(candidate:NativeCallbackArrangement) {player.installArrangement(candidate,MediaItem.Builder().setMediaId("arrangement").setUri("soundqarrangement://fixture").build(),items)}
        override fun close(){hardware.allowRetire=true;hardware.allowOrdinaryRetire=true;player.release();drain{player.nativeReleased.isDone};assertTrue(player.nativeReleased.get());jobs.cancel();graph.close();root.deleteRecursively()}
    }
    @Test fun ordinaryPausedNativeCursorReachesRealMediaController() = pausedCursorPublication(false)
    @Test fun arrangementPausedNativeCursorReachesRealMediaController() = pausedCursorPublication(true)

    private fun pausedCursorPublication(arrangement:Boolean) {
        Fixture().use {f->
            if(arrangement){f.install(f.prepare());f.hardware.ready=true}
            else f.player.prepare()
            f.drain{f.player.playbackState==Player.STATE_READY&&f.player.preparationSettled}
            val session=androidx.media3.session.MediaSession.Builder(RuntimeEnvironment.getApplication(),f.player).build()
            val future=androidx.media3.session.MediaController.Builder(RuntimeEnvironment.getApplication(),session.token)
                .setApplicationLooper(Looper.getMainLooper()).buildAsync()
            var controller:androidx.media3.session.MediaController?=null
            try {
                f.drain{future.isDone};val remote=future.get();controller=remote
                val reasons=mutableListOf<Int>()
                f.player.addListener(object:Player.Listener {
                    override fun onPositionDiscontinuity(oldPosition:Player.PositionInfo,newPosition:Player.PositionInfo,reason:Int){reasons.add(reason)}
                })
                remote.play();f.drain{f.player.isPlaying&&remote.isPlaying}
                f.hardware.globalOverride=253L;f.drain{f.player.currentPosition==253L}
                f.hardware.holdPauseAck=true
                remote.pause();f.drain{f.hardware.pausePending&&!remote.playWhenReady&&!f.player.playWhenReady}
                val before=reasons.size
                val commands=f.hardware.ops.toList()
                // Native can consume the admitted Pause after one last moving callback.
                f.hardware.globalOverride=280L;f.drain{f.player.currentPosition==280L}
                assertEquals(before,reasons.size)
                f.hardware.globalOverride=313L;f.hardware.holdPauseAck=false
                f.drain{f.player.currentPosition==313L&&!f.hardware.pausePending}
                // No tolerance or projection tick: both are the same settled native cursor.
                assertEquals("Paused native cursor must be published by the real pinned MediaSession",313L,remote.currentPosition)
                assertEquals(listOf(Player.DISCONTINUITY_REASON_INTERNAL),reasons.drop(before))
                repeat(4){f.drain{true}}
                assertEquals("Identical paused snapshots must not emit discontinuities",before+1,reasons.size)
                assertEquals("Publishing a cursor must not seek/restart native output",commands,f.hardware.ops.toList())
                assertEquals(313L,remote.currentPosition);assertFalse(remote.isPlaying)
                // A subsequent genuine Play/Pause has its own settled correction.
                remote.play();f.drain{f.player.isPlaying&&remote.isPlaying}
                f.hardware.globalOverride=400L;f.drain{f.player.currentPosition==400L}
                f.hardware.holdPauseAck=true;remote.pause();f.drain{f.hardware.pausePending&&!f.player.playWhenReady}
                f.hardware.globalOverride=439L;f.hardware.holdPauseAck=false
                f.drain{f.player.currentPosition==439L&&!f.hardware.pausePending}
                assertEquals(439L,remote.currentPosition)
                assertEquals(listOf(Player.DISCONTINUITY_REASON_INTERNAL,Player.DISCONTINUITY_REASON_INTERNAL),reasons.drop(before))
                remote.seekTo(900L);f.drain{f.player.currentPosition==900L}
                assertEquals(900L,remote.currentPosition)
                assertEquals("A real seek retains its SEEK reason",Player.DISCONTINUITY_REASON_SEEK,reasons.last())
                f.hardware.globalOverride=900L
                val afterSeek=reasons.size
                remote.play();f.drain{f.player.isPlaying&&remote.isPlaying}
                remote.pause();f.drain{!f.hardware.pausePending&&!f.player.playWhenReady}
                assertEquals("No correction for an unchanged paused cursor",afterSeek,reasons.size)
                remote.play();f.drain{f.player.isPlaying&&remote.isPlaying}
                f.hardware.holdPauseAck=true;remote.pause();f.drain{f.hardware.pausePending&&!f.player.playWhenReady}
                remote.play();f.drain{f.player.playWhenReady&&f.player.isPlaying}
                f.hardware.pausePending=false;f.hardware.holdPauseAck=false
                f.hardware.globalOverride=500L;f.drain{f.player.currentPosition==500L}
                assertEquals("A newer Play retires the old Pause correction",afterSeek,reasons.size)
                assertTrue(remote.playWhenReady)
                f.hardware.holdPauseAck=true;remote.pause();f.drain{f.hardware.pausePending&&!f.player.playWhenReady}
                f.grants.clear();f.hardware.globalOverride=550L;f.hardware.holdPauseAck=false
                f.drain{f.player.playbackState==Player.STATE_IDLE}
                assertEquals("A retired grant cannot publish a late Pause correction",afterSeek,reasons.size)
            } finally {controller?.release();session.release()}
        }
    }
    @Test fun performanceFieldsAreNotDiscardedByNativeSnapshotParser() {
        val hardware=Hardware()
        val root=JSONObject(hardware.state(1))
        root.getJSONArray("decks").getJSONObject(0).put("sourceFrame",12000.5).put("rate",-0.125)
            .put("nominalSourceFrame",24000.0).put("scratching",true).put("gesture",7L)
            .put("lastMoveEventNanos",100L).put("lastMoveAppliedNanos",120L).put("lastMoveSequence",3L)
            .put("heldZero",false).put("syncReference",2L).put("syncBeats",4).put("syncState",3).put("syncPhaseErrorFrames",0.25)
        val deck=NativeCallbackSnapshot.parse(root.toString()).decks.first()
        fun value(name:String)=deck.javaClass.getDeclaredField(name).apply{isAccessible=true}.get(deck)
        assertEquals("Actual fractional native cursor must survive parsing",12000.5,value("sourceFrame"))
        assertEquals(-0.125,value("rate"));assertEquals(7L,value("gesture"));assertEquals(3,value("syncState"))
    }
    @Test fun keylockReceiptRetainsProcessingEpochAndEffectiveTempoWithoutChangingSourceCoordinates() {
        val root=JSONObject(Hardware().state(1))
        root.getJSONArray("decks").getJSONObject(0)
            .put("sourceFrame",12000.25).put("nominalSourceFrame",12000.5)
            .put("pitchPreserved",true).put("processingEpoch",42L).put("effectiveBpm",132.5)
        val deck=NativeCallbackSnapshot.parse(root.toString()).decks.first()
        assertTrue(deck.pitchPreserved);assertEquals(42L,deck.processingEpoch)
        assertEquals(132.5,deck.effectiveBpm,0.0)
        assertEquals(12000.25,deck.sourceFrame,0.0);assertEquals(12000.5,deck.nominalSourceFrame,0.0)
    }
    @Test fun scratchMovesAreBoundedAndTerminalCannotBeOvertaken() {
        Fixture().use {f->
            val owner=NativeCallbackPlayer::class.java.getDeclaredField("owner").apply{isAccessible=true}.get(f.player)
            val method=owner.javaClass.methods.firstOrNull{it.name=="offerScratch"}
            assertNotNull("Native control owner needs a bounded latest-Move lane with reliable terminal",method)
        }
    }
    @Test fun scratchLeaseUsesDocumentOrdinalAndOriginalEventsAndPauseRevokesDelayedEnd() {
        Fixture().use {f->
            val candidate=f.prepare();f.install(candidate);f.hardware.ready=true
            val identity=com.soundq.android.playback.ArrangementIdentity("service",f.graph.session.capture()!!.epoch,"queue",f.document.revision,"arrangement")
            f.player.bindPerformance(identity);f.player.seekTo(600);f.drain{f.player.performanceDecks.size==2&&f.player.currentPosition==600L}
            f.hardware.slotSwap=true
            android.os.SystemClock.setCurrentTimeMillis(10000)
            val now=android.os.SystemClock.uptimeMillis()*1_000_000L
            var lease:com.soundq.android.playback.ScratchLease?=null
            f.player.beginScratch(com.soundq.android.playback.PerformanceTarget(identity,"b"),now-20000,{true}){lease=it}
            f.drain{lease!=null}
            val captured=lease!!
            assertEquals(2L,f.hardware.scratchCalls.single()[1]);assertEquals(now-20000,f.hardware.scratchCalls.single()[3])
            f.hardware.holdMove=true
            assertTrue(f.player.moveScratch(captured,-0.125,now-19500))
            val pump=Thread { val owner=NativeCallbackPlayer::class.java.getDeclaredField("owner").apply{isAccessible=true}.get(f.player);val thread=owner.javaClass.getDeclaredField("thread").apply{isAccessible=true}.get(owner) as android.os.HandlerThread;Shadows.shadowOf(thread.looper).idleFor(java.time.Duration.ofMillis(50)) };pump.start()
            assertTrue(f.hardware.moveEntered.await(5,TimeUnit.SECONDS))
            repeat(1000){i->assertTrue(f.player.moveScratch(captured,-0.125,now-19000+i))}
            f.hardware.holdMove=false;f.hardware.movePermit.countDown();pump.join()
            f.drain{f.hardware.moveSequence>0}
            assertTrue("Move backlog must stay bounded",f.hardware.scratchCalls.count{it[0]==2}<=2)
            assertEquals(now-18001,f.hardware.moveEvent);assertEquals(-0.125,f.hardware.actualRate,0.0)
            assertFalse(f.player.moveScratch(captured,1.0,now-18002))
            assertFalse(f.player.moveScratch(captured,Double.NaN,now-17000))
            assertEquals(1000.0052083333334,f.player.performanceDecks.getValue("b").sourcePositionMs,1e-9)
            assertTrue(f.player.finishScratch(captured,now-16000,false))
            f.player.revokePerformance();f.player.pause() // Service admission revokes even a no-op Pause.
            f.drain{f.hardware.ops.contains(2)}
            assertFalse(f.hardware.scratchCalls.any{it[0]==3});assertFalse(f.player.moveScratch(captured,1.0,now-15000))
            assertFalse(f.player.playWhenReady);assertSame(f.document,candidate.document)
        }
    }
    @Test fun liveQualificationIsReadOnlyAndPermanentlyFencesSourceAndDurationABA() {
        Fixture().use {f->
            val scope=f.graph.session.capture()!!
            var key="source-a"
            val repository=TimelineRepository(f.graph.session,File(f.root,"qualification")){_,track,duration,valid->check(valid());TrackWaveform(track,key,duration,listOf(PeakTier("overview",floatArrayOf(-1f),floatArrayOf(1f))))}
            val rows=f.items.map {TimelineSource(it.mediaId,7,"Fixture",3000,QueueSegment.Context)}
            repository.observe(scope,rows)
            repository.waveform(scope,TrackId(7),3000){true}
            val document=repository.state.value.document
            val lease=repository.qualifyLiveGrid(scope,7,3000,"source-a","local:1",123.45,0.25,null,"local_manual")!!
            assertTrue(lease());assertEquals(document,repository.state.value.document)
            key="source-b";repository.waveform(scope,TrackId(7),3000,true){true};assertFalse(lease())
            key="source-a";repository.waveform(scope,TrackId(7),3000,true){true};assertFalse(lease())
            val fresh=repository.qualifyLiveGrid(scope,7,3000,"source-a","local:1",123.45,0.25,null,"local_manual")!!
            repository.observe(scope,emptyList());repository.observe(scope,rows);repository.waveform(scope,TrackId(7),3000,true){true};assertFalse(fresh())
            assertNull(repository.qualifyLiveGrid(scope,7,3000,"source-a","local:1",601.0,0.0,null,"local_manual"))
            assertNull(repository.qualifyLiveGrid(scope,7,3000,"source-a","server:1",120.0,0.0,null,"manual_timing_v2"))
            f.graph.session.accept(f.graph.session.beginIntent(),SecretTokens("other","other","other"))
            assertNull(repository.qualifyLiveGrid(scope,7,3000,"source-a","local:1",120.0,0.0,null,"local_manual"))
        }
    }
    @Test fun unequalLiveBpmUsesNativePendingThenExactLockedAckWithoutDraftMutation() {
        Fixture().use {f->
            val candidate=f.prepare();f.install(candidate);f.hardware.ready=true
            val identity=com.soundq.android.playback.ArrangementIdentity("service",f.graph.session.capture()!!.epoch,"queue",f.document.revision,"arrangement")
            f.player.bindPerformance(identity);f.player.seekTo(600);f.drain{f.player.performanceDecks.size==2&&f.player.currentPosition==600L}
            val a=com.soundq.android.playback.QualifiedLiveGrid(120.0,0.0,0.0,"source-a","local:1")
            val b=com.soundq.android.playback.QualifiedLiveGrid(100.0,0.0,0.0,"source-b","local:2")
            var accepted:Boolean?=null
            f.jobs.launch{accepted=f.player.syncIncoming(identity,"a","b",4,a,b){true}}
            f.drain{accepted!=null};assertTrue(accepted!!)
            assertEquals(listOf<Number>(2L,1L,4,120.0,0.0,0.0,100.0,0.0,0.0),f.hardware.syncCalls.single())
            f.drain{f.player.performanceDecks["b"]?.syncState==com.soundq.android.playback.LiveSyncState.Pending}
            f.hardware.syncState=2;f.hardware.actualRate=1.2
            f.drain{f.player.performanceDecks["b"]?.syncState==com.soundq.android.playback.LiveSyncState.Locked}
            assertEquals(1.2,f.player.performanceDecks.getValue("b").rate,0.0)
            assertSame(f.document,candidate.document);assertFalse(f.player.playWhenReady)
            var masterLease:com.soundq.android.playback.ScratchLease?=null
            f.player.beginScratch(com.soundq.android.playback.PerformanceTarget(identity,"a"),android.os.SystemClock.uptimeMillis()*1000000L,{true}){masterLease=it}
            assertNull(masterLease);assertTrue(f.hardware.scratchCalls.isEmpty())
            accepted=null;f.jobs.launch{accepted=f.player.unlinkIncoming(identity,"b"){true}};f.drain{accepted!=null}
            assertTrue(accepted!!);assertEquals(0,f.hardware.syncCalls.last()[2]);assertFalse(f.player.playWhenReady)
        }
    }
    @Test fun reliableTerminalRetriesOriginalEventAndCapturedGrantRefusesStaleMove() {
        Fixture().use {f->
            val candidate=f.prepare();f.install(candidate);f.hardware.ready=true
            val identity=com.soundq.android.playback.ArrangementIdentity("service",f.graph.session.capture()!!.epoch,"queue",f.document.revision,"arrangement")
            f.player.bindPerformance(identity);f.drain{f.player.performanceDecks.containsKey("a")}
            var lease:com.soundq.android.playback.ScratchLease?=null
            val event=android.os.SystemClock.uptimeMillis()*1000000L
            f.player.beginScratch(com.soundq.android.playback.PerformanceTarget(identity,"a"),event-10000,{true}){lease=it};f.drain{lease!=null}
            f.hardware.terminalRefusals=2
            assertTrue(f.player.finishScratch(lease!!,event-9000,false))
            f.drain{f.hardware.scratchInstance==0L}
            assertEquals(3,f.hardware.scratchCalls.count{it[0]==3});assertTrue(f.hardware.scratchCalls.filter{it[0]==3}.all{it[3]==event-9000})
            lease=null
            f.player.beginScratch(com.soundq.android.playback.PerformanceTarget(identity,"a"),event-8000,{true}){lease=it};f.drain{lease!=null}
            val uri=f.items.first().localConfiguration!!.uri.toString()
            f.grants[uri]=MediaGrant(f.graph.session.capture()!!,TrackId(7))
            assertFalse(f.player.moveScratch(lease!!,0.001,event-7000));assertFalse(f.player.finishScratch(lease!!,event-6000,false))
            f.drain{f.hardware.ops.contains(5)}
        }
    }
    @Test fun fourNativeOccurrencesPublishOnlyTouchedScratchAndRejectOldScheduleAck() {
        Fixture(4).use {f->
            f.hardware.scheduleDurationMs=4500
            val candidate=f.prepare();f.install(candidate);f.hardware.ready=true
            val identity=com.soundq.android.playback.ArrangementIdentity("service",f.graph.session.capture()!!.epoch,"queue",f.document.revision,"arrangement")
            f.player.bindPerformance(identity);f.player.seekTo(1600);f.drain{f.player.performanceDecks.size==4&&f.player.currentPosition==1600L}
            f.player.play();f.drain{f.player.isPlaying}
            var lease:com.soundq.android.playback.ScratchLease?=null
            val now=android.os.SystemClock.uptimeMillis()*1000000L
            f.player.beginScratch(com.soundq.android.playback.PerformanceTarget(identity,"d"),now-1000,{true}){lease=it};f.drain{lease!=null}
            f.drain{f.player.performanceDecks["d"]?.scratching==true}
            assertEquals(listOf("d"),f.player.performanceDecks.filterValues{it.scratching}.keys.toList())
            assertEquals(setOf("a","b","c"),f.player.performanceDecks.filterValues{!it.scratching&&it.playing}.keys)
            assertEquals(4L,f.hardware.scratchCalls.last()[1])
            val stale=NativeCallbackSnapshot.parse(f.hardware.state(1)).copy(scheduleRevision=candidate.revision+1,globalPositionMs=999)
            NativeCallbackPlayer::class.java.getDeclaredMethod("observe",NativeCallbackSnapshot::class.java).apply{isAccessible=true}.invoke(f.player,stale)
            assertEquals(1600L,f.player.currentPosition)
            f.player.stop();assertTrue(f.player.performanceDecks.isEmpty());assertFalse(f.player.moveScratch(lease!!,1.0,now+1))
            assertEquals(f.items,(0 until f.player.mediaItemCount).map(f.player::getMediaItemAt));assertFalse(f.player.playWhenReady)
        }
    }
    @Test fun realPlayerKeepsGraphPausedUntilReadyThenUsesNativeAckAndDoesNotForgeTrackCompletion() {
        Fixture().use {f->
            val candidate=f.prepare();f.install(candidate)
            f.drain{f.hardware.ops.contains(4)}
            assertEquals(Player.STATE_BUFFERING,f.player.playbackState)
            f.player.play();f.drain{f.player.playWhenReady};assertFalse(f.hardware.ops.contains(1))
            f.hardware.ready=true;f.drain{f.player.isPlaying}
            assertTrue(f.hardware.ops.contains(1));assertEquals(2,NativeCallbackSnapshot.parse(f.hardware.state(1)).decks.count{it.playing})
            f.player.pause();f.drain{!f.player.isPlaying};assertEquals(0L,f.player.currentPosition)
            f.player.seekTo(1000);f.drain{f.player.currentPosition==1000L};assertFalse(f.player.isPlaying)
        }
    }
    @Test fun seekHeldBehindOrdinaryUnloadReachesInstalledGraphAndWaitsCursorAckPaused() {
        Fixture().use {f->
            f.player.prepare();f.drain{f.player.playbackState==Player.STATE_READY}
            val candidate=f.prepare()
            f.hardware.allowOrdinaryRetire=false;f.install(candidate)
            f.drain{f.hardware.ops.contains(108)}
            f.player.seekTo(1000);assertFalse(f.hardware.ops.contains(3))
            f.hardware.holdSeekAck=true;f.hardware.ready=true;f.hardware.allowOrdinaryRetire=true
            f.drain{f.hardware.ops.contains(4)&&f.player.preparationSettled}
            assertTrue("Seek captured during install must reach native graph",f.hardware.ops.contains(3))
            assertFalse(f.player.isPlaying);assertFalse(f.hardware.ops.contains(1));assertEquals(0L,f.player.currentPosition)
            f.hardware.holdSeekAck=false;f.drain{f.player.currentPosition==1000L&&f.player.playbackState==Player.STATE_READY}
            assertFalse(f.player.isPlaying)
            f.player.play();f.drain{f.player.isPlaying};assertTrue(f.hardware.ops.contains(1))
        }
    }
    @Test fun decodedNativeDurationReplacesOnlyPlaybackDurationAndEndpointSeekAckUsesActualEnd() {
        Fixture().use {f->
            val original=f.document
            f.player.prepare();f.drain{f.player.playbackState==Player.STATE_READY}
            val candidate=f.prepare();f.hardware.scheduleDurationMs=2800;f.hardware.allowOrdinaryRetire=false
            f.install(candidate);f.drain{f.hardware.ops.contains(108)}
            f.player.seekTo(3400) // Catalog schedule is 3500; native EOF is not published yet.
            f.hardware.allowOrdinaryRetire=true;f.hardware.ready=true
            f.drain{f.player.currentPosition==2800L&&f.player.playbackState==Player.STATE_READY}
            assertEquals(2800L,f.player.duration);assertSame(original,candidate.document)
            f.player.play();f.drain{f.player.isPlaying};assertTrue(f.hardware.ops.contains(1))
        }
    }
    @Test fun seekCapturedDuringInstallCannotReachRetiredSourceOwner() {
        Fixture().use {f->
            f.player.prepare();f.drain{f.player.playbackState==Player.STATE_READY}
            val candidate=f.prepare();f.hardware.allowOrdinaryRetire=false;f.install(candidate)
            f.drain{f.hardware.ops.contains(108)};f.player.seekTo(1000)
            f.grants.clear();f.hardware.allowOrdinaryRetire=true;f.drain{f.player.preparationSettled}
            assertFalse(f.hardware.ops.contains(4));assertFalse(f.hardware.ops.contains(3));assertFalse(f.player.isPlaying)
        }
    }
    @Test fun returnToOrdinaryRetainsAllEncodedFilesUntilGraphRetirementThenReusesOwner() {
        Fixture().use {f->val candidate=f.prepare();f.install(candidate);f.hardware.ready=true;f.drain{f.player.playbackState==Player.STATE_READY}
            val bytes=f.files.toList();assertTrue(bytes.all{it.exists()})
            f.player.setMediaItems(f.items,1,900);f.player.prepare()
            f.drain{f.hardware.ops.contains(5)};assertTrue(bytes.all{it.exists()})
            f.hardware.allowRetire=true;f.drain{f.player.playbackState==Player.STATE_READY&&f.player.currentMediaItem?.mediaId=="b"}
            assertFalse(bytes.first().exists());assertEquals(900L,f.player.currentPosition)
        }
    }
    @Test fun cancellationDuringNativeExtentProbeCannotPublishCandidateOrAutoplay() {
        Fixture().use {f->
            f.hardware.holdProbe=true
            var candidate:NativeCallbackArrangement?=null;var failure:Throwable?=null
            val job=f.jobs.launch {try{candidate=f.player.prepareArrangement(f.document,f.items){true}}catch(t:Throwable){failure=t}}
            // Native control resumes on a separate real executor while its fake
            // looper is pumping. Main remains free to retire the coroutine.
            val owner=NativeCallbackPlayer::class.java.getDeclaredField("owner").apply{isAccessible=true}.get(f.player)
            val thread=owner.javaClass.getDeclaredField("thread").apply{isAccessible=true}.get(owner) as android.os.HandlerThread
            val pump=Thread {while(f.hardware.probeEntered.count!=0L){Shadows.shadowOf(thread.looper).idleFor(java.time.Duration.ofMillis(50));Thread.sleep(2)}}
            pump.start()
            val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
            while(f.hardware.probeEntered.count!=0L && System.nanoTime()<deadline){Shadows.shadowOf(Looper.getMainLooper()).idle();Thread.sleep(5)}
            check(f.hardware.probeEntered.count==0L)
            job.cancel();f.hardware.probePermit.countDown();pump.join()
            f.drain{job.isCompleted}
            assertNull(candidate);assertNotNull(failure);assertFalse(f.hardware.ops.contains(4));assertTrue(f.files.none{it.exists()})
        }
    }
    @Test fun preparationRetiredByStopCannotInstallGraph() {
        Fixture().use {f->
            var failure:Throwable?=null;var candidate:NativeCallbackArrangement?=null
            val job=f.jobs.launch {try{candidate=f.player.prepareArrangement(f.document,f.items){true}}catch(t:Throwable){failure=t}}
            // Start the operation, then revoke the real player's monotonic epoch.
            f.player.stop()
            f.drain{job.isCompleted}
            assertNull(candidate);assertNotNull(failure);assertFalse(f.hardware.ops.contains(4))
            assertTrue(f.files.none{it.exists()})
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun actualServiceApplyAndReturnKeepExactSourceGrantsAndNativeOwner() {
        val app=RuntimeEnvironment.getApplication() as NativeOverlapServiceApplication
        val controller=org.robolectric.Robolectric.buildService(com.soundq.android.playback.SoundQLibraryService::class.java).create()
        val service=controller.get()
        fun field(name:String)=service.javaClass.getDeclaredField(name).apply{isAccessible=true}
        val player=field("player").get(service) as NativeCallbackPlayer
        @Suppress("UNCHECKED_CAST") val grants=field("grants").get(service) as ConcurrentHashMap<String,MediaGrant>
        val scope=app.graph.session.capture()!!
        val items=listOf("source-a","source-b").map {id->
            val uri=Uri.parse("soundq://track/7/$id");grants[uri.toString()]=MediaGrant(scope,TrackId(7))
            MediaItem.Builder().setMediaId(id).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setExtras(Bundle().apply{putLong("trackId",7);putLong("durationMs",3000)}).build()).build()
        }
        val exact=grants.toMap()
        try {
            player.setMediaItems(items)
            app.graph.timeline.observe(scope,items.map{TimelineSource(it.mediaId,7,"Fixture",3000,QueueSegment.Context)})
            val original=app.graph.timeline.state.value.document
            check(app.graph.timeline.commit(TimelineEdit(original.revision,original.clips[1],EditKind.Placement,500)){true})
            val document=app.graph.timeline.state.value.document
            val request=app.graph.timeline.captureAudition(scope,document){true}!!
            val ctor=androidx.media3.session.MediaSession.ControllerInfo::class.java.declaredConstructors.single{it.parameterCount==8}.apply{isAccessible=true}
            val remote=ctor.parameterTypes[0].getConstructor(String::class.java,Int::class.javaPrimitiveType,Int::class.javaPrimitiveType).newInstance("fixture",android.os.Process.myPid(),service.applicationInfo.uid)
            val info=ctor.newInstance(remote,1,1,true,null,Bundle.EMPTY,0,true) as androidx.media3.session.MediaSession.ControllerInfo
            val callback=Class.forName("com.soundq.android.playback.SoundQLibraryService\$Callback").getDeclaredConstructor(service.javaClass).apply{isAccessible=true}.newInstance(service) as androidx.media3.session.MediaLibraryService.MediaLibrarySession.Callback
            val session=field("session").get(service) as androidx.media3.session.MediaSession
            val args=Bundle().apply {putString("service",field("serviceIncarnation").get(service) as String);putString("queue",field("sourceQueueIncarnation").get(service) as String);putLong("accountEpoch",scope.epoch);putString("request",request);putString("document",kotlinx.serialization.json.Json.encodeToString(document))}
            fun drain(predicate:()->Boolean) {
                val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
                while(true) {
                    val owner=NativeCallbackPlayer::class.java.getDeclaredField("owner").apply{isAccessible=true}.get(player)
                    val thread=owner.javaClass.getDeclaredField("thread").apply{isAccessible=true}.get(owner) as android.os.HandlerThread
                    Shadows.shadowOf(thread.looper).idleFor(java.time.Duration.ofMillis(50));Shadows.shadowOf(Looper.getMainLooper()).idle()
                    if(predicate())return
                    check(System.nanoTime()<deadline){"Service ACK deadline"};Thread.sleep(5)
                }
            }
            drain {field("account").get(service)!=null}
            val unsupported=callback.onCustomCommand(session,info,androidx.media3.session.SessionCommand(com.soundq.android.playback.SoundQLibraryService.PLAY_MIX,Bundle.EMPTY),Bundle.EMPTY).get()
            assertEquals(androidx.media3.session.SessionError.ERROR_NOT_SUPPORTED,unsupported.resultCode)
            val applied=callback.onCustomCommand(session,info,androidx.media3.session.SessionCommand(com.soundq.android.playback.SoundQLibraryService.APPLY_ARRANGEMENT,Bundle.EMPTY),args)
            drain{applied.isDone};assertEquals(0,applied.get().resultCode)
            drain{app.hardware.ops.contains(4)};assertEquals(1,player.mediaItemCount)
            assertTrue(exact.all{(uri,grant)->grants[uri]===grant})
            app.hardware.ready=true;drain{player.isPlaying}
            val accepted=field("acceptedArrangement").get(service) as com.soundq.android.playback.AcceptedArrangement
            player.seekTo(600);drain{player.currentPosition==600L&&player.performanceDecks.size==2}
            val event=android.os.SystemClock.uptimeMillis()*1000000L
            fun performance(action:String,payload:Bundle)=callback.onCustomCommand(session,info,androidx.media3.session.SessionCommand(action,Bundle.EMPTY),payload)
            val target=com.soundq.android.playback.PerformanceTarget(accepted.identity,"source-b")
            val begun=performance(com.soundq.android.playback.PerformanceCommands.BEGIN,com.soundq.android.playback.PerformanceCommands.target(target).apply {putLong("eventNanos",event-10000)})
            drain{begun.isDone};assertEquals(0,begun.get().resultCode)
            val lease=com.soundq.android.playback.PerformanceCommands.read<com.soundq.android.playback.ScratchLease>(begun.get().extras,"lease")!!
            assertEquals(2L,app.hardware.scratchCalls.last()[1])
            val stale=com.soundq.android.playback.PerformanceCommands.target(target.copy(identity=accepted.identity.copy(queue="retired"))).apply {putLong("eventNanos",event-9000)}
            assertNotEquals(0,performance(com.soundq.android.playback.PerformanceCommands.BEGIN,stale).get().resultCode)
            assertEquals(0,performance(com.soundq.android.playback.PerformanceCommands.MOVE,com.soundq.android.playback.PerformanceCommands.lease(lease,event-8000).apply {putDouble("rate",-0.001)}).get().resultCode)
            assertEquals(0,callback.onPlayerCommandRequest(session,info,Player.COMMAND_PLAY_PAUSE))
            player.pause();drain{app.hardware.scratchCalls.any{it[0]==4}}
            assertNotEquals(0,performance(com.soundq.android.playback.PerformanceCommands.END,com.soundq.android.playback.PerformanceCommands.lease(lease,event-7000)).get().resultCode)
            assertEquals(document,app.graph.timeline.state.value.document)
            player.prepare();player.play();drain{player.isPlaying}
            val qa=com.soundq.android.playback.QualifiedLiveGrid(120.0,0.0,0.0,"fixture-source","local:1")
            val qb=qa.copy(bpm=100.0,revision="local:2")
            // Only the loaded-waveform qualification boundary is supplied. The service, validator and JNI dispatch stay real.
            val qualificationType=Class.forName("com.soundq.android.data.timeline.TimelineRepository\$SourceQualification")
            val record=qualificationType.getDeclaredConstructor(Long::class.javaPrimitiveType).apply{isAccessible=true}.newInstance(3000L)
            qualificationType.getDeclaredField("sourceKey").apply{isAccessible=true}.set(record,"fixture-source")
            @Suppress("UNCHECKED_CAST") val qualifications=TimelineRepository::class.java.getDeclaredField("qualifications").apply{isAccessible=true}.get(app.graph.timeline) as MutableMap<Long,Any>
            qualifications[7L]=record
            val syncArgs=com.soundq.android.playback.PerformanceCommands.target(target).apply {putString("reference","source-a");putInt("beats",4);putString("referenceGrid",kotlinx.serialization.json.Json.encodeToString(qa));putString("incomingGrid",kotlinx.serialization.json.Json.encodeToString(qb))}
            val synced=performance(com.soundq.android.playback.PerformanceCommands.SYNC,syncArgs)
            drain{synced.isDone};assertEquals(0,synced.get().resultCode);assertEquals(2L,app.hardware.syncCalls.last()[0])
            app.hardware.syncState=2;drain{player.performanceDecks["source-b"]?.syncState==com.soundq.android.playback.LiveSyncState.Locked}
            app.hardware.holdUnlinkAck=true
            qualificationType.getDeclaredField("revision").apply{isAccessible=true}.setLong(record,1L)
            drain{app.hardware.syncCalls.last()[2]==0}
            val qualificationChecks=field("liveQualifications").get(service) as Map<*,*>
            assertEquals(1,qualificationChecks.size)
            assertTrue(player.performanceDecks["source-b"]?.syncState!=com.soundq.android.playback.LiveSyncState.Locked)
            app.hardware.syncState=2
            drain{player.performanceDecks["source-b"]==null}
            val projection=com.soundq.android.playback.ControllerProjection(app,session.token)
            try {
                drain{projection.state.value.connection==com.soundq.android.playback.PlaybackProjection.Connection.Connected&&projection.state.value.canPerformArrangement}
                assertEquals(accepted.identity,projection.state.value.arrangement?.identity)
                assertTrue(projection.state.value.performanceDecks.size<=2)
                var projectedLease:com.soundq.android.playback.ScratchLease?=null
                projection.beginScratch(accepted.identity,"source-a",android.os.SystemClock.uptimeMillis()*1000000L){projectedLease=it}
                drain{projectedLease!=null}
                val live=projectedLease!!
                val t=android.os.SystemClock.uptimeMillis()*1000000L
                repeat(1000){projection.moveScratch(live,0.0001,t+it+1)}
                projection.endScratch(live,t+1001)
                drain{app.hardware.scratchCalls.any{it[0]==3&&it[2]==live.id}}
                assertTrue(app.hardware.scratchCalls.count{it[0]==2&&it[2]==live.id}<=2)
            }finally{projection.close()}
            assertEquals(document,app.graph.timeline.state.value.document)
            assertTrue(exact.all{(uri,grant)->grants[uri]===grant})
            player.stop()
            assertEquals("Stop must restore authorized source rows, not leave an unpreparable synthetic URI",items,(0 until player.mediaItemCount).map(player::getMediaItemAt))
            assertNull(field("acceptedArrangement").get(service));assertFalse(player.playWhenReady)
            assertTrue(exact.all{(uri,grant)->grants[uri]===grant})
            app.hardware.allowRetire=true;player.prepare();player.play();drain{player.isPlaying}
            player.pause()
            val requestAgain=app.graph.timeline.captureAudition(scope,document){true}!!
            args.putString("queue",field("sourceQueueIncarnation").get(service) as String);args.putString("request",requestAgain)
            val reapplied=callback.onCustomCommand(session,info,androidx.media3.session.SessionCommand(com.soundq.android.playback.SoundQLibraryService.APPLY_ARRANGEMENT,Bundle.EMPTY),args)
            drain{reapplied.isDone};assertEquals(0,reapplied.get().resultCode);drain{player.isPlaying}
            app.hardware.actualFrame=72000.5 // New callback cursor not yet observed by the 50ms projection.
            val returned=callback.onCustomCommand(session,info,androidx.media3.session.SessionCommand(com.soundq.android.playback.SoundQLibraryService.RETURN_SOURCES,Bundle.EMPTY),Bundle.EMPTY)
            drain{returned.isDone}
            assertEquals(0,returned.get().resultCode);assertEquals(items,(0 until player.mediaItemCount).map(player::getMediaItemAt));assertFalse(player.isPlaying)
            assertEquals("Return to sources must consume exact current native cursor, not authored/slip mapping or previous poll",1500L,player.currentPosition)
            assertTrue(exact.all{(uri,grant)->grants[uri]===grant})
            app.hardware.allowRetire=true;player.prepare();player.play();drain{player.playbackState==Player.STATE_READY&&player.isPlaying}
        } finally { app.hardware.allowRetire=true;controller.destroy();val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);while(!player.nativeReleased.isDone && System.nanoTime()<end){Shadows.shadowOf(Looper.getMainLooper()).idle();Thread.sleep(5)};app.graph.close() }
    }
    /** Real service/session/controller and pinned Media3; only native hardware and loaded waveform are supplied. */
    private class ServiceFixture:AutoCloseable {
        val app=RuntimeEnvironment.getApplication() as NativeOverlapServiceApplication
        val serviceController=org.robolectric.Robolectric.buildService(com.soundq.android.playback.SoundQLibraryService::class.java).create()
        val service=serviceController.get()
        fun field(name:String)=service.javaClass.getDeclaredField(name).apply{isAccessible=true}
        val player=field("player").get(service) as NativeCallbackPlayer
        val hardware get()=app.hardware
        @Suppress("UNCHECKED_CAST") val grants=field("grants").get(service) as ConcurrentHashMap<String,MediaGrant>
        val scope=app.graph.session.capture()!!
        val session=field("session").get(service) as androidx.media3.session.MediaSession
        val callback=Class.forName("com.soundq.android.playback.SoundQLibraryService\$Callback").getDeclaredConstructor(service.javaClass).apply{isAccessible=true}.newInstance(service) as androidx.media3.session.MediaLibraryService.MediaLibrarySession.Callback
        val info:androidx.media3.session.MediaSession.ControllerInfo
        val accepted:com.soundq.android.playback.AcceptedArrangement
        val document:TimelineDocument
        val qualification:Any
        val qa=com.soundq.android.playback.QualifiedLiveGrid(120.0,0.0,0.0,"fixture-source","local:1")
        val qb=qa.copy(bpm=100.0,revision="local:2")
        init {
            val ctor=androidx.media3.session.MediaSession.ControllerInfo::class.java.declaredConstructors.single{it.parameterCount==8}.apply{isAccessible=true}
            val remote=ctor.parameterTypes[0].getConstructor(String::class.java,Int::class.javaPrimitiveType,Int::class.javaPrimitiveType).newInstance("fixture",android.os.Process.myPid(),service.applicationInfo.uid)
            info=ctor.newInstance(remote,1,1,true,null,Bundle.EMPTY,0,true) as androidx.media3.session.MediaSession.ControllerInfo
            val items=listOf("source-a","source-b").map {id->
                val uri=Uri.parse("soundq://track/7/$id");grants[uri.toString()]=MediaGrant(scope,TrackId(7))
                MediaItem.Builder().setMediaId(id).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setExtras(Bundle().apply{putLong("trackId",7);putLong("durationMs",3000)}).build()).build()
            }
            player.setMediaItems(items)
            app.graph.timeline.observe(scope,items.map{TimelineSource(it.mediaId,7,"Fixture",3000,QueueSegment.Context)})
            val original=app.graph.timeline.state.value.document
            check(app.graph.timeline.commit(TimelineEdit(original.revision,original.clips[1],EditKind.Placement,500)){true})
            document=app.graph.timeline.state.value.document
            val request=app.graph.timeline.captureAudition(scope,document){true}!!
            drain{field("account").get(service)!=null}
            val applied=command(com.soundq.android.playback.SoundQLibraryService.APPLY_ARRANGEMENT,Bundle().apply {
                putString("service",field("serviceIncarnation").get(service) as String);putString("queue",field("sourceQueueIncarnation").get(service) as String)
                putLong("accountEpoch",scope.epoch);putString("request",request);putString("document",kotlinx.serialization.json.Json.encodeToString(document))
            })
            drain{applied.isDone};assertEquals(0,applied.get().resultCode)
            hardware.ready=true;drain{player.isPlaying}
            accepted=field("acceptedArrangement").get(service) as com.soundq.android.playback.AcceptedArrangement
            player.seekTo(600);drain{player.currentPosition==600L&&player.performanceDecks.size==2}
            val type=Class.forName("com.soundq.android.data.timeline.TimelineRepository\$SourceQualification")
            qualification=type.getDeclaredConstructor(Long::class.javaPrimitiveType).apply{isAccessible=true}.newInstance(3000L)
            type.getDeclaredField("sourceKey").apply{isAccessible=true}.set(qualification,"fixture-source")
            @Suppress("UNCHECKED_CAST") val qualifications=TimelineRepository::class.java.getDeclaredField("qualifications").apply{isAccessible=true}.get(app.graph.timeline) as MutableMap<Long,Any>
            qualifications[7L]=qualification
        }
        fun target()=com.soundq.android.playback.PerformanceTarget(accepted.identity,"source-b")
        fun command(action:String,args:Bundle)=callback.onCustomCommand(session,info,androidx.media3.session.SessionCommand(action,Bundle.EMPTY),args)
        fun sync(grid:com.soundq.android.playback.QualifiedLiveGrid=qb)=command(com.soundq.android.playback.PerformanceCommands.SYNC,com.soundq.android.playback.PerformanceCommands.target(target()).apply {
            putString("reference","source-a");putInt("beats",4);putString("referenceGrid",kotlinx.serialization.json.Json.encodeToString(qa));putString("incomingGrid",kotlinx.serialization.json.Json.encodeToString(grid))
        })
        fun drain(predicate:()->Boolean) {
            val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
            while(true) {
                val owner=NativeCallbackPlayer::class.java.getDeclaredField("owner").apply{isAccessible=true}.get(player)
                val thread=owner.javaClass.getDeclaredField("thread").apply{isAccessible=true}.get(owner) as android.os.HandlerThread
                Shadows.shadowOf(thread.looper).idleFor(java.time.Duration.ofMillis(50));Shadows.shadowOf(Looper.getMainLooper()).idle()
                if(predicate())return
                check(System.nanoTime()<deadline){"Service lifecycle ACK deadline"};Thread.sleep(5)
            }
        }
        fun projection():com.soundq.android.playback.ControllerProjection {
            val projection=com.soundq.android.playback.ControllerProjection(app,session.token)
            drain{projection.state.value.connection==com.soundq.android.playback.PlaybackProjection.Connection.Connected&&projection.state.value.canPerformArrangement}
            return projection
        }
        fun serviceQualifications()=field("liveQualifications").get(service) as Map<*,*>
        fun playerQualifications()=NativeCallbackPlayer::class.java.getDeclaredField("syncQualifications").apply{isAccessible=true}.get(player) as Map<*,*>
        override fun close() {
            hardware.allowRetire=true;serviceController.destroy()
            val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
            while(!player.nativeReleased.isDone&&System.nanoTime()<end){Shadows.shadowOf(Looper.getMainLooper()).idle();Thread.sleep(5)}
            assertTrue(player.nativeReleased.isDone);app.graph.close()
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun actualServiceTerminalsAcceptSameMillisecondAndStalePhysicalTimeWithoutChangingMoves() {
        ServiceFixture().use {f->
            listOf(false to false,true to false,false to true,true to true).forEach {(cancel,stale)->
                val begin=android.os.SystemClock.uptimeMillis()*1_000_000L
                val begun=f.command(com.soundq.android.playback.PerformanceCommands.BEGIN,com.soundq.android.playback.PerformanceCommands.target(f.target()).apply{putLong("eventNanos",begin)})
                f.drain{begun.isDone};assertEquals(0,begun.get().resultCode)
                val lease=com.soundq.android.playback.PerformanceCommands.read<com.soundq.android.playback.ScratchLease>(begun.get().extras,"lease")!!
                val move=android.os.SystemClock.uptimeMillis()*1_000_000L
                assertEquals(0,f.command(com.soundq.android.playback.PerformanceCommands.MOVE,com.soundq.android.playback.PerformanceCommands.lease(lease,move).apply{putDouble("rate",-0.125)}).get().resultCode)
                f.drain{f.hardware.moveEvent==move}
                val physical=if(stale)begin-3_000_000_000L else move
                val terminal=f.command(if(cancel)com.soundq.android.playback.PerformanceCommands.CANCEL else com.soundq.android.playback.PerformanceCommands.END,com.soundq.android.playback.PerformanceCommands.lease(lease,physical))
                assertEquals("Terminal must not strand the lease on equal/stale physical time",0,terminal.get().resultCode)
                f.drain{f.hardware.scratchInstance==0L}
                assertEquals(move,f.hardware.scratchCalls.last{it[0]==2}[3])
                assertTrue(f.hardware.scratchCalls.last()[3].toLong()>move)
                assertNotEquals(0,f.command(com.soundq.android.playback.PerformanceCommands.END,com.soundq.android.playback.PerformanceCommands.lease(lease,move)).get().resultCode)
            }
            val projection=f.projection()
            try {
                listOf(false,true).forEach {cancel->
                    var lease:com.soundq.android.playback.ScratchLease?=null
                    projection.beginScratch(f.accepted.identity,"source-b",android.os.SystemClock.uptimeMillis()*1_000_000L){lease=it};f.drain{lease!=null}
                    val move=android.os.SystemClock.uptimeMillis()*1_000_000L
                    projection.moveScratch(lease!!,-0.25,move);f.drain{f.hardware.moveEvent==move}
                    if(cancel)projection.cancelScratch(lease!!,move-3_000_000_000L) else projection.endScratch(lease!!,move)
                    f.drain{f.hardware.scratchInstance==0L}
                    assertTrue(f.hardware.scratchCalls.last()[3].toLong()>move)
                }
            } finally {projection.close()}
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun actualServiceQualificationRetiresOnlyAfterObservedOffThenFreshGridCanSyncSameInstall() {
        ServiceFixture().use {f->
            val result=f.sync();f.drain{result.isDone};assertEquals(0,result.get().resultCode)
            f.hardware.syncState=2;f.drain{f.player.performanceDecks["source-b"]?.syncState==com.soundq.android.playback.LiveSyncState.Locked}
            f.hardware.holdUnlinkAck=true
            f.qualification.javaClass.getDeclaredField("revision").apply{isAccessible=true}.setLong(f.qualification,1L)
            f.drain{f.hardware.syncCalls.any{it[2]==0}}
            assertEquals(1,f.serviceQualifications().size);assertEquals(1,f.playerQualifications().size)
            assertNull("Stale Locked must stay fenced after unlink admission",f.player.performanceDecks["source-b"])
            repeat(4){f.drain{true}}
            val retirementCalls=f.hardware.syncCalls.count{it[2]==0}
            f.hardware.syncState=0;f.hardware.syncReference=0;f.hardware.syncBeats=0
            repeat(2){f.drain{true}}
            assertEquals("Observed native Off must restore the installed incoming",com.soundq.android.playback.LiveSyncState.Off,f.player.performanceDecks["source-b"]?.syncState)
            assertEquals("Retirement must not resubmit unlink every publication",1,retirementCalls)
            assertTrue("Obsolete service qualification must retire at Off",f.serviceQualifications().isEmpty())
            assertTrue("Obsolete player qualification must retire at Off",f.playerQualifications().isEmpty())
            val projection=f.projection()
            try {assertEquals(com.soundq.android.playback.LiveSyncState.Off,projection.state.value.performanceDecks["source-b"]?.syncState)}finally{projection.close()}
            val fresh=f.sync(f.qb.copy(bpm=110.0,revision="local:fresh"));f.drain{fresh.isDone};assertEquals(0,fresh.get().resultCode)
            f.hardware.syncState=2;f.drain{f.player.performanceDecks["source-b"]?.syncState==com.soundq.android.playback.LiveSyncState.Locked}
            assertSame(f.accepted,f.field("acceptedArrangement").get(f.service));assertEquals(f.document,f.app.graph.timeline.state.value.document)
            assertEquals(2,f.hardware.syncCalls.count{it[2]==4})
            // A late, mismatched install snapshot cannot retire the fresh capture.
            val stale=NativeCallbackSnapshot.parse(f.hardware.state(1)).copy(scheduleRevision=Long.MAX_VALUE)
            NativeCallbackPlayer::class.java.getDeclaredMethod("observe",NativeCallbackSnapshot::class.java).apply{isAccessible=true}.invoke(f.player,stale)
            assertEquals(1,f.serviceQualifications().size);assertEquals(1,f.playerQualifications().size)
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun actualControllerSyncRefusalReopensAndFastUnlinkRequiresNewOffPublication() {
        ServiceFixture().use {f->
            val projection=f.projection()
            try {
                var refused:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb.copy(sourceKey="missing")){refused=it}
                f.drain{refused!=null};assertFalse(refused!!);assertTrue(f.hardware.syncCalls.isEmpty())
                var admitted:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb){admitted=it}
                f.drain{admitted!=null};assertTrue(admitted!!)
                f.drain{projection.state.value.performanceDecks["source-b"]?.syncState==com.soundq.android.playback.LiveSyncState.Pending}
                projection.unlinkIncoming(f.accepted.identity,"source-b")
                f.drain{projection.state.value.performanceDecks["source-b"]?.syncState==com.soundq.android.playback.LiveSyncState.Off}
                // Drain a current native publication, not an RPC admission receipt.
                repeat(2){f.drain{true}}
                var fresh:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb.copy(revision="local:fresh")){fresh=it}
                f.drain{fresh!=null};assertTrue("Observed Off must allow explicit fresh intent",fresh!!)
                assertEquals(2,f.hardware.syncCalls.count{it[2]==4})
            } finally {projection.close()}
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun actualControllerSyncLatchSurvivesAdmissionWithoutAckAndRemountUntilUnlinkObservedOff() {
        ServiceFixture().use {f->
            val projection=f.projection()
            try {
                f.hardware.holdSyncAck=true
                var first:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb){first=it}
                f.drain{first!=null};assertTrue(first!!)
                assertEquals(com.soundq.android.playback.LiveSyncState.Off,projection.state.value.performanceDecks["source-b"]?.syncState)
                var second:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb.copy(bpm=110.0)){second=it}
                f.drain{second!=null};assertFalse("JNI admission without native ACK must retain canonical latch",second!!)
                assertEquals(1,f.hardware.syncCalls.count{it[2]==4})
                val direct=f.sync(f.qb.copy(bpm=111.0));f.drain{direct.isDone};assertNotEquals(0,direct.get().resultCode)
                val remounted=f.projection()
                try {
                    var refused:Boolean?=null
                    remounted.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb.copy(bpm=112.0)){refused=it}
                    f.drain{refused!=null};assertFalse("A new controller cannot bypass service admission fence",refused!!)
                }finally{remounted.close()}
                f.hardware.holdSyncAck=false;f.hardware.syncReference=1;f.hardware.syncBeats=4;f.hardware.syncState=2
                f.drain{projection.state.value.performanceDecks["source-b"]?.syncState==com.soundq.android.playback.LiveSyncState.Locked}
                f.hardware.holdUnlinkAck=true;projection.unlinkIncoming(f.accepted.identity,"source-b")
                f.drain{f.hardware.syncCalls.any{it[2]==0}}
                var premature:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb){premature=it};f.drain{premature!=null};assertFalse(premature!!)
                f.hardware.syncState=0;f.hardware.syncReference=0;f.hardware.syncBeats=0
                f.drain{projection.state.value.performanceDecks["source-b"]?.syncState==com.soundq.android.playback.LiveSyncState.Off}
                var fresh:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb.copy(bpm=115.0)){fresh=it};f.drain{fresh!=null};assertTrue(fresh!!)
                assertEquals(2,f.hardware.syncCalls.count{it[2]==4})
            } finally {projection.close()}
        }
    }
    /** Invoke the new callback seam when present; the preserved predecessor still executes real Unlink. */
    private fun unlinkCompletion(projection:com.soundq.android.playback.ControllerProjection,identity:com.soundq.android.playback.ArrangementIdentity,incoming:String,done:(Boolean)->Unit) {
        val method=projection.javaClass.methods.singleOrNull{it.name=="unlinkIncoming"&&it.parameterCount==3}
        if(method!=null)method.invoke(projection,identity,incoming,done) else projection.unlinkIncoming(identity,incoming)
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun actualControllerUnlinkCompletionWaitsForNewOffPublicationNotRpcOrOldOffReplay() {
        ServiceFixture().use {f->
            val projection=f.projection()
            val publication=f.player.onPerformanceChanged
            fun admission():Any? {
                val field=projection.javaClass.getDeclaredField("syncAdmissions").apply{isAccessible=true}
                return (field.get(projection) as Map<*,*>)["source-b"]
            }
            fun unlinkAccepted()=admission()?.let {it.javaClass.getDeclaredField("unlinkPublication").apply{isAccessible=true}.get(it)!=null}==true
            fun publish()=f.service.javaClass.getDeclaredMethod("publishSessionExtras").apply{isAccessible=true}.invoke(f.service)
            try {
                f.hardware.holdSyncAck=true
                f.player.onPerformanceChanged=null // Hold real session publication independently of RPC admission.
                var admitted:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb){admitted=it}
                f.drain{admitted!=null};assertTrue(admitted!!)
                assertEquals(com.soundq.android.playback.LiveSyncState.Off,projection.state.value.performanceDecks["source-b"]?.syncState)
                val completions=mutableListOf<Boolean>()
                unlinkCompletion(projection,f.accepted.identity,"source-b"){completions.add(it)}
                f.drain{unlinkAccepted()}
                assertTrue("RPC success must not acknowledge the held Off publication",completions.isEmpty())
                repeat(2){projection.javaClass.getDeclaredMethod("publish").apply{isAccessible=true}.invoke(projection)}
                assertTrue("Replaying old Off must not settle explicit Unlink",completions.isEmpty())
                var premature:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb.copy(bpm=110.0)){premature=it}
                assertEquals(false,premature)
                f.drain{f.player.performanceDecks["source-b"]?.syncState==com.soundq.android.playback.LiveSyncState.Off}
                publish();f.drain{true}
                assertEquals("Only the newer observed Off settles the UI escape",listOf(true),completions)
                assertNull(admission())
                var fresh:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb.copy(bpm=115.0)){fresh=it}
                f.drain{fresh!=null};assertTrue(fresh!!)
                val freshAdmission=admission()
                repeat(2){publish();f.drain{true}}
                assertSame("Old Off after recovery must not clear a fresh admission",freshAdmission,admission())
                assertEquals(listOf(true),completions)
                assertEquals(2,f.hardware.syncCalls.count{it[2]==4})
            } finally {f.player.onPerformanceChanged=publication;projection.close()}
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun actualControllerUnlinkRefusalAndCloseSettleFalseAndRetainSyncFence() {
        ServiceFixture().use {f->
            val projection=f.projection()
            val publication=f.player.onPerformanceChanged
            try {
                f.hardware.holdSyncAck=true;f.player.onPerformanceChanged=null
                var admitted:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb){admitted=it}
                f.drain{admitted!=null};assertTrue(admitted!!)
                val stale=mutableListOf<Boolean>()
                unlinkCompletion(projection,f.accepted.identity.copy(queue="retired"),"source-b"){stale.add(it)}
                assertEquals(listOf(false),stale)
                val refused=mutableListOf<Boolean>()
                unlinkCompletion(projection,f.accepted.identity,"absent"){refused.add(it)}
                f.drain{refused.isNotEmpty()};assertEquals(listOf(false),refused)
                var blocked:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb){blocked=it}
                assertEquals(false,blocked)
                f.hardware.ready=false
                val targetRefused=mutableListOf<Boolean>()
                unlinkCompletion(projection,f.accepted.identity,"source-b"){targetRefused.add(it)}
                f.drain{targetRefused.isNotEmpty()};assertEquals(listOf(false),targetRefused)
                f.hardware.ready=true;f.drain{f.player.canPerform(f.accepted.identity)}
                blocked=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb){blocked=it}
                assertEquals("Refused Unlink must retain its incoming's canonical Sync latch",false,blocked)
                val closed=mutableListOf<Boolean>()
                unlinkCompletion(projection,f.accepted.identity,"source-b"){closed.add(it)}
                f.drain{f.hardware.syncCalls.any{it[2]==0}}
                assertTrue(closed.isEmpty())
                val duplicate=mutableListOf<Boolean>()
                unlinkCompletion(projection,f.accepted.identity,"source-b"){duplicate.add(it)}
                assertEquals(listOf(false),duplicate)
                projection.close();assertEquals(listOf(false),closed)
                f.service.javaClass.getDeclaredMethod("publishSessionExtras").apply{isAccessible=true}.invoke(f.service)
                f.drain{true};assertEquals(listOf(false),closed)
                val afterClose=mutableListOf<Boolean>()
                unlinkCompletion(projection,f.accepted.identity,"source-b"){afterClose.add(it)}
                assertEquals(listOf(false),afterClose)
            } finally {f.player.onPerformanceChanged=publication;projection.close()}
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun actualControllerUnlinkIdentityRetirementCannotSettleOrClearFreshSameOccurrenceAdmission() {
        ServiceFixture().use {f->
            val projection=f.projection()
            val publication=f.player.onPerformanceChanged
            fun admission():Any?=(projection.javaClass.getDeclaredField("syncAdmissions").apply{isAccessible=true}.get(projection) as Map<*,*>)["source-b"]
            fun publish()=f.service.javaClass.getDeclaredMethod("publishSessionExtras").apply{isAccessible=true}.invoke(f.service)
            try {
                f.hardware.holdSyncAck=true;f.player.onPerformanceChanged=null
                var admitted:Boolean?=null
                projection.syncIncoming(f.accepted.identity,"source-a","source-b",4,f.qa,f.qb){admitted=it}
                f.drain{admitted!=null};assertTrue(admitted!!)
                val retired=mutableListOf<Boolean>()
                unlinkCompletion(projection,f.accepted.identity,"source-b"){retired.add(it)}
                val oldAdmission=admission()!!
                f.drain{oldAdmission.javaClass.getDeclaredField("unlinkPublication").apply{isAccessible=true}.get(oldAdmission)!=null}
                assertTrue(retired.isEmpty())
                val returned=f.command(com.soundq.android.playback.SoundQLibraryService.RETURN_SOURCES,Bundle.EMPTY)
                f.drain{returned.isDone&&projection.state.value.arrangement==null}
                assertEquals(0,returned.get().resultCode);assertEquals(listOf(false),retired)
                f.hardware.allowRetire=true
                f.drain{f.player.preparationSettled}
                val request=f.app.graph.timeline.captureAudition(f.scope,f.document){true}!!
                val applied=f.command(com.soundq.android.playback.SoundQLibraryService.APPLY_ARRANGEMENT,Bundle().apply {
                    putString("service",f.field("serviceIncarnation").get(f.service) as String)
                    putString("queue",f.field("sourceQueueIncarnation").get(f.service) as String)
                    putLong("accountEpoch",f.scope.epoch);putString("request",request);putString("document",kotlinx.serialization.json.Json.encodeToString(f.document))
                })
                f.drain{applied.isDone};assertEquals(0,applied.get().resultCode)
                f.drain{f.player.isPlaying}
                f.player.seekTo(600);f.drain{f.player.currentPosition==600L&&f.player.performanceDecks.size==2}
                publish();f.drain{projection.state.value.canPerformArrangement}
                val identity=projection.state.value.arrangement!!.identity
                assertNotEquals(f.accepted.identity,identity)
                var fresh:Boolean?=null
                projection.syncIncoming(identity,"source-a","source-b",4,f.qa,f.qb.copy(bpm=115.0)){fresh=it}
                f.drain{fresh!=null};assertTrue(fresh!!)
                val freshAdmission=admission()!!
                val stale=mutableListOf<Boolean>()
                unlinkCompletion(projection,f.accepted.identity,"source-b"){stale.add(it)}
                assertEquals(listOf(false),stale)
                // Duplicate terminal delivery to a retained old admission cannot invoke its waiter again.
                oldAdmission.javaClass.getDeclaredMethod("completeUnlink",Boolean::class.javaPrimitiveType).apply{isAccessible=true}.invoke(oldAdmission,true)
                repeat(2){publish();f.drain{true}}
                assertEquals(listOf(false),retired)
                assertSame(freshAdmission,admission())
                var replay:Boolean?=null
                projection.syncIncoming(identity,"source-a","source-b",4,f.qa,f.qb){replay=it}
                assertEquals(false,replay)
            } finally {f.player.onPerformanceChanged=publication;projection.close()}
        }
    }
    @Test fun accountRetirementStopsGraphAndRetainsBytesUntilWorkerReceipt() {
        Fixture().use {f->val candidate=f.prepare();f.install(candidate);f.hardware.ready=true;f.drain{f.player.playbackState==Player.STATE_READY}
            f.player.play();f.drain{f.player.isPlaying};val bytes=f.files.toList()
            f.graph.session.accept(f.graph.session.beginIntent(),SecretTokens("successor","successor","other-account"))
            f.drain{f.hardware.ops.contains(5)}
            assertEquals(0,f.player.mediaItemCount);assertFalse(f.player.isPlaying);assertTrue(bytes.all{it.exists()})
            f.hardware.allowRetire=true;f.drain{bytes.none{it.exists()}}
        }
    }
    @Test fun revokedExactGrantCannotPlayInstalledGraph() {
        Fixture().use {f->val candidate=f.prepare();f.install(candidate);f.hardware.ready=true;f.drain{f.player.playbackState==Player.STATE_READY}
            f.grants.clear();f.player.play();f.drain{f.hardware.ops.contains(5)};assertFalse(f.hardware.ops.contains(1));assertFalse(f.player.isPlaying)
        }
    }
    private fun ServiceFixture.tempoSource():TempoSourceIdentity {
        val clip=document.clips.single {it.occurrence=="source-b"}
        val source=TempoSourceTiming("fixture-source","local:bpm","local_bpm",120.0,0.0,beatAnchorKnown=false)
        @Suppress("UNCHECKED_CAST") val local=qualification.javaClass.getDeclaredField("localTempos").apply{isAccessible=true}.get(qualification) as MutableSet<TempoSourceTiming>
        local.add(source)
        return source.identity(clip)
    }
    private fun ServiceFixture.beginTempo(projection:com.soundq.android.playback.ControllerProjection):com.soundq.android.playback.TempoPreviewLease {
        var done=false;var lease:com.soundq.android.playback.TempoPreviewLease?=null;var message:String?=null
        projection.beginTempo(accepted.identity,"source-b",tempoSource()){l,m->lease=l;message=m;done=true}
        drain{done};assertNotNull(message,lease);return lease!!
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoControllerLatestWinsCancelUsesHigherTagAndSaveDoesNotRestartNative() {
        ServiceFixture().use {f->
            val projection=f.projection()
            try {
                val lease=f.beginTempo(projection)
                f.hardware.holdTempoAck=true
                repeat(1000){i->projection.previewTempo(lease,130.0+i/1000.0)}
                f.drain{f.hardware.tempoCalls.lastOrNull()?.target==130.999}
                assertTrue("Controller and player keep bounded latest-only motion",f.hardware.tempoCalls.size<10)
                assertEquals(com.soundq.android.playback.TempoPreviewPhase.Preparing,f.player.tempoPreviewState!!.phase)
                assertEquals(f.document,f.app.graph.timeline.state.value.document)
                val preview=f.hardware.tempoCalls.last()
                var cancelled:Boolean?=null
                projection.cancelTempo(lease){ok,_->cancelled=ok}
                f.drain{f.hardware.tempoCalls.last().target==120.0}
                assertNull("Admission is not rollback ACK",cancelled)
                assertTrue(f.hardware.tempoCalls.last().tag>preview.tag)
                projection.previewTempo(lease,145.0)
                f.hardware.holdTempoAck=false
                f.drain{cancelled!=null};assertTrue(cancelled!!)
                assertEquals(120.0,f.player.tempoPreviewState!!.appliedBpm,0.0)
                assertEquals(f.document,f.app.graph.timeline.state.value.document)
                val second=f.beginTempo(projection)
                projection.previewTempo(second,138.5)
                f.drain{f.player.tempoPreviewState!!.phase==com.soundq.android.playback.TempoPreviewPhase.Applied}
                val operations=f.hardware.ops.toList()
                val nativeRevision=f.hardware.tempoCalls.last().revision
                var saved:Boolean?=null
                projection.saveTempo(second){ok,_->saved=ok};f.drain{saved!=null}
                assertTrue(saved!!);assertTrue(f.player.isPlaying)
                assertEquals("Save must not call JNI transport, seek or install",operations,f.hardware.ops.toList())
                val durable=f.app.graph.timeline.state.value.document
                assertEquals(138.5,durable.playbackTempos.single().playbackBpm,0.0)
                assertTrue(f.app.graph.timeline.state.value.canUndo)
                val accepted=f.field("acceptedArrangement").get(f.service) as com.soundq.android.playback.AcceptedArrangement
                assertEquals(durable,accepted.document);assertEquals(durable.revision,accepted.identity.revision)
                assertEquals(f.accepted.identity.install,accepted.identity.install)
                f.drain{projection.state.value.arrangement?.identity==accepted.identity}
                var next:com.soundq.android.playback.TempoPreviewLease?=null
                projection.beginTempo(accepted.identity,"source-b",f.tempoSource()){l,_->next=l};f.drain{next!=null}
                projection.previewTempo(next!!,133.0);f.drain{f.hardware.tempoCalls.last().target==133.0}
                assertEquals("Durable revision is not native installed schedule revision",nativeRevision,f.hardware.tempoCalls.last().revision)
                projection.cancelTempo(next)
            } finally {projection.close()}
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoWaitingSaveIsRevokedByCancelAndLatePreviewCannotPersist() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection);f.hardware.holdTempoAck=true
            projection.previewTempo(lease,144.0);f.drain{f.hardware.tempoCalls.isNotEmpty()}
            var saved:Boolean?=null;projection.saveTempo(lease){ok,_->saved=ok}
            f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Saving}
            var cancelled:Boolean?=null;projection.cancelTempo(lease){ok,_->cancelled=ok}
            f.drain{f.hardware.tempoCalls.last().target==120.0}
            f.hardware.holdTempoAck=false;f.drain{cancelled!=null&&saved!=null}
            assertTrue(cancelled!!);assertFalse(saved!!)
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
        }finally{projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoQualificationAbaAndTransportRevokeNeverRestoreOverSuccessor() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection);f.hardware.holdTempoAck=true
            projection.previewTempo(lease,144.0);f.drain{f.hardware.tempoCalls.isNotEmpty()}
            val count=f.hardware.tempoCalls.size
            f.qualification.javaClass.getDeclaredField("revision").apply{isAccessible=true}.setLong(f.qualification,1)
            f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Retired}
            projection.cancelTempo(lease);repeat(2){f.drain{true}}
            assertEquals(count,f.hardware.tempoCalls.size)
            f.qualification.javaClass.getDeclaredField("revision").apply{isAccessible=true}.setLong(f.qualification,0)
            assertFalse(f.player.previewTempo(lease,999,150.0,0))
            f.player.seekTo(1000);f.hardware.holdTempoAck=false
            f.drain{f.player.currentPosition==1000L}
            assertFalse(f.player.previewTempo(lease,1000,150.0,0))
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
        }finally{projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoRefusalIsNotPersistedAndRuntimeSlowdownSurvivesOldAuthoredEnd() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection);f.hardware.refuseTempo=true
            projection.previewTempo(lease,144.0);f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Refused}
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
            f.hardware.refuseTempo=false;projection.previewTempo(lease,108.0)
            f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Applied}
            f.hardware.scheduleDurationMs=4500;f.hardware.globalOverride=3600
            f.drain{f.player.currentPosition==3600L}
            assertNotNull("Live deck must not disappear at obsolete durable EOF",f.player.performanceDecks["source-b"])
            projection.cancelTempo(lease)
        }finally{projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoWriteFailurePreservesBytesAndKeepsTruthfulLiveOnlyThenCancelRestores() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection)
            projection.previewTempo(lease,141.0);f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Applied}
            f.hardware.previewSlots=0 // terminal headroom must survive failed durable write
            val durable=File(f.app.graph.directory,"timeline").listFiles()!!.single {it.name.startsWith("arrangement-")&&it.name.endsWith(".v1.json")}
            val bytes=durable.readBytes()
            val blocked=File(durable.parentFile,".${durable.name}.pending");assertTrue(blocked.mkdir())
            try {
                var saved:Boolean?=null
                projection.saveTempo(lease){ok,_->saved=ok};f.drain{saved!=null}
                assertFalse(saved!!);assertArrayEquals(bytes,durable.readBytes())
                assertEquals(f.document,f.app.graph.timeline.state.value.document)
                assertTrue(f.player.tempoPreviewState!!.message!!.contains("live only"))
                assertTrue(f.player.isPlaying)
            }finally{blocked.delete()}
            var restored:Boolean?=null;projection.cancelTempo(lease){ok,_->restored=ok};f.drain{restored!=null};assertTrue(restored!!)
            assertArrayEquals(bytes,durable.readBytes())
        }finally{projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoControllerDisposalRestoresAndAccountRetirementCannotRestoreSuccessor() {
        ServiceFixture().use {f->
            val projection=f.projection();val lease=f.beginTempo(projection)
            projection.previewTempo(lease,144.0);f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Applied}
            f.hardware.previewSlots=0
            projection.previewTempo(lease,146.0);f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Refused}
            projection.close()
            f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Restored}
            assertEquals(1,f.hardware.restoreCalls)
            f.hardware.previewSlots=Int.MAX_VALUE
            assertEquals(120.0,f.player.tempoPreviewState!!.appliedBpm,0.0)
            val fresh=f.projection();try {
                val second=f.beginTempo(fresh);fresh.previewTempo(second,140.0)
                f.drain{f.hardware.tempoCalls.last().target==140.0}
                val count=f.hardware.tempoCalls.size
                f.hardware.allowRetire=true
                f.app.graph.session.accept(f.app.graph.session.beginIntent(),SecretTokens("new","new","other-account"))
                f.drain{f.player.mediaItemCount==0}
                fresh.cancelTempo(second);repeat(2){f.drain{true}}
                assertEquals(count,f.hardware.tempoCalls.size)
            }finally{fresh.close()}
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoRootReceiptWithoutMatchingDeckGenerationCannotCompleteSave() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection);f.hardware.holdTempoAck=true
            projection.previewTempo(lease,142.0);f.drain{f.hardware.tempoCalls.isNotEmpty()}
            val tag=f.hardware.tempoCalls.last().tag
            f.hardware.tempoApplied=tag;f.hardware.tempoInstance=1;f.hardware.tempoBpm=142.0
            repeat(3){f.drain{true}}
            assertEquals(com.soundq.android.playback.TempoPreviewPhase.Preparing,f.player.tempoPreviewState!!.phase)
            assertEquals(0L,f.player.tempoPreviewState!!.appliedTag)
            f.hardware.tempoRefused=tag
            f.drain{f.player.tempoPreviewState!!.phase==com.soundq.android.playback.TempoPreviewPhase.Refused}
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
            f.hardware.tempoRefused=0;f.hardware.holdTempoAck=false
            var cancelled:Boolean?=null;projection.cancelTempo(lease){ok,_->cancelled=ok};f.drain{cancelled!=null};assertTrue(cancelled!!)
        }finally{projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun appliedTempoPublicationAlreadyContainsMatchingPerformanceDeck() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection)
            val publication=f.player.onPerformanceChanged
            val mismatches=mutableListOf<Pair<Long,Long?>>()
            f.player.onPerformanceChanged={
                f.player.tempoPreviewState?.takeIf {it.phase==com.soundq.android.playback.TempoPreviewPhase.Applied}?.let {state->
                    val generation=f.player.performanceDecks[state.lease.target.occurrence]?.tempoGeneration
                    if(generation!=state.appliedTag)mismatches.add(state.appliedTag to generation)
                }
                publication?.invoke()
            }
            projection.previewTempo(lease,132.25)
            f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Applied}
            assertTrue("Applied receipt must publish with the same snapshot's deck generation: $mismatches",mismatches.isEmpty())
            f.player.onPerformanceChanged=publication
            projection.cancelTempo(lease)
        }finally{projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoQueuedTerminalRechecksCapturedServiceOwnerAfterTransportRevocation() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection)
            projection.previewTempo(lease,139.0);f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Applied}
            f.hardware.holdState=true
            f.drain{f.hardware.stateEntered.count==0L}
            val calls=f.hardware.restoreCalls
            var restored:Boolean?=null
            f.player.cancelTempo(lease){restored=it}
            f.player.retirePerformanceTransport()
            f.hardware.statePermit.countDown()
            f.drain{restored!=null}
            assertFalse(restored!!);assertEquals(calls,f.hardware.restoreCalls)
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
        }finally{f.hardware.statePermit.countDown();projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoCapacityRefusalKeepsOldLiveAudioAndCancelUsesReservedTerminalOnlyOnce() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection);f.hardware.previewSlots=1
            projection.previewTempo(lease,139.0);f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Applied}
            projection.previewTempo(lease,140.0);f.drain{f.player.tempoPreviewState?.phase==com.soundq.android.playback.TempoPreviewPhase.Refused}
            assertEquals(139.0,f.hardware.tempoBpm,0.0)
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
            var restored:Boolean?=null;projection.cancelTempo(lease){ok,_->restored=ok};f.drain{restored!=null}
            assertTrue(restored!!);assertEquals(120.0,f.hardware.tempoBpm,0.0);assertEquals(1,f.hardware.restoreCalls)
            f.player.cancelTempo(lease);repeat(2){f.drain{true}};assertEquals(1,f.hardware.restoreCalls)
        }finally{projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoBeginRefusesUnavailableTerminalCapacityBeforeExposingLease() {
        ServiceFixture().use {f->val projection=f.projection();try {
            f.hardware.reservationAvailable=false
            val calls=f.hardware.tempoCalls.size
            val ops=f.hardware.ops.toList()
            val accepted=f.accepted
            var done=false;var lease:com.soundq.android.playback.TempoPreviewLease?=null
            projection.beginTempo(accepted.identity,"source-b",f.tempoSource()){l,_->lease=l;done=true}
            f.drain{done}
            assertNull("Begin may not expose a lease without native terminal capacity",lease)
            assertEquals(calls,f.hardware.tempoCalls.size)
            assertEquals(ops,f.hardware.ops.toList())
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
        }finally{projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoBeginRequiresPlayingQualifiedSourceAndRefusesPhaseWithoutDetachingIt() {
        ServiceFixture().use {f->
            val source=f.tempoSource()
            assertNull(runBlocking { f.player.beginTempo(f.target(),source,{false}){true} })
            f.player.pause();f.drain{!f.player.isPlaying}
            assertNull(runBlocking { f.player.beginTempo(f.target(),source,{true}){true} })
            f.player.play();f.drain{f.player.isPlaying}
            val installed=NativeCallbackPlayer::class.java.getDeclaredField("arrangement").apply{isAccessible=true}.get(f.player) as NativeCallbackArrangement
            f.hardware.syncState=2;f.hardware.syncReference=1;f.hardware.syncBeats=4
            f.drain{f.player.performanceDecks["source-b"]?.syncState==com.soundq.android.playback.LiveSyncState.Locked}
            assertNull(runBlocking { f.player.beginTempo(f.target(),source,{true}){true} })
            assertEquals(1L,f.hardware.syncReference);assertTrue(f.hardware.syncCalls.isEmpty())
            assertEquals(f.document,installed.document)
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
        }
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoRouteFailureRetiresLeaseAndLateCallbackCannotPersistOrRollback() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection);f.hardware.holdTempoAck=true
            projection.previewTempo(lease,145.0);f.drain{f.hardware.tempoCalls.isNotEmpty()}
            val count=f.hardware.tempoCalls.size
            val failure=NativeCallbackSnapshot.parse(f.hardware.state(1)).copy(error=-899)
            NativeCallbackPlayer::class.java.getDeclaredMethod("observe",NativeCallbackSnapshot::class.java).apply{isAccessible=true}.invoke(f.player,failure)
            assertEquals(com.soundq.android.playback.TempoPreviewPhase.Retired,f.player.tempoPreviewState!!.phase)
            assertFalse(f.player.playWhenReady)
            projection.cancelTempo(lease)
            f.hardware.holdTempoAck=false;repeat(3){f.drain{true}}
            assertEquals(count,f.hardware.tempoCalls.size)
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
            assertFalse(f.player.previewTempo(lease,99,150.0,0))
        }finally{projection.close()}}
    }
    @Test @Config(application=NativeOverlapServiceApplication::class)
    fun tempoCancelHasBoundedReceiptWaitAndLateGenerationCannotReviveLease() {
        ServiceFixture().use {f->val projection=f.projection();try {
            val lease=f.beginTempo(projection);f.hardware.holdTempoAck=true
            projection.previewTempo(lease,146.0);f.drain{f.hardware.tempoCalls.isNotEmpty()}
            var restored:Boolean?=null;projection.cancelTempo(lease){ok,_->restored=ok}
            f.drain{f.hardware.tempoCalls.last().target==120.0}
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(11))
            f.drain{restored!=null};assertFalse(restored!!)
            assertEquals(com.soundq.android.playback.TempoPreviewPhase.Retired,f.player.tempoPreviewState!!.phase)
            f.hardware.holdTempoAck=false;repeat(3){f.drain{true}}
            assertEquals(com.soundq.android.playback.TempoPreviewPhase.Retired,f.player.tempoPreviewState!!.phase)
            assertFalse(f.player.previewTempo(lease,999,140.0,0))
            assertEquals(f.document,f.app.graph.timeline.state.value.document)
        }finally{projection.close()}}
    }
}
