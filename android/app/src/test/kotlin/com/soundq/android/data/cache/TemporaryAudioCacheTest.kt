package com.soundq.android.data.cache

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class TemporaryAudioCacheTest {
    private class Fixture:AutoCloseable {
        val dir=Files.createTempDirectory(java.io.File(System.getenv("TMPDIR")).toPath(),"temporary-cache").toFile().canonicalFile
        val session=AccountSession(ApiEndpoint.parse("https://cache.example.test/api/v1"),object:SessionStore {
            override fun load(endpoint:ApiEndpoint):SecretTokens?=null
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
            override fun clear(){}
        }).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
        val scope=session.capture()!!
        val cache=TemporaryAudioCache(dir,session)
        fun complete(id:Long=7):Boolean {val w=cache.begin(scope,TrackId(id),4)!!;w.append(byteArrayOf(1,2,3,4),0,4);return w.finish()}
        override fun close(){dir.deleteRecursively()}
    }
    @Test fun clearDefersExactActiveFileAndRejectsLateCompletion() {
        Fixture().use {f ->
            assertTrue(f.complete());val file=f.dir.listFiles()!!.single {it.extension=="audio"}
            val lease=f.cache.acquire(f.scope,TrackId(7))!!
            val late=f.cache.begin(f.scope,TrackId(8),4)!!;late.append(byteArrayOf(4,3,2,1),0,4)
            assertEquals(CacheClearResult(0,1,0),f.cache.clear());assertFalse(late.finish())
            assertNull(f.cache.acquire(f.scope,TrackId(7)));assertTrue(file.exists())
            assertEquals(4L,f.cache.status().bytes);assertEquals(1,f.cache.status().deferredFiles)
            val b=ByteArray(4);assertEquals(4,lease.read(b,0,4));assertArrayEquals(byteArrayOf(1,2,3,4),b)
            lease.close();assertFalse(file.exists());assertEquals(0L,f.cache.status().bytes)
        }
    }
    @Test fun reconstructedStoreUsesOwnedBytesAndClearNeverDeletesUnknownFiles() {
        Fixture().use {f ->
            assertTrue(f.complete())
            val restored=TemporaryAudioCache(f.dir,f.session);val lease=restored.acquire(f.scope,TrackId(7))!!;lease.close()
            val foreign=f.dir.resolve("foreign.audio").apply {writeText("keep")}
            assertNull(restored.status().bytes)
            assertEquals(1,restored.clear().removedFiles);assertEquals("keep",foreign.readText())
        }
    }
    @Test fun replacementDirectoryAndSameByteFileAreNeverDeletedOrPromoted() {
        Fixture().use {f ->
            assertTrue(f.complete());val old=f.dir.resolve("../${f.dir.name}-old")
            Files.move(f.dir.toPath(),old.toPath());f.dir.mkdirs()
            try {
                old.listFiles()!!.forEach {it.copyTo(f.dir.resolve(it.name))}
                val file=f.dir.listFiles()!!.single {it.extension=="audio"}
                assertNull(f.cache.acquire(f.scope,TrackId(7)));assertTrue(f.cache.clear().failedFiles>0)
                assertTrue(file.exists());assertArrayEquals(byteArrayOf(1,2,3,4),file.readBytes())
                assertNull(TemporaryAudioCache(f.dir,f.session).acquire(f.scope,TrackId(7)))
            }finally {old.deleteRecursively()}
        }
    }
    @Test fun capturedClearDoesNotDeleteReplacementAccountBytesAndStillCatchesCapturedPromotion() {
        Fixture().use {f ->
            assertTrue(f.complete())
            val capturedStage=f.cache.begin(f.scope,TrackId(8),4)!!;capturedStage.append(byteArrayOf(1,2,3,4),0,4)
            val clear=f.cache.captureClear();assertTrue(capturedStage.finish())
            f.session.accept(f.session.beginIntent(),SecretTokens("b","br","B"));val next=f.session.capture()!!
            val fresh=f.cache.begin(next,TrackId(7),4)!!;fresh.append(byteArrayOf(9,8,7,6),0,4);assertTrue(fresh.finish())
            assertEquals(2,f.cache.clear(clear).removedFiles)
            val lease=f.cache.acquire(next,TrackId(7))!!;val bytes=ByteArray(4);lease.read(bytes,0,4);lease.close()
            assertArrayEquals(byteArrayOf(9,8,7,6),bytes)
        }
    }
    @Test fun accountABAAndTruncatedWriteCannotPublish() {
        Fixture().use {f ->
            val w=f.cache.begin(f.scope,TrackId(7),4)!!;w.append(byteArrayOf(1),0,1);assertFalse(w.finish())
            val old=f.cache.begin(f.scope,TrackId(7),4)!!;old.append(byteArrayOf(1,2,3,4),0,4)
            f.session.accept(f.session.beginIntent(),SecretTokens("b","r","B"));f.session.accept(f.session.beginIntent(),SecretTokens("a2","r2","A"))
            assertFalse(old.finish());assertNull(f.cache.acquire(f.session.capture()!!,TrackId(7)))
            assertEquals(0L,f.cache.status().bytes)
        }
    }
}
