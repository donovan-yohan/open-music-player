package com.soundq.android.playback.nativeengine

import android.os.*
import androidx.media3.common.*
import androidx.media3.session.*
import com.soundq.android.*
import com.soundq.android.data.*
import com.soundq.android.playback.*
import kotlinx.coroutines.*
import androidx.lifecycle.viewModelScope
import com.soundq.android.product.ProductViewModel
import com.soundq.android.playback.system.ServiceTransportPlayer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.*
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

internal object LargeContextCallProbe {
    val prepares=java.util.concurrent.atomic.AtomicInteger()
    val plays=java.util.concurrent.atomic.AtomicInteger()
}

/** Real Media3 controller, service, canonical player and durable pages. Only the
 * encoded-source/hardware boundary is controlled. This is not audible JNI proof. */
internal class LargeContextApplication:SoundQApplication() {
    val hardware=NativeArrangementPlayerTest.Hardware()
    val crossfadeHardware=OrdinaryCrossfadePlayerTest.Hardware()
    var useCrossfadeHardware=false
    val acquired=CopyOnWriteArrayList<String>()
    override fun onCreate() {
        graph=AppGraph(this,ApiEndpoint.parse("https://fixture.invalid/api/v1"),store=object:SessionStore {
            override fun load(endpoint:ApiEndpoint):SecretTokens?=null
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
            override fun clear(){}
        })
        check(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture","fixture","A")))
    }
    override fun createCallbackLibraryPlayer(grants:ConcurrentHashMap<String,MediaGrant>,jobs:CoroutineScope):Player =
        NativeCallbackPlayer(graph,grants,jobs,if(useCrossfadeHardware)crossfadeHardware else hardware,NativeCallbackSource {item,current->
            check(current());acquired+=item.mediaId
            File(graph.directory,item.mediaId+".encoded").apply {writeBytes(byteArrayOf(1,2,3))}
        })
}

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=LargeContextApplication::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class LargeContextPlayerTest {
    private class Fixture(crossfade:Boolean=false):AutoCloseable {
        val app=(RuntimeEnvironment.getApplication() as LargeContextApplication).also {it.graph.close();it.onCreate();it.useCrossfadeHardware=crossfade}
        val lifecycle=Robolectric.buildService(SoundQLibraryService::class.java).create()
        val service=lifecycle.get()
        fun field(name:String)=service.javaClass.getDeclaredField(name).apply {isAccessible=true}
        val player=field("player").get(service) as NativeCallbackPlayer
        val session=field("session").get(service) as MediaSession
        val controller=ControllerProjection(app,session.token)
        init {drain {controller.state.value.connection==PlaybackProjection.Connection.Connected&&field("account").get(service)!=null}}
        fun drain(predicate:()->Boolean) {
            val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(15)
            while(true) {
                val owner=NativeCallbackPlayer::class.java.getDeclaredField("owner").apply {isAccessible=true}.get(player)
                val thread=owner.javaClass.getDeclaredField("thread").apply {isAccessible=true}.get(owner) as HandlerThread
                thread.looper?.let {Shadows.shadowOf(it).idleFor(java.time.Duration.ofMillis(50))}
                Shadows.shadowOf(Looper.getMainLooper()).idle()
                if(predicate())return
                check(System.nanoTime()<deadline){"Large context ACK deadline. count=${player.mediaItemCount}, error=${controller.state.value.error}"};Thread.sleep(5)
            }
        }
        fun rows(n:Int)=List(n){i->Track(TrackId(if(i==2)1 else i+1L),"Same title","Fixture",durationMs=3000)}
        fun start(rows:List<Track>,index:Int) {app.graph.rememberTracks(rows);controller.playContext(rows,index);drain {player.mediaItemCount==rows.size&&player.currentMediaItemIndex==index&&player.isPlaying}}
        fun pausedOld():List<MediaItem> {
            start(rows(3),2);controller.pause();drain {!player.playWhenReady&&!player.isPlaying}
            controller.seek(1300);drain {player.currentPosition==1300L}
            return (0 until player.mediaItemCount).map(player::getMediaItemAt)
        }
        override fun close() {
            controller.close();app.hardware.allowRetire=true;lifecycle.destroy()
            drain {player.nativeReleased.isDone};assertTrue(player.nativeReleased.get())
            app.graph.close()
        }
    }
    @Test fun actualControllerServiceStarts500501And12037WithoutEagerAudioOrRecordingDedupe() {
        Fixture().use {f->for(n in listOf(500,501,12037)) {
            val before=f.app.acquired.size;val rows=f.rows(n)
            f.start(rows,n-1)
            assertEquals(rows.map {it.id.value},(0 until n).map {f.player.getMediaItemAt(it).mediaMetadata.extras!!.getLong("trackId")})
            assertEquals(n,(0 until n).map {f.player.getMediaItemAt(it).mediaId}.toSet().size)
            assertEquals(n-1,f.player.currentMediaItemIndex);assertEquals(listOf(1L,2L,1L),(0..2).map {f.player.getMediaItemAt(it).mediaMetadata.extras!!.getLong("trackId")})
            assertEquals("Only selected encoded source is acquired",1,f.app.acquired.size-before)
            assertEquals(f.player.currentMediaItem!!.mediaId,f.app.acquired.last())
            f.controller.pause();f.drain {!f.player.isPlaying&&!f.player.playWhenReady}
        }}
    }
    private fun normalStartup(n:Int) {
        Fixture().use {f->
            val old=f.pausedOld()
            val corpus=List(n){i->Track(TrackId(i+100L),"Library $i","Fixture",durationMs=3000)}
            val fetch:(AccountScope,LibraryQuery,Int)->LibraryPage={_,_,offset->LibraryPage(corpus.drop(offset).take(500),total=n,limit=500,offset=offset)}
            LibraryRepository::class.java.getDeclaredField("fetch").apply {isAccessible=true}.set(f.app.graph.library,fetch)
            AppGraph::class.java.getDeclaredField("controllerOwner").apply {isAccessible=true}.set(f.app.graph,lazyOf(f.controller))
            val model=ProductViewModel(f.app)
            try {
                f.drain {model.library.value.rows.size==minOf(n,500)&&!model.library.value.loading&&model.timeline.value.document.clips.size==3}
                while(model.library.value.rows.size<n) {
                    val count=model.library.value.rows.size
                    model.loadMore();f.drain {model.library.value.rows.size>count&&!model.library.value.loading}
                }
                val observers=model.viewModelScope.coroutineContext[Job]!!.children.filter {it.isActive}.toList()
                assertEquals("Normal editor and auth startup collectors",2,observers.size)
                val repo=f.app.graph.timeline;val scope=f.app.graph.session.capture()!!
                val original=repo.state.value.document
                assertTrue(repo.commit(com.soundq.android.data.timeline.TimelineEdit(original.revision,original.clips[1],com.soundq.android.data.timeline.EditKind.TrimIn,1000)){true})
                val draft=repo.state.value.document
                val stale=com.soundq.android.data.timeline.TimelineEdit(draft.revision,draft.clips[1],com.soundq.android.data.timeline.EditKind.TrimOut,2500)
                // Discover the actual owner file, never substitute a synthesized draft.
                val file=f.app.graph.directory.walkTopDown().single {it.isFile&&it.name.startsWith("arrangement-")&&it.name.endsWith(".json")}
                val bytes=file.readBytes()
                model.play(n-1,model.library.value.rows)
                f.drain {f.player.mediaItemCount==n&&f.player.currentMediaItemIndex==n-1&&f.player.isPlaying}
                f.drain {if(n<=500)model.timeline.value.document.clips.size==n else !model.timeline.value.writable}
                assertTrue("Normal startup collectors survived $n known-duration occurrences",observers.all {it.isActive})
                assertEquals(corpus,model.library.value.rows)
                assertEquals(corpus.map {it.id.value},model.playback.value.queue.map {it.trackId})
                assertEquals(n,model.playback.value.queue.map {it.occurrenceId}.toSet().size)
                assertEquals(n-1,f.player.currentMediaItemIndex)
                if(n>500) {
                    assertEquals("Prior bounded draft retained, not first 500 projected",draft,repo.state.value.document)
                    assertArrayEquals(bytes,file.readBytes())
                    assertFalse(repo.preview(stale).accepted);assertFalse(repo.commit(stale){true});assertFalse(repo.undo {true})
                    assertFalse(repo.accepts(scope,draft));assertNull(repo.captureAudition(scope,draft){true})
                    assertArrayEquals(bytes,file.readBytes())
                } else assertTrue(repo.state.value.writable)
                f.controller.pause();f.drain {!f.player.playWhenReady&&!f.player.isPlaying}
                f.controller.undo()
                f.drain {f.player.mediaItemCount==3&&model.timeline.value.writable&&model.timeline.value.document.clips.map {it.occurrence}==old.map {it.mediaId}}
                assertEquals(old,(0 until 3).map(f.player::getMediaItemAt));assertEquals(2,f.player.currentMediaItemIndex);assertEquals(1300L,f.player.currentPosition)
                assertFalse(f.player.playWhenReady);assertFalse(f.player.isPlaying)
                assertEquals(draft.clips,repo.state.value.document.clips);assertArrayEquals(bytes,file.readBytes())
                assertFalse("Former callback cannot revive after source queue Undo",repo.commit(stale){true})
                val fresh=repo.state.value.document
                assertTrue(repo.commit(com.soundq.android.data.timeline.TimelineEdit(fresh.revision,fresh.clips[1],com.soundq.android.data.timeline.EditKind.TrimOut,2500)){true})
                assertTrue(observers.all {it.isActive});assertFalse(bytes.contentEquals(file.readBytes()))
                println("NORMAL_STARTUP n=$n collectors=2 alive=true browse=$n queue=$n selected=${n-1} draftBytesPreserved=true undoCursor=1300 recoveredEditing=true")
            } finally {model.viewModelScope.cancel()}
        }
    }
    @Test fun normalStartup500KnownDurationsRetainsSupportedEditing()=normalStartup(500)
    @Test fun normalStartup501KnownDurationsKeepsFullOrdinaryPlaybackAndRecoversEditing()=normalStartup(501)
    @Test fun normalStartup1001KnownDurationsKeepsFullOrdinaryPlaybackAndRecoversEditing()=normalStartup(1001)
    /** Hold the real ordinary read before a ticket exists, not a fabricated admission seam. */
    private fun preTicketRead(action:String, initiallyPaused:Boolean=true, collection:Boolean=false) {
        Fixture().use {f->
            val old=f.pausedOld()
            if(!initiallyPaused){f.controller.toggle();f.drain {f.player.isPlaying}}
            val secondFuture=MediaController.Builder(f.app,f.session.token).buildAsync()
            f.drain {secondFuture.isDone};val second=secondFuture.get()
            assertTrue(second.isConnected);assertTrue(second.isCommandAvailable(Player.COMMAND_PLAY_PAUSE))
            val entered=CountDownLatch(1);val permit=CountDownLatch(1)
            val held=AtomicBoolean(false)
            val corpus=List(1001){i->Track(TrackId(i+100L),"Library $i","Fixture",durationMs=3000)}
            val fetch:(AccountScope,LibraryQuery,Int)->LibraryPage={_,_,offset->
                if(offset==500&&held.get()){entered.countDown();check(permit.await(10,TimeUnit.SECONDS))}
                LibraryPage(corpus.drop(offset).take(500),total=1001,limit=500,offset=offset)
            }
            // Replace only the external catalog boundary. Repository, ViewModel,
            // controllers, callback admission, transport and canonical player are real.
            LibraryRepository::class.java.getDeclaredField("fetch").apply {isAccessible=true}.set(f.app.graph.library,fetch)
            AppGraph::class.java.getDeclaredField("controllerOwner").apply {isAccessible=true}.set(f.app.graph,lazyOf(f.controller))
            val model=ProductViewModel(f.app)
            try {
                f.drain {model.library.value.rows.size==500&&!model.library.value.loading}
                val observers=model.viewModelScope.coroutineContext[Job]!!.children.filter {it.isActive}.toList()
                assertEquals("Both normal startup collectors remain active",2,observers.size)
                held.set(true)
                val priorJobs=model.viewModelScope.coroutineContext[Job]!!.children.toSet()
                if(collection)model.playLibraryCollection(model.library.value,selected=model.library.value.rows[1].id,current={true}) else model.play(1,model.library.value.rows)
                val read=model.viewModelScope.coroutineContext[Job]!!.children.single {it !in priorJobs}
                f.drain {entered.count==0L}
                assertEquals("Later ordinary page is actually held",1L,permit.count)
                assertNull("No ticket before later-page completion",ContextStartAdmission::class.java.getDeclaredField("active").apply {isAccessible=true}.get(f.app.graph.contextStarts))
                val transport=f.field("transport").get(f.service) as ServiceTransportPlayer
                val revision=transport.revision
                val epoch=f.field("selectionEpoch").getLong(f.service)
                when(action) {
                    "pause"->second.pause()
                    "system"->f.app.sendBroadcast(android.content.Intent(android.media.AudioManager.ACTION_AUDIO_BECOMING_NOISY))
                    "clear"->second.clearMediaItems()
                    "seek"->second.seekTo(1700)
                    "undo"->{val result=second.sendCustomCommand(SessionCommand(SoundQLibraryService.UNDO,Bundle.EMPTY),Bundle.EMPTY);f.drain {result.isDone};assertEquals(SessionResult.RESULT_SUCCESS,result.get().resultCode)}
                    "connection"->f.controller.close()
                    "account"->{f.app.graph.session.retire();f.drain {f.field("account").get(f.service)==null&&f.player.mediaItemCount==0&&!f.player.playWhenReady}}
                    "none"->Unit
                    else->error(action)
                }
                if(action in listOf("pause","system","clear","seek")) {
                    // Positive evidence at BOTH admission and execution. In particular a
                    // no-op Pause cannot borrow an already-false isPlaying predicate.
                    f.drain {f.field("selectionEpoch").getLong(f.service)>epoch&&transport.revision>revision}
                    when(action){"pause","system"->f.drain {!f.player.playWhenReady&&!f.player.isPlaying};"clear"->f.drain {f.player.mediaItemCount==0};"seek"->f.drain {f.player.currentPosition==1700L}}
                }
                val items=(0 until f.player.mediaItemCount).map(f.player::getMediaItemAt)
                val selected=f.player.currentMediaItemIndex;val position=f.player.currentPosition;val ready=f.player.playbackState
                val grants=(f.field("grants").get(f.service) as Map<*,*>).toMap()
                val acquired=f.app.acquired.toList();val ops=f.app.hardware.ops.toList()
                val prepares=LargeContextCallProbe.prepares.get();val plays=LargeContextCallProbe.plays.get()
                permit.countDown()
                f.drain {read.isCompleted}
                f.drain {ContextStartAdmission::class.java.getDeclaredField("active").apply {isAccessible=true}.get(f.app.graph.contextStarts)==null}
                if(action=="none") {
                    f.drain {f.player.mediaItemCount==1001&&f.player.isPlaying}
                    assertEquals(corpus.map {it.id.value},(0 until 1001).map {f.player.getMediaItemAt(it).mediaMetadata.extras!!.getLong("trackId")})
                    assertEquals(1,f.player.currentMediaItemIndex);assertEquals(acquired.size+1,f.app.acquired.size)
                    assertTrue(LargeContextCallProbe.prepares.get()>prepares);assertTrue(LargeContextCallProbe.plays.get()>plays)
                    f.drain {!model.timeline.value.writable}
                    assertTrue("Normal startup collectors survive the complete held Library start",observers.all {it.isActive})
                } else {
                    assertEquals("$action must not install the delayed Library context",items,(0 until f.player.mediaItemCount).map(f.player::getMediaItemAt))
                    assertEquals(selected,f.player.currentMediaItemIndex);assertEquals(position,f.player.currentPosition)
                    assertEquals(ready,f.player.playbackState);assertFalse(f.player.playWhenReady);assertFalse(f.player.isPlaying)
                    assertEquals(grants,(f.field("grants").get(f.service) as Map<*,*>).toMap());assertEquals(acquired,f.app.acquired)
                    assertEquals("No Prepare handler entry",prepares,LargeContextCallProbe.prepares.get())
                    assertEquals("No Play handler entry",plays,LargeContextCallProbe.plays.get())
                    assertEquals("No native Play after the accepted command",ops.count {it==101},f.app.hardware.ops.count {it==101})
                    if(action=="pause")assertEquals(old,items)
                }
            } finally {permit.countDown();model.viewModelScope.cancel();MediaController.releaseFuture(secondFuture)}
        }
    }
    @Test fun jointCollectionHeldReadCannotOverrideSecondControllerPauseWhilePaused()=preTicketRead("pause",collection=true)
    @Test fun jointCollectionHeldReadCannotOverrideSecondControllerPauseWhilePlaying()=preTicketRead("pause",false,true)
    @Test fun jointCollectionHeldReadCannotOverrideSecondControllerSeek()=preTicketRead("seek",collection=true)
    @Test fun jointCollectionHeldReadCannotOverrideNoisyPause()=preTicketRead("system",collection=true)
    @Test fun jointCollectionHeldReadWithoutCommandStartsAfterConsumption()=preTicketRead("none",collection=true)
    @Test fun ordinaryHeldLibraryReadCannotOverrideSecondControllerPauseWhileAlreadyPaused()=preTicketRead("pause")
    @Test fun ordinaryHeldLibraryReadCannotOverrideSecondControllerPauseFromPlaying()=preTicketRead("pause",false)
    @Test fun ordinaryHeldLibraryReadCannotOverrideSystemNoisyPause()=preTicketRead("system")
    @Test fun ordinaryHeldLibraryReadWithoutNewCommandStartsCompleteContext()=preTicketRead("none")
    @Test fun ordinaryHeldLibraryReadRetiresForSecondControllerClear()=preTicketRead("clear")
    @Test fun ordinaryHeldLibraryReadRetiresForSecondControllerUndo()=preTicketRead("undo")
    @Test fun ordinaryHeldLibraryReadRetiresForSecondControllerSeek()=preTicketRead("seek")
    @Test fun ordinaryHeldLibraryReadRetiresForConnectionClose()=preTicketRead("connection")
    @Test fun ordinaryHeldLibraryReadRetiresForAccountRetirement()=preTicketRead("account")
    @Test fun metadataRefusalPreservesExactOldPausedQueueCursorReadinessAndGrants() {
        Fixture().use {f->
            val old=f.pausedOld();val ready=f.player.playbackState;val acquired=f.app.acquired.toList()
            val before=(f.field("grants").get(f.service) as Map<*,*>).toMap()
            f.controller.playContext(f.rows(501).map {it.copy(title="x".repeat(100000))},500)
            f.drain {f.controller.state.value.error!=null}
            assertEquals(old,(0 until f.player.mediaItemCount).map(f.player::getMediaItemAt));assertEquals(2,f.player.currentMediaItemIndex)
            assertEquals(1300L,f.player.currentPosition);assertEquals(ready,f.player.playbackState)
            assertFalse(f.player.playWhenReady);assertFalse(f.player.isPlaying);assertEquals(acquired,f.app.acquired)
            assertEquals(before,(f.field("grants").get(f.service) as Map<*,*>).toMap())
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(2))
            assertNotNull("Refusal remains reachable after projection ticks",f.controller.state.value.error)
        }
    }
    @Test fun heldStagingCannotOverrideNewPauseClearUndoOrSourceAba() {
        for(action in listOf("pause","clear","undo","source"))Fixture().use {f->
            val old=f.pausedOld();val entered=CountDownLatch(1);val permit=CountDownLatch(1);val source=AtomicBoolean(true)
            f.controller.playContext(f.rows(501),500,valid={
                if(Looper.myLooper()!=Looper.getMainLooper()&&permit.count>0){entered.countDown();check(permit.await(5,TimeUnit.SECONDS))}
                source.get()
            })
            assertTrue("staging gate for $action",entered.await(5,TimeUnit.SECONDS))
            when(action) {"pause"->f.controller.pause();"clear"->f.controller.clear();"undo"->f.controller.undo();else->source.set(false)}
            permit.countDown()
            f.drain {ContextStartAdmission::class.java.getDeclaredField("active").apply {isAccessible=true}.get(f.app.graph.contextStarts)==null&&File(f.app.graph.directory,"context-starts").listFiles().orEmpty().none {it.name.endsWith(".json")||it.name.endsWith(".pages")}}
            if(action=="source"){source.set(true);Shadows.shadowOf(Looper.getMainLooper()).idle()}
            assertTrue(f.player.mediaItemCount<=3);assertFalse(f.player.playWhenReady)
            if(action=="pause"||action=="source")assertEquals(old,(0 until f.player.mediaItemCount).map(f.player::getMediaItemAt))
        }
    }
    @Test fun largeReplacementCarriesOnlyFutureManualOccurrencesAndUndoRestoresExactOldCursor() {
        Fixture().use {f->
            f.start(f.rows(3),0);f.controller.pause();f.drain {!f.player.isPlaying}
            val manual=Track(TrackId(7),"Manual","Fixture",durationMs=3000);f.app.graph.rememberTracks(listOf(manual));f.controller.enqueue(manual,false)
            f.drain {f.player.mediaItemCount==4};f.controller.seek(1300);f.drain {f.player.currentPosition==1300L}
            val old=(0 until f.player.mediaItemCount).map(f.player::getMediaItemAt);val carried=old[1]
            f.app.graph.rememberTracks(f.rows(501));f.controller.playContext(f.rows(501),500)
            f.drain {f.player.mediaItemCount==502&&f.player.isPlaying}
            assertSame(carried,f.player.getMediaItemAt(501));assertEquals(500,f.player.currentMediaItemIndex)
            f.controller.undo();f.drain {f.player.mediaItemCount==4&&!f.player.playWhenReady}
            assertEquals(old,(0 until f.player.mediaItemCount).map(f.player::getMediaItemAt));assertEquals(1300L,f.player.currentPosition);assertEquals(0,f.player.currentMediaItemIndex)
            assertFalse(f.player.isPlaying)
            // Existing preference disables carry, but Undo still keeps the source snapshot.
            f.app.graph.queueSettings.load()
            assertTrue(f.app.graph.queueSettings.setKeepQueued(f.app.graph.queueSettings.capture()!!,false))
            f.controller.playContext(f.rows(501),500)
            f.drain {f.player.mediaItemCount==501&&f.player.isPlaying}
            assertTrue((0 until 501).none {f.player.getMediaItemAt(it).mediaId==carried.mediaId})
        }
    }
    @Test fun fullLiteralCollectionAndLikedInputsUseTheSamePagedCanonicalStartWithManualCarry() {
        Fixture().use {f->
            f.pausedOld()
            val manual=Track(TrackId(7),"Manual","Fixture",durationMs=3000)
            f.app.graph.rememberTracks(listOf(manual));f.controller.enqueue(manual,false)
            f.drain {f.player.mediaItemCount==4}
            val carried=f.player.getMediaItemAt(3)
            val artist="""  A%_"\\海辺  """;val album="""_100% "\\étude """
            // These are consumer-boundary fixture inputs, not a substitute for
            // the separately reviewed/corrected production corpus collector.
            val corpus=List(3606){i->Track(TrackId(i+1L),"Same title",if(i%2==0)artist else artist+" ",album,3000,i%3==0)}
            val collection=corpus.filter {it.artist==artist&&it.album==album}
            for(eligible in listOf(collection,collection.filter {it.liked==true})) {
                assertTrue(eligible.size>500)
                val index=eligible.lastIndex
                f.app.graph.rememberTracks(eligible);f.controller.playContext(eligible,index,valid={true})
                f.drain {f.player.mediaItemCount==eligible.size+1&&f.player.currentMediaItemIndex==index&&f.player.isPlaying}
                assertEquals(eligible.map {it.id.value},(0 until eligible.size).map {f.player.getMediaItemAt(it).mediaMetadata.extras!!.getLong("trackId")})
                assertEquals(eligible[index].id.value,f.player.currentMediaItem!!.mediaMetadata.extras!!.getLong("trackId"))
                assertSame(carried,f.player.getMediaItemAt(eligible.size))
                assertTrue((0 until eligible.size).all {f.player.getMediaItemAt(it).mediaMetadata.artist.toString()==artist})
            }
        }
    }
    @Test fun actualNativeShuffleRepeatAndPausedPagedRestartPreserveEveryOccurrence() {
        Fixture().use {f->
            val rows=f.rows(501);f.start(rows,500);f.controller.pause();f.drain {!f.player.isPlaying}
            f.controller.shuffle();f.controller.repeat();f.drain {f.player.shuffleModeEnabled&&f.player.repeatMode==Player.REPEAT_MODE_ALL}
            val ids=(0 until 501).map {f.player.getMediaItemAt(it).mediaId}
            var index=f.player.currentMediaItemIndex
            val first=index
            val visited=mutableSetOf(ids[index])
            repeat(500){index=f.player.currentTimeline.getNextWindowIndex(index,Player.REPEAT_MODE_ALL,true);assertTrue(visited.add(ids[index]))}
            assertEquals(ids.toSet(),visited)
            assertEquals(first,f.player.currentTimeline.getNextWindowIndex(index,Player.REPEAT_MODE_ALL,true))
            assertEquals(index,f.player.currentTimeline.getNextWindowIndex(index,Player.REPEAT_MODE_ONE,true))
            val before=f.player.currentMediaItem!!.mediaId
            f.controller.next();f.drain {f.player.currentMediaItem!!.mediaId!=before}
            f.controller.repeat();f.drain {f.player.repeatMode==Player.REPEAT_MODE_ONE}
            f.controller.seek(1300);f.drain {f.player.currentPosition==1300L}
            val selected=f.player.currentMediaItemIndex
            val scope=f.app.graph.session.capture()!!
            val saved=QueueSnapshot(f.app.graph.endpoint.identity,scope.accountId,(0 until 501).map {i->val m=f.player.getMediaItemAt(i);val e=m.mediaMetadata.extras!!;SavedOccurrence(m.mediaId,e.getLong("trackId"),m.mediaMetadata.title.toString(),m.mediaMetadata.artist.toString(),e.getBoolean("manual"),false,e.getLong("durationMs"))},selected,1300,true,SavedRepeatMode.One)
            val method=f.service.javaClass.getDeclaredMethod("queueFile",AccountScope::class.java).apply {isAccessible=true}
            val file=method.invoke(f.service,scope) as File
            QueueSnapshotStore(file).write(saved)
            val restarted=QueueSnapshotStore(file).read(saved.endpoint,saved.account)!!
            assertEquals(saved,restarted);assertEquals(ids,restarted.items.map {it.occurrence});assertEquals(1300L,restarted.position)
            f.field("saveJob").get(f.service)?.let {(it as kotlinx.coroutines.Job).cancel()}
            f.field("restoring").setBoolean(f.service,true);f.player.clearMediaItems();f.field("restoring").setBoolean(f.service,false)
            f.service.javaClass.getDeclaredMethod("restoreQueue",AccountScope::class.java).apply {isAccessible=true}.invoke(f.service,scope)
            f.drain {f.player.mediaItemCount==501}
            assertEquals(ids,(0 until 501).map {f.player.getMediaItemAt(it).mediaId})
            assertEquals(selected,f.player.currentMediaItemIndex);assertEquals(1300L,f.player.currentPosition)
            assertTrue(f.player.shuffleModeEnabled);assertEquals(Player.REPEAT_MODE_ONE,f.player.repeatMode)
            assertEquals(Player.STATE_IDLE,f.player.playbackState);assertFalse(f.player.playWhenReady)
            // A new large source while shuffle is already enabled must use the
            // canonical player's existing permutation constructor.
            f.controller.playContext(f.rows(501),500)
            f.drain {f.player.mediaItemCount==501&&f.player.isPlaying}
            val order=mutableListOf<Int>();var next=500
            repeat(501){order+=next;next=f.player.currentTimeline.getNextWindowIndex(next,Player.REPEAT_MODE_ALL,true)}
            assertEquals((0..500).toSet(),order.toSet());assertEquals(500,order.first())
            assertNotEquals((0..499).toList(),order.drop(1))
            assertTrue(f.player.shuffleModeEnabled);assertEquals(Player.REPEAT_MODE_ONE,f.player.repeatMode)
        }
    }

