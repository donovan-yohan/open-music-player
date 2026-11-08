package com.soundq.android.playback

import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.*
import org.junit.Test

class LargeContextTest {
    private fun rows(n:Int)=List(n){i->SavedOccurrence("occ-$i",if(i==2)1 else i+1L,"Song $i","Fixture",i in 3..4,false,12000)}
    private fun snapshot(n:Int)=QueueSnapshot("https://fixture.invalid/api/v1","A",rows(n),n-1,4300,true,SavedRepeatMode.All)
    private fun directory()=Files.createTempDirectory(Path.of(System.getenv("TMPDIR")),"large-metadata-").toFile()
    @Test fun completeMetadataIsPagedAndRestartsWithExactLaterSelectionAndRepeatedOccurrences() {
        for(n in listOf(500,501,12037))directory().let {dir->try {
            val file=java.io.File(dir,"queue.json");val expected=snapshot(n)
            QueueSnapshotStore(file).write(expected)
            val actual=QueueSnapshotStore(file).read(expected.endpoint,"A")!!
            assertEquals((0 until n).map {"occ-$it"},actual.items.map {it.occurrence})
            assertEquals(expected,actual);assertEquals("occ-${n-1}",actual.items[actual.selected].occurrence)
            assertEquals(listOf(1L,2L,1L),actual.items.take(3).map {it.track})
            assertTrue(file.length()<=500000)
            java.io.File(dir,"queue.json.pages").listFiles()!!.forEach {page->
                assertTrue(page.length()<=500000)
                val decoded=QueueSnapshot.decode(page.readText(),expected.endpoint,"A")!!
                assertTrue(decoded.items.size<=500)
            }
            if(n>500)assertNull(QueueSnapshot.decode(expected.encode(),expected.endpoint,"A"))
            assertTrue(runCatching {QueueSnapshotStore(file).read(expected.endpoint,"B")}.isFailure)
            assertTrue(runCatching {QueueSnapshotStore(file).read("https://other.invalid/api/v1","A")}.isFailure)
        }finally {dir.deleteRecursively()}}
    }
    @Test fun failedOrCancelledPublicationCannotReplaceOldPausedObservation()=directory().let {dir->try {
        val file=java.io.File(dir,"queue.json");val store=QueueSnapshotStore(file);val old=snapshot(500)
        store.write(old);val bytes=file.readBytes()
        var calls=0
        assertTrue(runCatching {store.write(snapshot(12037)){++calls<4}}.isFailure)
        assertArrayEquals(bytes,file.readBytes());assertEquals(old,QueueSnapshotStore(file).read(old.endpoint,"A"))
        val invalid=snapshot(501).copy(items=rows(501).toMutableList().apply {this[500]=this[0]})
        assertTrue(runCatching {store.write(invalid)}.isFailure);assertArrayEquals(bytes,file.readBytes())
        val huge=snapshot(501).copy(items=rows(501).map {it.copy(title="é".repeat(260000))})
        assertTrue(runCatching {store.write(huge)}.isFailure);assertArrayEquals(bytes,file.readBytes())
    }finally {dir.deleteRecursively()}}
    @Test fun corruptionOrMissingPageIsRefusedWithoutPartialRestore()=directory().let {dir->try {
        val file=java.io.File(dir,"queue.json");val expected=snapshot(501);val store=QueueSnapshotStore(file)
        store.write(expected)
        val page=java.io.File(dir,"queue.json.pages").listFiles()!!.first()
        val bytes=page.readBytes();page.writeBytes(bytes.copyOf().apply {this[lastIndex]=(this[lastIndex].toInt() xor 1).toByte()})
        assertTrue(runCatching {store.read(expected.endpoint,"A")}.isFailure)
        page.writeBytes(bytes);page.delete();assertTrue(runCatching {store.read(expected.endpoint,"A")}.isFailure)
    }finally {dir.deleteRecursively()}}
    @Test fun processRestartReclaimsUnreplayableStagingWithoutDeletingDurableQueue()=directory().let {dir->try {
        val saved=snapshot(501);val durable=java.io.File(dir,"queue.json");QueueSnapshotStore(durable).write(saved)
        val staging=java.io.File(dir,"context-starts");val starts=ContextStartAdmission(staging)
        val capture=starts.capture(saved.endpoint,saved.account){true};starts.stage(capture,saved)
        assertTrue(staging.listFiles()!!.isNotEmpty())
        val restarted=ContextStartAdmission(staging)
        assertNull(restarted.claim(capture.ticket));assertTrue(staging.listFiles().orEmpty().isEmpty())
        assertEquals(saved,QueueSnapshotStore(durable).read(saved.endpoint,saved.account))
    }finally {dir.deleteRecursively()}}
    @Test fun sourceAdmissionNeverRevivesAcrossAbaOrReplaysClaim()=directory().let {dir->try {
        val starts=ContextStartAdmission(dir);var query="A"
        val first=starts.capture("endpoint","account"){query=="A"}
        query="B";assertFalse(starts.current(first));query="A";assertFalse(starts.current(first))
        val second=starts.capture("endpoint","account"){true}
        assertNull(starts.claim(first.ticket));assertSame(second,starts.claim(second.ticket));assertNull(starts.claim(second.ticket))
        starts.retire();assertFalse(starts.current(second))
        val saved=snapshot(501);val fresh=starts.capture(saved.endpoint,saved.account){true}
        starts.stage(fresh,saved);assertEquals(saved,starts.read(fresh));starts.finish(fresh)
        assertFalse(starts.current(fresh));assertNull(starts.claim(fresh.ticket))
    }finally {dir.deleteRecursively()}}

