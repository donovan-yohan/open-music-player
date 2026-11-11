#!/usr/bin/env python3
"""Compile the actual ViewModel observer with only Android/lifecycle boundaries replaced."""
from pathlib import Path
import argparse

parser=argparse.ArgumentParser()
parser.add_argument('--generate',type=Path,required=True)
args=parser.parse_args()
source=Path(__file__).resolve().parents[1]/'app/src/main/kotlin/com/soundq/android/product/ProductViewModel.kt'
text=source.read_text()
start=text.index('        viewModelScope.launch(mainObserverDispatcher) {',text.index('    init {'))
opening=text.index('{',start)
depth=1
end=opening+1
while depth:
    if text[end]=='{':depth+=1
    elif text[end]=='}':depth-=1
    end+=1
observer=text[start:end]
# Completion marker is after the actual collector body, not before owner publication.
pos=observer.rfind('            }')
observer=observer[:pos]+'                processed.trySend(Unit)\n'+observer[pos:]
fixture='''package com.soundq.android.extracted
import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class TimelineObserverExtractedTest {
    class Graph(val session:AccountSession,val timeline:TimelineRepository)
    class Model(val graph:Graph,val playback:MutableStateFlow<PlaybackProjection>) : AutoCloseable {
        val auth=graph.session.state
        val viewModelScope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
        // Android main-dispatcher declaration facade only. The extracted
        // repository observer body and its completion assertions stay intact.
        val mainObserverDispatcher=Dispatchers.Default
        val processed=Channel<Unit>(Channel.UNLIMITED)
        init {
OBSERVER
        }
        override fun close(){viewModelScope.cancel()}
        suspend fun settled(){withTimeout(5000){processed.receive()}}
    }
    @Test fun appendedContinuationPreservesEarlierTrimAndPlacementThroughTheActualObserver()=runBlocking {
        val dir=Files.createTempDirectory(java.nio.file.Path.of(System.getenv("TMPDIR")),"continuation-observer-").toFile()
        var model:Model?=null
        try {
            val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","fixture"));val scope=session.capture()!!
            val repo=TimelineRepository(session,dir){_,_,_,_->error("No analysis")}
            val old=QueueOccurrence("A",7,"Original","",false,10000)
            repo.observe(scope,listOf(TimelineSource("A",7,"Original",10000,QueueSegment.Context)))
            for((kind,value) in listOf(EditKind.TrimIn to 1000L,EditKind.TrimOut to 8000L,EditKind.Placement to 3000L)) {
                val d=repo.state.value.document;assertTrue(repo.commit(TimelineEdit(d.revision,d.clips.single(),kind,value)){true})
            }
            val accepted=repo.state.value.document.clips.single()
            val flow=MutableStateFlow(PlaybackProjection(PlaybackProjection.Connection.Connected,queue=listOf(old),accountEpoch=scope.epoch))
            val active=Model(Graph(session,repo),flow);model=active;active.settled()
            flow.value=flow.value.copy(queue=listOf(old,QueueOccurrence("B",8,"Auto","",false,2000,QueueOrigin.Continuation)));active.settled()
            assertEquals(accepted,repo.state.value.document.clips.first())
            assertEquals(QueueSegment.Continuation,repo.state.value.document.clips.last().segment)
        }finally {model?.close();dir.deleteRecursively()}
    }
    @Test fun loadedOwnerIgnoresUnavailableProjectionsButAdmitsConnectedEmptyAndRestoration()=runBlocking {
        val dir=Files.createTempDirectory("timeline-observer").toFile()
        var model:Model?=null
        try {
            val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val scope=session.capture()!!
            val repo=TimelineRepository(session,dir){_,_,_,_->error("No analysis")}
            val queue=listOf("A","B").map {QueueOccurrence(it,7,"Duplicate source","Fixture",false,10000)}
            repo.observe(scope,queue.map {TimelineSource(it.occurrenceId,it.trackId,it.title,it.durationMs,QueueSegment.Context)})
            fun edit(kind:EditKind,value:Long) {
                val d=repo.state.value.document
                assertTrue(repo.commit(TimelineEdit(d.revision,d.clips.last(),kind,value)){true})
            }
            edit(EditKind.TrimIn,2000);edit(EditKind.TrimOut,8000);edit(EditKind.Placement,3000)
            val playback=MutableStateFlow(PlaybackProjection(PlaybackProjection.Connection.Connected,queue=queue,accountEpoch=scope.epoch))
            val active=Model(Graph(session,repo),playback);model=active;active.settled()
            val accepted=repo.state.value
            val bytes=dir.listFiles()!!.single().readBytes()
            // A connected projection can still belong to a retired service account.
            playback.value=PlaybackProjection(PlaybackProjection.Connection.Connected,accountEpoch=scope.epoch-1);active.settled()
            assertEquals(accepted,repo.state.value)
            assertArrayEquals(bytes,dir.listFiles()!!.single().readBytes())
            playback.value=PlaybackProjection(PlaybackProjection.Connection.Connected,queue=queue,accountEpoch=scope.epoch);active.settled()
            for(connection in listOf(PlaybackProjection.Connection.Unavailable,PlaybackProjection.Connection.Connecting,PlaybackProjection.Connection.Disconnected)) {
                playback.value=PlaybackProjection(connection);active.settled()
                assertEquals(accepted,repo.state.value)
                assertArrayEquals(bytes,dir.listFiles()!!.single().readBytes())
            }
            // Same empty queue, different connection. Must not be suppressed by queue-only distinct.
            playback.value=PlaybackProjection(PlaybackProjection.Connection.Connected,accountEpoch=scope.epoch);active.settled()
            assertTrue(repo.state.value.document.clips.isEmpty())
            playback.value=PlaybackProjection(PlaybackProjection.Connection.Connected,queue=queue,accountEpoch=scope.epoch);active.settled()
            assertEquals(accepted.document.clips,repo.state.value.document.clips)
        } finally {model?.close();dir.deleteRecursively()}
    }
}
'''.replace('OBSERVER',observer)
args.generate.mkdir(parents=True,exist_ok=True)
(args.generate/'TimelineObserverExtractedTest.kt').write_text(fixture)

