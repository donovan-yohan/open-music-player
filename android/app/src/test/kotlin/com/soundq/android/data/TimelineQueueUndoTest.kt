package com.soundq.android.data

import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class TimelineQueueUndoTest {
    private val sources=listOf("A","B").map {TimelineSource(it,7,"Duplicate source",10000,QueueSegment.Context)}
    private fun edit(repo:TimelineRepository,id:String,kind:EditKind,value:Long) {
        val d=repo.state.value.document
        assertTrue(repo.commit(TimelineEdit(d.revision,d.clips.single {it.occurrence==id},kind,value)){true})
    }
    @Test fun absentTimingCannotCrossAccountOwnerEvenWhenOccurrenceIdsCollide() {
        val dir=Files.createTempDirectory("timeline-queue-account").toFile()
        try {
            val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","first-fixture"))
            val first=session.capture()!!
            val repo=TimelineRepository(session,dir){_,_,_,_->error("No analysis")}
            repo.observe(first,sources);edit(repo,"B",EditKind.TrimIn,2000)
            repo.observe(first,sources.take(1))
            val firstFile=dir.listFiles()!!.single();val bytes=firstFile.readBytes()
            session.retire();session.accept(session.beginIntent(),SecretTokens("b","s","second-fixture"))
            val second=session.capture()!!;repo.observe(second,sources)
            assertEquals(0L,repo.state.value.document.clips.last().sourceInMs)
            repo.observe(first,sources)
            assertEquals(0L,repo.state.value.document.clips.last().sourceInMs)
            edit(repo,"B",EditKind.TrimIn,1000)
            assertArrayEquals(bytes,firstFile.readBytes())
            session.retire();session.accept(session.beginIntent(),SecretTokens("c","t","first-fixture"))
            repo.observe(session.capture()!!,sources)
            assertEquals(2000L,repo.state.value.document.clips.last().sourceInMs)
        } finally {dir.deleteRecursively()}
    }
    @Test fun restoredQueueOccurrenceRetainsAcceptedTimingThroughNextSaveAndRealFileReload() {
        val dir=Files.createTempDirectory("timeline-queue-undo").toFile()
        try {
            val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val scope=session.capture()!!
            fun repository()=TimelineRepository(session,dir){_,_,_,_->error("No analysis request expected")}
            val repo=repository();repo.observe(scope,sources)
            edit(repo,"B",EditKind.TrimIn,2000);edit(repo,"B",EditKind.TrimOut,8000);edit(repo,"B",EditKind.Placement,3000)
            val accepted=repo.state.value.document.clips.single {it.occurrence=="B"}
            val file=dir.listFiles()!!.single();val acceptedBytes=file.readBytes()
            repo.observe(scope,sources.take(1))
            assertEquals(listOf("A"),repo.state.value.document.clips.map {it.occurrence})
            assertArrayEquals(acceptedBytes,file.readBytes())
            // Service queue Undo restores the exact saved occurrence IDs, not new source IDs.
            repo.observe(scope,sources)
            assertEquals(accepted,repo.state.value.document.clips.single {it.occurrence=="B"})
            edit(repo,"A",EditKind.TrimOut,9000)
            val restored=repository();restored.observe(scope,sources)
            assertEquals(accepted,restored.state.value.document.clips.single {it.occurrence=="B"})
            assertEquals(9000L,restored.state.value.document.clips.first().sourceOutMs)
        } finally {dir.deleteRecursively()}
    }
}
