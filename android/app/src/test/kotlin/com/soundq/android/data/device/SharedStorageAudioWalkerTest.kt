package com.soundq.android.data.device

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class SharedStorageAudioWalkerTest {
    private fun tree(body:(File)->Unit):File=Files.createTempDirectory("storage-walk-").toFile().also(body)
    private fun File.put(path:String)=File(this,path).apply {parentFile!!.mkdirs();writeBytes(byteArrayOf(1,2,3))}
    private fun names(walk:StorageAudioWalk,root:File)=walk.files.map {it.relativeTo(root).invariantSeparatorsPath}.toSet()

    @Test fun findsAudioInDownloadRootAndNestedFoldersButNotPrivateHiddenOrNomedia() {
        val root=tree {
            it.put("Download/Song.MP3");it.put("Music/Spotify/Synced files/a.flac");it.put("Deep/one/two/three/b.opus")
            it.put("Android/media/com.app/voice.m4a")
            it.put("Android/data/com.app/cache.mp3");it.put("Android/obb/com.game/theme.ogg")
            it.put(".hidden/secret.mp3");it.put("Ringtones/.thumbnails/x.mp3")
            it.put("Podcasts/private/.nomedia");it.put("Podcasts/private/episode.mp3")
            it.put("Download/notes.txt");it.put("Download/cover.jpg")
        }
        try {
            val walk=SharedStorageAudioWalker.walk(listOf(root),{true})
            assertFalse(walk.truncated)
            assertEquals(setOf("Download/Song.MP3","Music/Spotify/Synced files/a.flac","Deep/one/two/three/b.opus","Android/media/com.app/voice.m4a"),names(walk,root))
        } finally {root.deleteRecursively()}
    }

    @Test fun symlinkCyclesAreNotFollowed() {
        val root=tree {it.put("Music/a.mp3");Files.createSymbolicLink(File(it,"Music/loop").toPath(),it.toPath())}
        try {assertEquals(setOf("Music/a.mp3"),names(SharedStorageAudioWalker.walk(listOf(root),{true}),root))}
        finally {root.deleteRecursively()}
    }

    @Test fun boundsReportTruncationAndRetirementCancels() {
        val root=tree {d->repeat(5){d.put("Music/$it.mp3")}}
        try {
            val walk=SharedStorageAudioWalker.walk(listOf(root),{true},maxFiles=3)
            assertTrue(walk.truncated);assertEquals(3,walk.files.size)
            assertThrows(java.util.concurrent.CancellationException::class.java) {SharedStorageAudioWalker.walk(listOf(root),{false})}
        } finally {root.deleteRecursively()}
    }

    @Test fun onlyPathsMediaStoreDoesNotListAreSentForIndexingInBoundedBatches() {
        val files=(1..5).map {File("/storage/emulated/0/Download/$it.mp3")}
        val batches=mutableListOf<Int>()
        val unlisted=SharedStorageAudioWalker.unlisted(files,{chunk->batches+=chunk.size;chunk.filter {it.endsWith("2.mp3")||it.endsWith("4.mp3")}.toSet()},batch=2)
        assertEquals(listOf("/storage/emulated/0/Download/1.mp3","/storage/emulated/0/Download/3.mp3","/storage/emulated/0/Download/5.mp3"),unlisted)
        assertEquals(listOf(2,2,1),batches)
    }

    @Test fun unreadableOrMissingRootIsEmptyNotFatal() {
        val walk=SharedStorageAudioWalker.walk(listOf(File("/definitely/not/mounted")),{true})
        assertTrue(walk.files.isEmpty());assertFalse(walk.truncated)
    }
}
