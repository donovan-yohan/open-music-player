package com.soundq.android.data

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class LibrarySortStoreTest {
    private fun session(endpoint:String="https://fixture.test/api/v1",account:String="A")=AccountSession(ApiEndpoint.parse(endpoint),MemoryStore()).also {
        it.accept(it.beginIntent(),SecretTokens("a","r",account))
    }
    private fun repo(session:AccountSession,directory:File)=LibraryRepository(session,{_,_,offset->LibraryPage(listOf(Track(TrackId(1),"Song")),1,20,offset)},{_,_,_->},LibrarySortStore(directory))
    @Test fun restartRestoresSortAndDirectionButNotOldSearchOrCollection() {
        val dir=Files.createTempDirectory("library-sort-test").toFile()
        try {
            val first=repo(session(),dir);first.restore()
            first.refine(LibraryQuery(text="old",sort=LibrarySort.Title,ascending=true,liked=true,collection=LibraryCollection(artist="")))
            val restarted=repo(session(),dir);restarted.restore()
            assertEquals(LibraryQuery(sort=LibrarySort.Title,ascending=true),restarted.state.value.query)
            assertFalse(restarted.state.value.sortError)
        }finally {dir.deleteRecursively()}
    }
    @Test fun sameAccountDifferentEndpointAndDifferentAccountDoNotShareChoice() {
        val dir=Files.createTempDirectory("library-sort-test").toFile()
        try {
            val a=repo(session(),dir);a.restore();a.refine(LibraryQuery(sort=LibrarySort.Duration,ascending=true))
            for(s in listOf(session(account="B"),session(endpoint="https://other.test/api/v1"))) {
                val other=repo(s,dir);other.restore();assertEquals(LibraryQuery(),other.state.value.query)
            }
            val again=repo(session(),dir);again.restore();assertEquals(LibrarySort.Duration,again.state.value.query.sort)
        }finally {dir.deleteRecursively()}
    }
    @Test fun failedSaveRetainsAcceptedSortAndBytesAndCanBeRetried() {
        val dir=Files.createTempDirectory("library-sort-test").toFile()
        try {
            val r=repo(session(),dir);r.restore();r.refine(LibraryQuery(sort=LibrarySort.Title,ascending=true))
            val saved=dir.listFiles()!!.single();val original=saved.readBytes()
            val blocked=File(dir.parentFile,"${dir.name}-saved");assertTrue(dir.renameTo(blocked));dir.writeText("not a directory")
            r.refine(r.state.value.query.copy(text="new search",sort=LibrarySort.Duration,ascending=false))
            assertEquals(LibrarySort.Title,r.state.value.query.sort);assertTrue(r.state.value.query.ascending)
            assertEquals("new search",r.state.value.query.text);assertTrue(r.state.value.sortError)
            assertArrayEquals(original,File(blocked,saved.name).readBytes())
            assertTrue(dir.delete());assertTrue(blocked.renameTo(dir))
            r.refine(r.state.value.query.copy(sort=LibrarySort.Duration,ascending=false));assertFalse(r.state.value.sortError)
            val again=repo(session(),dir);again.restore();assertEquals(LibrarySort.Duration,again.state.value.query.sort);assertFalse(again.state.value.query.ascending)
        }finally {dir.deleteRecursively()}
    }
    @Test fun malformedOrExternallyReplacedStoreIsNotOverwritten() {
        val dir=Files.createTempDirectory("library-sort-test").toFile()
        try {
            val r=repo(session(),dir);r.restore();r.refine(LibraryQuery(sort=LibrarySort.Title))
            val saved=dir.listFiles()!!.single();saved.writeText("rejected bytes")
            r.refine(LibraryQuery(sort=LibrarySort.Artist));assertTrue(r.state.value.sortError)
            assertEquals(LibrarySort.Title,r.state.value.query.sort);assertEquals("rejected bytes",saved.readText())
            val again=repo(session(),dir);again.restore();again.refine(LibraryQuery(sort=LibrarySort.Duration))
            assertTrue(again.state.value.sortError);assertEquals(LibrarySort.Added,again.state.value.query.sort)
            assertEquals("rejected bytes",saved.readText())
        }finally {dir.deleteRecursively()}
    }
}