    /** The current producer, normal collectors, paged service and optional crossfade execute together. */
    private fun jointCollectionCrossfade(n:Int,liked:Boolean) {
        Fixture(crossfade=true).use {f->
            val old=f.pausedOld()
            val manual=Track(TrackId(70),"Manual","Fixture",durationMs=6000)
            f.app.graph.rememberTracks(listOf(manual));f.controller.enqueue(manual,false)
            f.drain {f.player.mediaItemCount==4}
            val carried=f.player.getMediaItemAt(3)
            val artist="  A%_\"\\海辺  ";val album="_100% \"\\étude "
            val eligible=List(n){i->Track(TrackId(i+100L),"Same title",artist,album,6000,true)}
            // Every wire page is bounded. Excluded rows have distinct raw identities.
            val corpus=eligible.flatMapIndexed {i,t->listOf(t,Track(TrackId(i+100000L),"Same title",artist+" ",album,6000,false))}
            val fetch:(AccountScope,LibraryQuery,Int)->LibraryPage={_,_,offset->LibraryPage(corpus.drop(offset).take(500),total=corpus.size,limit=500,offset=offset)}
            LibraryRepository::class.java.getDeclaredField("fetch").apply {isAccessible=true}.set(f.app.graph.library,fetch)
            AppGraph::class.java.getDeclaredField("controllerOwner").apply {isAccessible=true}.set(f.app.graph,lazyOf(f.controller))
            val model=ProductViewModel(f.app)
            try {
                f.drain {!model.library.value.loading&&model.library.value.rows.isNotEmpty()}
                val query=LibraryQuery(liked=liked,collection=LibraryCollection(artist,album))
                model.refine(query)
                f.drain {!model.library.value.loading&&model.library.value.query==query&&model.library.value.rows.size==n}
                val observers=model.viewModelScope.coroutineContext[Job]!!.children.filter {it.isActive}.toList()
                assertEquals(2,observers.size)
                val repo=f.app.graph.timeline
                val before=repo.state.value.document
                val selected=eligible[n-2].id
                f.app.graph.crossfadePreferences.load()
                assertEquals(0,f.app.graph.crossfadePreferences.state.value.seconds)
                val acquisitions=f.app.acquired.size
                model.playLibraryCollection(model.library.value,selected=selected,current={true})
                f.drain {f.player.mediaItemCount==n+1&&f.player.currentMediaItemIndex==n-2&&f.player.isPlaying&&f.player.preparationSettled}
                f.drain {!model.timeline.value.writable} // Complete context plus carried manual exceeds the editor budget.
                assertEquals(eligible,model.library.value.rows)
                assertEquals(eligible.map {it.id.value},(0..n).map(f.player::getMediaItemAt).filter {it.mediaId!=carried.mediaId}.map {it.mediaMetadata.extras!!.getLong("trackId")})
                assertSame(carried,f.player.getMediaItemAt(n-1))
                assertEquals("Off acquires only selected source",acquisitions+1,f.app.acquired.size)
                assertTrue(f.app.crossfadeHardware.pairs.isEmpty())
                assertTrue(observers.all {it.isActive})
                assertEquals(before,repo.state.value.document)
                // The same installed large metadata queue now enables optional overlap.
                f.app.crossfadeHardware.failIncoming=true
                check(f.app.graph.crossfadePreferences.setSeconds(f.app.graph.crossfadePreferences.capture()!!,2){true})
                f.drain {f.app.crossfadeHardware.loads.size>=2&&f.player.preparationSettled}
                val afterFailure=f.app.acquired.toList();val observations=f.app.crossfadeHardware.observations
                f.drain {f.app.crossfadeHardware.observations>=observations+40}
                assertEquals("Failed optional decoder is latched, never poll-retried",afterFailure,f.app.acquired)
                assertEquals(acquisitions+2,afterFailure.size)
                assertTrue(f.player.isPlaying);assertEquals(selected.value,f.player.currentMediaItem!!.mediaMetadata.extras!!.getLong("trackId"))
                assertNull(f.player.playerError)
                f.app.crossfadeHardware.failIncoming=false
                check(f.app.graph.crossfadePreferences.setSeconds(f.app.graph.crossfadePreferences.capture()!!,3){true})
                f.drain {f.app.crossfadeHardware.pairs.any {it[2]>0}&&f.player.preparationSettled}
                assertEquals(acquisitions+3,f.app.acquired.size)
                f.app.crossfadeHardware.sample(5000,1000,.6,.8)
                f.drain {f.player.currentMediaItemIndex==n-1}
                assertSame(carried,f.player.currentMediaItem)
                assertEquals(1000L,f.player.currentPosition)
                f.controller.select(f.player.getMediaItemAt(n).mediaId)
                f.drain {f.player.currentMediaItemIndex==n&&!f.player.playWhenReady}
                assertEquals(eligible.last().id.value,f.player.currentMediaItem!!.mediaMetadata.extras!!.getLong("trackId"))
                assertTrue(observers.all {it.isActive})
                f.controller.pause();f.drain {!f.player.playWhenReady&&!f.player.isPlaying}
                f.controller.undo();f.drain {f.player.mediaItemCount==4&&model.timeline.value.writable}
                assertEquals(old,(0 until 3).map(f.player::getMediaItemAt));assertSame(carried,f.player.getMediaItemAt(3))
                assertEquals(2,f.player.currentMediaItemIndex);assertEquals(1300L,f.player.currentPosition);assertFalse(f.player.playWhenReady)
                println("JOINT producer=${if(liked)"Liked" else "literal"} n=$n selected=${selected.value} membership=complete collectors=2 off=selected-only failedDecoder=latched recovery=preference dominance=later-row manualCarry=true undo=1300")
            }finally {model.viewModelScope.cancel()}
        }
    }
    @Test fun jointLiteral500NormalCollectorsPagedServiceAndDefaultOffCrossfade()=jointCollectionCrossfade(500,false)
    @Test fun jointLiteral501NormalCollectorsPagedServiceAndDefaultOffCrossfade()=jointCollectionCrossfade(501,false)
    @Test fun jointLiked1001NormalCollectorsPagedServiceAndDefaultOffCrossfade()=jointCollectionCrossfade(1001,true)

