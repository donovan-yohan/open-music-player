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