    @Test fun pagedJamProvenanceKeepsCanonicalKeysAndRefusesCrossPageDuplicateAdmission()=directory().let {dir->try {
        val jam=com.soundq.android.data.jam.JamOccurrence("a".repeat(64),"00000000-0000-0000-0000-000000000001","fixture")
        val second=com.soundq.android.data.jam.JamOccurrence("b".repeat(64),"00000000-0000-0000-0000-000000000002","fixture")
        val all=rows(501).toMutableList().apply {this[0]=this[0].copy(jam=jam);this[500]=this[500].copy(jam=second)}
        val expected=snapshot(501).copy(items=all)
        val file=java.io.File(dir,"queue.json");val store=QueueSnapshotStore(file)
        store.write(expected);assertEquals(expected,store.read(expected.endpoint,"A"))
        val bytes=file.readBytes()
        val duplicate=expected.copy(items=all.toMutableList().apply {this[500]=this[500].copy(jam=jam)})
        assertTrue(runCatching {store.write(duplicate)}.isFailure);assertArrayEquals(bytes,file.readBytes())
        // Construct independently valid pages with globally duplicated canonical evidence.
        val pageDir=java.io.File(dir,"queue.json.pages")
        val root=kotlinx.serialization.json.Json.parseToJsonElement(file.readText()).let {it as kotlinx.serialization.json.JsonObject}
        val pages=root.getValue("pages") as kotlinx.serialization.json.JsonArray
        val descriptor=pages[1] as kotlinx.serialization.json.JsonObject
        val encoded=QueueSnapshot(expected.endpoint,"A",listOf(all[500].copy(jam=jam)),0,0).encode().toByteArray()
        val hash=java.security.MessageDigest.getInstance("SHA-256").digest(encoded).joinToString("") {"%02x".format(it)}
        java.io.File(pageDir,hash).writeBytes(encoded)
        val changed=kotlinx.serialization.json.JsonObject(descriptor+mapOf("sha256" to kotlinx.serialization.json.JsonPrimitive(hash)))
        file.writeText(kotlinx.serialization.json.JsonObject(root+mapOf("pages" to kotlinx.serialization.json.JsonArray(listOf(pages[0],changed)))).toString())
        assertTrue(runCatching {store.read(expected.endpoint,"A")}.isFailure)
    }finally {dir.deleteRecursively()}}
}
