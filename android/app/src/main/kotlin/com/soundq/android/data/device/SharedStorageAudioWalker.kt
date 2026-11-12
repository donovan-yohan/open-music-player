package com.soundq.android.data.device

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CancellationException

/** Audio files found on shared storage. [truncated] means coverage is incomplete: a bound stopped the walk
 * or an existing directory could not be listed. */
internal data class StorageAudioWalk(val files: List<File>, val truncated: Boolean)

/** Bounded walk of shared-storage roots for audio files, including the Download root.
 * Finds candidates for MediaStore indexing only; it is not a Library identity.
 * Skips Android/data and Android/obb (app-private), hidden directories, symlinks
 * and directories containing `.nomedia` (MediaStore will not index those). Call on IO. */
internal object SharedStorageAudioWalker {
    val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "aif", "alac")
    const val MAX_FILES = 20_000
    const val MAX_FOLDERS = 50_000

    fun walk(roots: List<File>, current: () -> Boolean, maxFiles: Int = MAX_FILES, maxFolders: Int = MAX_FOLDERS): StorageAudioWalk {
        val found = ArrayList<File>()
        var folders = 0
        var truncated = false
        val visited = HashSet<String>()
        for (root in roots) {
            val pending = ArrayDeque<File>().apply { add(root) }
            while (pending.isNotEmpty()) {
                if (!current()) throw CancellationException("Storage walk retired")
                val dir = pending.removeFirst()
                if (!visited.add(dir.absolutePath)) continue
                if (++folders > maxFolders) { truncated = true; break }
                // listFiles() is null for an I/O failure as well as a missing root; only the latter is complete.
                val children = dir.listFiles() ?: run { if (dir.exists()) truncated = true; null } ?: continue
                if (children.any { it.name == ".nomedia" }) continue
                for (child in children.sortedBy { it.name }) {
                    if (child.name.startsWith(".") || Files.isSymbolicLink(child.toPath())) continue
                    if (child.isDirectory) {
                        if (!skipped(root, child)) pending.add(child)
                    } else if (child.isFile && child.extension.lowercase() in AUDIO_EXTENSIONS) {
                        if (found.size >= maxFiles) { truncated = true; break }
                        found.add(child)
                    }
                }
                if (truncated) break
            }
            if (truncated) break
        }
        return StorageAudioWalk(found, truncated)
    }

    /** Walked paths MediaStore does not list yet, looked up in bounded batches. */
    fun unlisted(files: List<File>, listed: (List<String>) -> Set<String>, batch: Int = 400): List<String> =
        files.map { it.absolutePath }.chunked(batch).flatMap { chunk -> listed(chunk).let { known -> chunk.filter { it !in known } } }

    private fun skipped(root: File, dir: File): Boolean {
        val relative = dir.relativeTo(root).invariantSeparatorsPath
        return relative.equals("Android/data", true) || relative.equals("Android/obb", true)
    }
}
