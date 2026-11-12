package com.soundq.android.data.device

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.os.Environment
import android.os.storage.StorageManager
import androidx.annotation.RequiresApi
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.CancellationException

/** Platform observations, not Library identities. The catalog alone reconciles aliases/revisions. */
internal data class AudioAccessObservation(
    val locator: String, val providerObject: String, val aliases: Set<String>,
    val filename: String, val title: String, val artist: String?, val album: String?,
    val durationMs: Long?, val size: Long?, val modified: Long?, val mime: String?,
)
internal data class AudioCoverage(val complete: Boolean, val observations: List<AudioAccessObservation>, val truncated: Boolean)
internal data class AudioContentProof(val bytes: Long, val sha256: String)
/** A picker key proved to name the audio-index object [key]. [sameContent]: the route only names the row, so the
 * stored row's bytes must also equal the index row's. */
internal data class IndexKeyProof(val key: String, val sameContent: Boolean)

/** All files access is the only route to phone audio: walk shared storage, index what MediaStore missed, then read
 * the MediaStore audio index. No writes to source, upload, backend or account dependency. Call on IO. */
internal class AndroidAudioAccess(private val context: Context) {
    private val resolver = context.contentResolver
    /** All files access. Before Android 11 there is none; the legacy storage permission is the equivalent read grant. */
    fun storageAllowed() = if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    @RequiresApi(30) fun storageRoots(): List<File> =
        context.getSystemService(StorageManager::class.java).storageVolumes.filter { it.state == Environment.MEDIA_MOUNTED || it.state == Environment.MEDIA_MOUNTED_READ_ONLY }.mapNotNull { it.directory }
    /** With all files access, ask MediaStore to index audio on shared storage it does not list yet, so the
     * indexed scan keeps owning identity. Returns false when the walk or indexing was incomplete. */
    fun indexUnlisted(current: () -> Boolean): Boolean {
        if (Build.VERSION.SDK_INT < 30 || !Environment.isExternalStorageManager()) return true
        val walk = SharedStorageAudioWalker.walk(storageRoots(), current)
        val unlisted = SharedStorageAudioWalker.unlisted(walk.files, ::listedPaths)
        return scanFiles(unlisted, current) && !walk.truncated
    }
    /** Membership in the audio index itself: a Files row can exist with a non-audio media type. */
    @RequiresApi(30) private fun listedPaths(paths: List<String>): Set<String> {
        @Suppress("DEPRECATION") val data = MediaStore.MediaColumns.DATA
        return resolver.query(MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL), arrayOf(data),
            "$data IN (${paths.joinToString(",") { "?" }})", paths.toTypedArray(), null)?.use { cursor ->
            buildSet { while (cursor.moveToNext()) cursor.getString(0)?.let(::add) }
        } ?: throw java.io.IOException("Media index unavailable")
    }
    private fun scanFiles(paths: List<String>, current: () -> Boolean): Boolean {
        if (paths.isEmpty()) return true
        val pending = java.util.concurrent.CountDownLatch(paths.size)
        val failed = java.util.concurrent.atomic.AtomicInteger()
        MediaScannerConnection.scanFile(context, paths.toTypedArray(), null) { _, uri -> if (uri == null) failed.incrementAndGet(); pending.countDown() }
        val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(minOf(300L, 30L + paths.size / 10))
        while (!pending.await(250, java.util.concurrent.TimeUnit.MILLISECONDS)) {
            if (!current()) throw CancellationException("Media indexing retired")
            if (System.nanoTime() > deadline) return false
        }
        return failed.get() == 0
    }
    /** Releases every URI permission older builds' file and folder pickers persisted. Returns how many were held. */
    fun releaseUriPermissions(): Int {
        val held = resolver.persistedUriPermissions
        for (permission in held) {
            val flags = (if (permission.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                (if (permission.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
            runCatching { resolver.releasePersistableUriPermission(permission.uri, flags) }
        }
        return held.size
    }
    /** The MediaStore audio index, read with all files access. */
    fun discover(current: () -> Boolean, signal: CancellationSignal = CancellationSignal()): AudioCoverage {
        val found = linkedMapOf<String, AudioAccessObservation>()
        var truncated = false
        fun checkCurrent() { if (!current()) { signal.cancel(); throw CancellationException("Audio discovery retired") } }
        if (!storageAllowed()) return AudioCoverage(false, emptyList(), false)
        try {
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
                        if (found.size >= MAX_FILES) { truncated = true; break }
                        val uri = ContentUris.withAppendedId(collection, cursor.getLong(0))
                        val filename = cursor.getString(1) ?: "Audio file"
                        val identity = identity(uri)
                        found[identity.key] = AudioAccessObservation(uri.toString(), identity.key, identity.all, filename,
                            cursor.getString(2).cleanTag() ?: filename, cursor.getString(3).cleanTag(), cursor.getString(4).cleanTag(),
                            cursor.nullLong(5), cursor.nullLong(6), cursor.nullLong(7), cursor.getString(8))
                    }
                } ?: throw java.io.IOException("Audio index unavailable")
                if (truncated) break
            }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { return AudioCoverage(false, found.values.toList(), truncated) }
        return AudioCoverage(!truncated, found.values.toList(), truncated)
    }
    /** Whether a scan walks shared storage before reading the index. Only then can coverage be whole enough to
     * retire picker rows the provider could not prove. */
    fun walksSharedStorage() = Build.VERSION.SDK_INT >= 30
    /** Maps object keys an older build's picker stored to the audio-index key of the same object, where the provider
     * proves it: a `media:` key must be a key MediaStore still gives that row (same row, same incarnation); an
     * external-storage or downloads document is found by its path. A `provider:` key from Android 10 or earlier only
     * names the row, so it also needs the index row's bytes to equal the stored row's. Keys it cannot prove are absent. */
    fun provenIndexKeys(objectIds: Collection<String>): Map<String, IndexKeyProof> {
        if (objectIds.isEmpty() || !storageAllowed()) return emptyMap()
        val result = linkedMapOf<String, IndexKeyProof>()
        for (old in objectIds) {
            val route = LegacyPickerIdentity.route(old, ::volumeRoot) ?: continue
            val media = when (route) { is LegacyRoute.Media -> route.uri; is LegacyRoute.Path -> indexedAudioAt(route.path) } ?: continue
            val identity = runCatching { identity(Uri.parse(media)) }.getOrNull() ?: continue
            if (identity.key == old) continue
            when {
                route is LegacyRoute.Path -> result[old] = IndexKeyProof(identity.key, sameContent = false)
                old in identity.all -> result[old] = IndexKeyProof(identity.key, sameContent = false)
                old.startsWith("provider:") -> result[old] = IndexKeyProof(identity.key, sameContent = true)
            }
        }
        return result
    }
    @Suppress("DEPRECATION") private fun volumeRoot(volume: String): String =
        if (volume == "primary") Environment.getExternalStorageDirectory().path else "/storage/$volume"
    /** The audio-index URI of the file at [path]: on the row's concrete volume where Android has volumes. */
    private fun indexedAudioAt(path: String): String? {
        @Suppress("DEPRECATION") val data = MediaStore.MediaColumns.DATA
        val volumes = Build.VERSION.SDK_INT >= 29
        val collection = if (volumes) MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL) else MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val columns = if (volumes) arrayOf(MediaStore.Audio.Media._ID, MediaStore.MediaColumns.VOLUME_NAME) else arrayOf(MediaStore.Audio.Media._ID)
        return runCatching {
            resolver.query(collection, columns, "$data=?", arrayOf(path), null)?.use { cursor ->
                if (cursor.count != 1 || !cursor.moveToFirst()) null
                else if (!volumes) ContentUris.withAppendedId(collection, cursor.getLong(0)).toString()
                else cursor.getString(1)?.takeIf { it.isNotBlank() }?.let { ContentUris.withAppendedId(MediaStore.Audio.Media.getContentUri(it), cursor.getLong(0)).toString() }
            }
        }.getOrNull()
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
    /** Object identity, not the route used to reach it: a MediaStore row is keyed on its audio-index URI (see
     * [MediaStoreIdentity]), with any earlier key kept as former so stored rows fold into one Library row. */
    private fun identity(uri: Uri): ProviderIdentity =
        if (uri.authority == MediaStore.AUTHORITY && Build.VERSION.SDK_INT >= 29) MediaStoreIdentity.of(uri.toString(), uri.pathSegments, mediaRows)
        else ProviderIdentity("provider:$uri")
    @RequiresApi(29) private val mediaRows = object : MediaStoreRows {
        override fun row(uri: String): MediaRowFacts {
            val generation = Build.VERSION.SDK_INT >= 30
            val columns = if (generation) arrayOf(MediaStore.MediaColumns.VOLUME_NAME, MediaStore.MediaColumns.GENERATION_ADDED) else arrayOf(MediaStore.MediaColumns.VOLUME_NAME)
            val facts = try {
                resolver.query(Uri.parse(uri), columns, null, null, null)?.use {
                    if (it.moveToFirst()) MediaRowFacts(if (generation) it.getLong(1) else null, it.getString(0)) else null
                }
            } catch (e: Exception) { if (generation) throw e else null }
            // Before API 30 the key never read the provider; an unreadable volume only skips folding.
            return facts ?: if (generation) throw java.io.IOException("Provider incarnation unavailable") else MediaRowFacts(null, null)
        }
        override fun indexedAudio(volume: String, id: Long): String? {
            val audio = ContentUris.withAppendedId(MediaStore.Audio.Media.getContentUri(volume), id)
            val listed = runCatching { resolver.query(audio, arrayOf(MediaStore.Audio.Media._ID), null, null, null)?.use { it.moveToFirst() } }.getOrNull() == true
            return if (listed) audio.toString() else null
        }
        override fun key(uri: String, volume: String, facts: MediaRowFacts): String =
            if (Build.VERSION.SDK_INT >= 30) "media:${MediaStore.getVersion(context, volume)}:$uri:${requireNotNull(facts.generation)}" else "provider:$uri"
    }
    private fun Cursor.nullLong(index: Int): Long? = if (isNull(index)) null else getLong(index).takeIf { it >= 0 }
    private fun String?.cleanTag(): String? = this?.trim()?.takeIf { it.isNotEmpty() && it != "<unknown>" }
    companion object {
        const val MAX_FILES = 20_000
        const val MAX_SOURCE_BYTES = 8L * 1024 * 1024 * 1024
        const val DISK_RESERVE_BYTES = 64L * 1024 * 1024
        const val MAX_ART_BYTES = 4 * 1024 * 1024
    }
}