    @Test fun jointConsumedCollectionSourceRetirementRefusesHeldPagedStagingWithoutOldPlayerEffects() {
        Fixture().use {f->
            val old=f.pausedOld();val corpus=List(501){i->Track(TrackId(i+100L),"Same title","Fixture",durationMs=3000)}
            val fetch:(AccountScope,LibraryQuery,Int)->LibraryPage={_,_,offset->LibraryPage(corpus.drop(offset).take(500),corpus.size,500,offset)}
            LibraryRepository::class.java.getDeclaredField("fetch").apply {isAccessible=true}.set(f.app.graph.library,fetch)
            AppGraph::class.java.getDeclaredField("controllerOwner").apply {isAccessible=true}.set(f.app.graph,lazyOf(f.controller))
            val model=ProductViewModel(f.app);val entered=CountDownLatch(1);val release=CountDownLatch(1)
            val lock=QueueSnapshotStore::class.java.getDeclaredField("lock").apply {isAccessible=true}.get(null)
            val executor=Executors.newSingleThreadExecutor();var route=true
            try {
                f.drain {model.library.value.rows.size==500&&!model.library.value.loading}
                val holder=executor.submit {synchronized(lock){entered.countDown();check(release.await(10,TimeUnit.SECONDS))}}
                assertTrue(entered.await(5,TimeUnit.SECONDS))
                val beforeAcquired=f.app.acquired.toList();val beforePrepares=LargeContextCallProbe.prepares.get();val beforePlays=LargeContextCallProbe.plays.get()
                model.playLibraryCollection(model.library.value,selected=model.library.value.rows.last().id,current={route})
                val pending=LibraryRepository::class.java.getDeclaredField("pendingCollection").apply {isAccessible=true}
                f.drain {pending.get(f.app.graph.library)==null}
                assertEquals("The producer has consumed its request",false,model.library.value.collectionLoading)
                route=false;release.countDown();holder.get(5,TimeUnit.SECONDS)
                f.drain {ContextStartAdmission::class.java.getDeclaredField("active").apply {isAccessible=true}.get(f.app.graph.contextStarts)==null}
                assertEquals(old,(0 until f.player.mediaItemCount).map(f.player::getMediaItemAt))
                assertEquals(2,f.player.currentMediaItemIndex);assertEquals(1300L,f.player.currentPosition)
                assertFalse(f.player.playWhenReady);assertEquals(beforeAcquired,f.app.acquired)
                assertEquals(beforePrepares,LargeContextCallProbe.prepares.get());assertEquals(beforePlays,LargeContextCallProbe.plays.get())
                println("JOINT consumedProducer=true heldPagedStage=true retiredRoute=true oldQueue=exact prepares=0 plays=0")
            }finally {release.countDown();executor.shutdownNow();model.viewModelScope.cancel()}
        }
    }
}