# Preserve the actual service account-retirement branch. Only player/platform
# boundaries are replaced; account capability and Library ownership are real.
service=(source.parent.parent/'playback/SoundQLibraryService.kt').read_text()
graph_source=(source.parent.parent/'SoundQApplication.kt').read_text()
assert 'internal fun retireCatalogAfterPlaybackAccount() {retireCatalog(true)}' in graph_source
assert 'if(preserveCurrentLibrary)library.retireObsolete()else library.retire()' in graph_source
start=service.index('                if(account!=null && (next==null || !graph.session.current(account!!))) {')
opening=service.index('{',start)
depth=1
end=opening+1
while depth:
    if service[end]=='{':depth+=1
    elif service[end]=='}':depth-=1
    end+=1
retirement=service[start:end]
retirement_fixture='''package com.soundq.android.accountretirementprobe
import com.soundq.android.data.*
import kotlinx.coroutines.Job
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class ServiceAccountRetirementExtractedTest {
    class Counter {
        var calls=0
        fun accountRetired(){calls++}
        fun close(){calls++}
        fun retire(){calls++}
        fun command(){calls++}
        fun replaceOwner(){calls++}
    }
    class Player {
        var clears=0
        var pauses=0
        fun pause(){pauses++}
        fun stop(){}
        fun clearMediaItems(){clears++}
    }
    class Graph(val session:AccountSession,val library:LibraryRepository,val mutationWrites:AtomicInteger) {
        var catalogRetirements=0
        val jamAdmission=Counter()
        fun retireCatalog(){catalogRetirements++;library.retire()}
        fun retireCatalogAfterPlaybackAccount(){catalogRetirements++;library.retireObsolete()}
    }
    class Host(val graph:Graph,var account:AccountScope?,val next:AccountScope?) {
        val continuation=Counter();var selectionEpoch=0
        val mixGrants=mutableMapOf<String,Counter>()
        var saveJob:Job?=null
        var restoring=false
        val transport=Counter();val interruptions=Counter();val player=Player()
        val grants=mutableMapOf<String,Any>()
        var undo:Any?=Any();var undoScope:AccountScope?=account
        var restoredIdentity:String?="previous";var rejectedQueue=true
        fun publishSessionExtras(){}
        fun refreshLikeButton(){}
        fun retirePrevious() {
RETIREMENT
        }
    }
    private fun graph():Graph {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore())
        check(session.accept(session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","A")))
        val writes=AtomicInteger();var liked=true
        val library=LibraryRepository(session,{_,_,offset->LibraryPage(listOf(Track(TrackId(1),"Fresh","Fixture",liked=liked)),1,20,offset)},
            {_,_,value->writes.incrementAndGet();liked=value})
        return Graph(session,library,writes)
    }
    @Test fun completedReplacementLibraryReadCannotBeErasedByLateOldPlaybackCleanup() {
        for(replacement in listOf("A","B")) {
            val graph=graph();val previous=graph.session.capture()!!
            check(graph.session.accept(graph.session.beginIntent(),SecretTokens("replacement-access","replacement-refresh",replacement)))
            graph.library.refine(LibraryQuery());val accepted=graph.library.state.value
            val host=Host(graph,previous,graph.session.capture()!!);host.retirePrevious()
            assertFalse(graph.session.current(previous))
            assertEquals(1,host.player.clears);assertEquals(1,host.continuation.calls);assertEquals(1,graph.jamAdmission.calls)
            assertSame("Late service cleanup erased the replacement account acknowledgement",accepted,graph.library.state.value)
            assertEquals("Other retired catalog owners still require cleanup",1,graph.catalogRetirements)
        }
    }
    @Test fun claimedReplacementLibraryReadStillCompletesAfterOldPlaybackCleanup() {
        val graph=graph();val previous=graph.session.capture()!!
        check(graph.session.accept(graph.session.beginIntent(),SecretTokens("replacement-access","replacement-refresh","A")))
        val request=graph.library.claimRefinement(LibraryQuery())!!
        val host=Host(graph,previous,graph.session.capture()!!);host.retirePrevious()
        graph.library.executeRefinement(request)
        assertEquals(listOf(1L),graph.library.state.value.rows.map {it.id.value})
        assertFalse(graph.library.state.value.loading);assertEquals(1,host.player.clears)
    }
    @Test fun accountRetirementWithoutReplacementStillClearsReadCatalogAndPlayback() {
        val graph=graph();graph.library.refine(LibraryQuery());val previous=graph.session.capture()!!
        graph.session.retire();val host=Host(graph,previous,null);host.retirePrevious()
        assertEquals(1,graph.catalogRetirements);assertTrue(graph.library.state.value.rows.isEmpty())
        assertEquals(1,host.player.clears);assertNull(host.account);assertFalse(host.rejectedQueue)
    }
    @Test fun replacementWithoutFreshReadCannotKeepPreviousAccountCatalog() {
        val graph=graph();graph.library.refine(LibraryQuery());val previous=graph.session.capture()!!
        check(graph.session.accept(graph.session.beginIntent(),SecretTokens("replacement-access","replacement-refresh","B")))
        val host=Host(graph,previous,graph.session.capture()!!);host.retirePrevious()
        assertTrue("A replacement account must not retain the old account rows",graph.library.state.value.rows.isEmpty())
        assertEquals(1,graph.catalogRetirements);assertEquals(1,host.player.clears)
    }
    @Test fun currentPlaybackAccountDoesNotRetireItsOwnReadOrPlaybackState() {
        val graph=graph();graph.library.refine(LibraryQuery());val accepted=graph.library.state.value
        val scope=graph.session.capture()!!;val host=Host(graph,scope,scope);host.retirePrevious()
        assertSame(accepted,graph.library.state.value);assertEquals(0,graph.catalogRetirements);assertEquals(0,host.player.clears)
    }
    @Test fun retiredLikeCannotBlockReplacementCollectionOrDispatchAfterLateCleanup() {
        val graph=graph();graph.library.refine(LibraryQuery());val previous=graph.session.capture()!!
        val old=graph.library.claimLike(graph.library.offerLike(previous,TrackId(1))!!)!!
        check(graph.session.accept(graph.session.beginIntent(),SecretTokens("replacement-access","replacement-refresh","B")))
        graph.library.refine(LibraryQuery())
        Host(graph,previous,graph.session.capture()!!).retirePrevious()
        val collection=graph.library.claimCollectionPlay(graph.library.state.value,current={true})
        assertNotNull("Retired Like bookkeeping blocked the replacement owner's collection",collection)
        graph.library.abandonCollection(collection!!)
        assertEquals(MutationOutcome.Refused,graph.library.executeLike(old));assertEquals(0,graph.mutationWrites.get())
    }
    @Test fun currentLikeStillBlocksCollectionAndSettlesThroughItsOriginalReceipt() {
        val graph=graph();val previous=graph.session.capture()!!
        check(graph.session.accept(graph.session.beginIntent(),SecretTokens("replacement-access","replacement-refresh","B")))
        graph.library.refine(LibraryQuery());val current=graph.session.capture()!!
        val receipt=graph.library.claimLike(graph.library.offerLike(current,TrackId(1))!!)!!
        Host(graph,previous,current).retirePrevious()
        assertNull(graph.library.claimCollectionPlay(graph.library.state.value,current={true}))
        assertEquals(MutationOutcome.Pending,graph.library.likeView(current,TrackId(1))!!.outcome)
        assertEquals(MutationOutcome.Confirmed,graph.library.executeLike(receipt))
        assertEquals(1,graph.mutationWrites.get());assertEquals(false,graph.library.likeView(current,TrackId(1))!!.track.liked)
    }
}
'''.replace('RETIREMENT',retirement)
(args.generate/'ServiceAccountRetirementExtractedTest.kt').write_text(retirement_fixture)
