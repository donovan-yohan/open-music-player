package com.soundq.android.data.device

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.provider.DocumentsContract
import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.CancellationException

/** Platform observations, not Library identities. The catalog alone reconciles aliases/revisions. */
internal data class AudioAccessObservation(
    val locator: String, val providerObject: String, val aliases: Set<String>, val grant: String?,
    val filename: String, val title: String, val artist: String?, val album: String?,
    val durationMs: Long?, val size: Long?, val modified: Long?, val mime: String?,
)
internal data class AudioCoverage(val indexedAllowed: Boolean, val indexedComplete: Boolean,
    val observations: List<AudioAccessObservation>, val unavailableGrants: Set<String>, val truncated: Boolean)
internal data class AudioContentProof(val bytes: Long, val sha256: String)

/** No filesystem crawl, writes to source, upload, backend or account dependency. Call on IO. */
internal class AndroidAudioAccess(private val context: Context) {
    private val resolver = context.contentResolver
    val permission: String get() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_EXTERNAL_STORAGE
    fun indexedAllowed() = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    fun persistedTrees(): List<String> = resolver.persistedUriPermissions.filter { it.isReadPermission && DocumentsContract.isTreeUri(it.uri) }.map { it.uri.toString() }
    fun persist(uri: Uri, flags: Int, tree: Boolean) {
        require(uri.scheme == "content")
        if (tree) require(validTree(uri)) { "Choose a supported subfolder, not a storage or Downloads root" }
        val read = flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
        require(read != 0)
        resolver.takePersistableUriPermission(uri, read)
    }
    fun release(locator: String) {
        resolver.releasePersistableUriPermission(Uri.parse(locator), Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    fun validTree(uri: Uri): Boolean {
        if (!DocumentsContract.isTreeUri(uri)) return false
        val id = runCatching { DocumentsContract.getTreeDocumentId(uri) }.getOrNull() ?: return false
        if (uri.authority == "com.android.externalstorage.documents") {
            val relative = id.substringAfter(':', "").trim('/')
            if (relative.isEmpty() || relative.equals("Download", true) || relative.equals("Downloads", true) ||
                relative.startsWith("Android/data", true) || relative.startsWith("Android/obb", true)) return false
        }
        if (uri.authority == "com.android.providers.downloads.documents" && id in setOf("downloads", "root")) return false
        return true
    }
    fun folderLabel(locator: String): String {
        val tree = Uri.parse(locator)
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return resolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: "Added folder"
    }
    /** Audio index includes exposed Documents/Downloads entries; it is not exhaustive folder access. */
    fun discover(trees: List<String>, current: () -> Boolean, signal: CancellationSignal = CancellationSignal(), includeIndexed: Boolean = true): AudioCoverage {
        val found = linkedMapOf<String, AudioAccessObservation>()
        var truncated = false
        fun checkCurrent() { if (!current()) { signal.cancel(); throw CancellationException("Audio discovery retired") } }
        fun add(row: AudioAccessObservation) { if (found.size < MAX_FILES) found[row.providerObject] = row else truncated = true }
        val allowed = indexedAllowed()
        var complete = false
        if (allowed && includeIndexed) try {
            val volumes = if (Build.VERSION.SDK_INT >= 29) MediaStore.getExternalVolumeNames(context) else setOf("external")
            for (volume in volumes) {
                checkCurrent()
                val collection = if (Build.VERSION.SDK_INT >= 29) MediaStore.Audio.Media.getContentUri(volume) else MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                resolver.query(collection, arrayOf(MediaStore.Audio.Media._ID, MediaStore.Audio.Media.DISPLAY_NAME,
                    MediaStore.Audio.Media.TITLE, MediaStore.Audio.Media.ARTIST, MediaStore.Audio.Media.ALBUM,
                    MediaStore.Audio.Media.DURATION, MediaStore.Audio.Media.SIZE, MediaStore.Audio.Media.DATE_MODIFIED,
                    MediaStore.Audio.Media.MIME_TYPE), null, null, "_id ASC", signal)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        checkCurrent()
                        val uri = ContentUris.withAppendedId(collection, cursor.getLong(0))
                        val filename = cursor.getString(1) ?: "Audio file"
                        add(AudioAccessObservation(uri.toString(), objectKey(uri), aliases(uri), null, filename,
                            cursor.getString(2).cleanTag() ?: filename, cursor.getString(3).cleanTag(), cursor.getString(4).cleanTag(),
                            cursor.nullLong(5), cursor.nullLong(6), cursor.nullLong(7), cursor.getString(8)))
                        if (truncated) break
                    }
                } ?: throw java.io.IOException("Audio index unavailable")
            }
            complete = !truncated
        } catch (e: CancellationException) { throw e } catch (_: Exception) { complete = false }
        val unavailable = mutableSetOf<String>()
        for (grant in trees) {
            checkCurrent()
            try {
                val tree = Uri.parse(grant); require(validTree(tree))
                val pending = ArrayDeque<String>(); pending.add(DocumentsContract.getTreeDocumentId(tree))
                val visited = mutableSetOf<String>()
                while (pending.isNotEmpty()) {
                    checkCurrent()
                    val id = pending.removeFirst()
                    if (!visited.add(id)) continue
                    if (visited.size > MAX_FOLDERS) { truncated = true; break }
                    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
                    resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
                        DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null, signal)?.use { cursor ->
                        while (cursor.moveToNext()) {
                            checkCurrent()
                            val child = cursor.getString(0)
                            val mime = cursor.getString(2).orEmpty()
                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) pending.add(child)
                            else if (mime.startsWith("audio/") || cursor.getString(1).orEmpty().substringAfterLast('.').lowercase() in AUDIO_EXTENSIONS) {
                                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, child)
                                add(metadata(uri, grant, cursor.getString(1) ?: "Audio file", cursor.nullLong(3), cursor.nullLong(4), mime))
                            }
                            if (truncated) break
                        }
                    } ?: throw java.io.IOException("Folder unavailable")
                    if (truncated) break
                }
            } catch (e: CancellationException) { throw e } catch (_: Exception) { unavailable.add(grant) }
        }
        return AudioCoverage(allowed, complete, found.values.toList(), unavailable, truncated)
    }
    fun metadata(uri: Uri, grant: String? = null, fallback: String = "Audio file", size: Long? = null, modified: Long? = null, mime: String? = null): AudioAccessObservation {
        require(uri.scheme == "content")
        var filename = fallback; var bytes = size
        resolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst()) { filename = it.getString(0) ?: fallback; bytes = it.nullLong(1) ?: size }
        }
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            return AudioAccessObservation(uri.toString(), objectKey(uri), aliases(uri), grant, filename,
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE).cleanTag() ?: filename,
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST).cleanTag(),
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM).cleanTag(),
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull(), bytes, modified, mime ?: resolver.getType(uri))
        } finally { retriever.release() }
    }
    fun embeddedArtwork(locator: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        return try { retriever.setDataSource(context, Uri.parse(locator)); retriever.embeddedPicture?.takeIf { it.size <= MAX_ART_BYTES } }
        finally { retriever.release() }
    }
    /** Exact-byte proof used by the catalog to establish revision, never by filename similarity. */
    fun proof(locator: String, current: () -> Boolean): AudioContentProof = copyOrHash(locator, null, current)
    /** Target must be a newly created private stage; original provider bytes are read-only. */
    fun copy(locator: String, target: File, current: () -> Boolean): AudioContentProof = copyOrHash(locator, target, current)
    private fun copyOrHash(locator: String, target: File?, current: () -> Boolean): AudioContentProof {
        val uri = Uri.parse(locator); require(uri.scheme == "content")
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        val descriptor = resolver.openAssetFileDescriptor(uri, "r")
            ?: throw java.io.FileNotFoundException("Audio provider unavailable")
        descriptor.use {
            require(descriptor.declaredLength <= MAX_SOURCE_BYTES)
            descriptor.createInputStream().use { input ->
                val output = target?.let(::FileOutputStream)
                try {
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        if (!current()) throw CancellationException("Audio source retired")
                        val n = input.read(buffer); if (n < 0) break
                        if (n == 0) throw java.io.IOException("Audio provider made no progress")
                        total = Math.addExact(total, n.toLong()); require(total <= MAX_SOURCE_BYTES)
                        if (output != null) { require(target!!.parentFile!!.usableSpace > DISK_RESERVE_BYTES); output.write(buffer, 0, n) }
                        digest.update(buffer, 0, n)
                    }
                    require(total > 0 && (descriptor.declaredLength < 0 || total == descriptor.declaredLength))
                    output?.fd?.sync()
                } finally { output?.close() }
            }
        }
        if (!current()) throw CancellationException("Audio source retired")
        return AudioContentProof(total, digest.digest().joinToString("") { "%02x".format(it) })
    }
    private fun aliases(uri: Uri): Set<String> = buildSet {
        add(objectKey(uri))
        if (Build.VERSION.SDK_INT >= 29) runCatching { MediaStore.getMediaUri(context, uri) }.getOrNull()?.let { add(objectKey(it)) }
    }
    private fun objectKey(uri: Uri): String {
        if (Build.VERSION.SDK_INT >= 29 && DocumentsContract.isDocumentUri(context, uri)) {
            runCatching { MediaStore.getMediaUri(context, uri) }.getOrNull()?.let { return objectKey(it) }
        }
        if (uri.authority == MediaStore.AUTHORITY && Build.VERSION.SDK_INT >= 30) {
            val generation = resolver.query(uri, arrayOf(MediaStore.MediaColumns.GENERATION_ADDED), null, null, null)?.use {
                if (it.moveToFirst()) it.getLong(0) else null
            } ?: throw java.io.IOException("Provider incarnation unavailable")
            val volume = uri.pathSegments.firstOrNull() ?: throw java.io.IOException("Provider volume unavailable")
            return "media:${MediaStore.getVersion(context, volume)}:$uri:$generation"
        }
        return if (DocumentsContract.isDocumentUri(context, uri))
            "document:${uri.authority}:${DocumentsContract.getDocumentId(uri)}" else "provider:$uri"
    }
    private fun Cursor.nullLong(index: Int): Long? = if (isNull(index)) null else getLong(index).takeIf { it >= 0 }
    private fun String?.cleanTag(): String? = this?.trim()?.takeIf { it.isNotEmpty() && it != "<unknown>" }
    companion object {
        const val MAX_FILES = 20_000
        const val MAX_FOLDERS = 4096
        const val MAX_SOURCE_BYTES = 8L * 1024 * 1024 * 1024
        const val DISK_RESERVE_BYTES = 64L * 1024 * 1024
        const val MAX_ART_BYTES = 4 * 1024 * 1024
        private val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "alac")
    }
}
