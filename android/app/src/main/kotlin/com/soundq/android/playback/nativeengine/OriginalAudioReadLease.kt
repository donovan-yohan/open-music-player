package com.soundq.android.playback.nativeengine

import android.content.ContentResolver
import android.media.MediaDataSource
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import com.soundq.android.data.device.OriginalFileStamp
import java.io.File
import java.io.IOException
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Captured live-file VERSION observation, deliberately not cryptographic content proof.
 * Each positioned read is confined to the provider asset range. Owns one duplicated fd.
 * Framework MediaDataSource callbacks may run on another thread, never the render callback.
 */
internal class OriginalAudioReadLease private constructor(
    private val descriptor: ParcelFileDescriptor,
    private val custody: OriginalDescriptorCustody.Ticket,
    val offset: Long, val length: Long,
    val path: String,
    val stamp: OriginalFileStamp,
    private val current: () -> Boolean,
    private val changed: () -> Unit,
    private val routeCurrent: () -> Boolean,
) : MediaDataSource() {
    private val retired = AtomicBoolean()
    private val closed = AtomicBoolean()
    private var closeFailed=false
    private val failure = AtomicReference<Throwable?>()
    private var deadline = 0L
    private var operationBytes = 0L
    private var operationCalls = 0
    @Volatile var totalReadBytes = 0L; private set
    @Volatile var totalReadCalls = 0L; private set
    val active: Boolean get() = !closed.get() && !retired.get() && failure.get()==null
    val version: String get() = "$stamp:$offset:$length"
    fun revoke() { retired.set(true) }
    fun checkCurrent() {
        failure.get()?.let { throw IOException("Original source read failed", it) }
        if (closed.get() || retired.get() || !current()) throw CancellationException("Original source retired")
        val fd = facts(Os.fstat(descriptor.fileDescriptor))
        val named = facts(Os.stat(path))
        if (fd != stamp || named != stamp || !routeCurrent()) {
            val error = IOException("Original audio changed or was replaced")
            failure.compareAndSet(null,error); retired.set(true); changed(); throw error
        }
    }
    /** Bounded open/seek/window IO, including extractor metadata/index reads. */
    @Synchronized fun beginOperation() { checkCurrent(); deadline=System.nanoTime()+15_000_000_000L;operationBytes=0;operationCalls=0 }
    @Synchronized override fun readAt(position: Long, buffer: ByteArray, bufferOffset: Int, size: Int): Int {
        try {
            checkCurrent()
            require(position>=0 && bufferOffset>=0 && size>=0 && bufferOffset<=buffer.size-size)
            if(size==0)return 0
            check(System.nanoTime()<deadline && ++operationCalls<=8192) { "Original decoder read deadline/call budget exceeded" }
            if(position>=length)return -1
            val count=minOf(size.toLong(),length-position).toInt()
            operationBytes=Math.addExact(operationBytes,count.toLong())
            check(operationBytes<=32L*1024*1024) { "Original decoder read budget exceeded; unindexed seek refused" }
            val n=Os.pread(descriptor.fileDescriptor,buffer,bufferOffset,count,Math.addExact(offset,position))
            check(n>0) { "Original file truncated or made no read progress" }
            totalReadBytes+=n;totalReadCalls++
            checkCurrent();return n
        } catch(error:Throwable) { failure.compareAndSet(null,error);throw error }
    }
    override fun getSize(): Long { checkCurrent();return length }
    @Synchronized override fun close() {
        if(closeFailed)throw IOException("Previous original descriptor close was not certified")
        if(!closed.get()) {
            retired.set(true)
            try {custody.close();closed.set(true)}catch(error:Throwable){closeFailed=true;throw error}
        }
    }
    companion object {
        // API26 explicitly records absent nanoseconds. This is a weaker live-version
        // observation, never a destructive stamp or equality with a prior SHA.
        private fun facts(s: StructStat) = OriginalFileStamp.of(s)
        /** Duplicates a caller-owned descriptor. A negative length resolves only
         * from a regular-file extent; every positive slice is validated exactly. */
        fun borrow(input:java.io.FileDescriptor,start:Long,declaredLength:Long,path:String,current:()->Boolean,changed:()->Unit={},sourceKey:String=path,routeCurrent:()->Boolean={true}):OriginalAudioReadLease {
            val fd=ParcelFileDescriptor.dup(input)
            val custody=OriginalDescriptorCustody.own(sourceKey,fd::close)
            try {
                val stat=Os.fstat(fd.fileDescriptor)
                require(OsConstants.S_ISREG(stat.st_mode)) {"Original audio requires a seekable regular file"}
                val length=if(declaredLength>=0)declaredLength else stat.st_size-start
                require(start>=0 && length>0 && length<=8L*1024*1024*1024 && start<=stat.st_size && length<=stat.st_size-start)
                return OriginalAudioReadLease(fd,custody,start,length,File(path).absolutePath,facts(stat),current,changed,routeCurrent).also {it.checkCurrent()}
            } catch(error:Throwable) {try {custody.close()}catch(close:Throwable){error.addSuppressed(close)};throw error}
        }
        fun open(resolver:ContentResolver,locator:String,current:()->Boolean,changed:()->Unit={},sourceKey:String=locator):OriginalAudioReadLease {
            val uri=Uri.parse(locator);require(uri.scheme=="content")
            // Reserve the source drain before a provider call can block with an
            // acquired descriptor that has not returned to our registration code.
            val acquisition=OriginalDescriptorCustody.own(sourceKey) {}
            return acquisition.use {
                @Suppress("DEPRECATION") val column=MediaStore.MediaColumns.DATA
                if(uri.authority==MediaStore.AUTHORITY) {
                    // All-files access names the actual original. MediaProvider's fd can
                    // inhabit a different device/ctime view, so never compare its stamp
                    // with a path stamp or pretend those observations bind physically.
                    val columns=mutableListOf(column,MediaStore.MediaColumns.SIZE,MediaStore.MediaColumns.DATE_MODIFIED)
                    if(Build.VERSION.SDK_INT>=30)columns+=listOf(MediaStore.MediaColumns.GENERATION_ADDED,MediaStore.MediaColumns.GENERATION_MODIFIED)
                    fun route()=resolver.query(uri,columns.toTypedArray(),null,null,null)?.use {c->
                        if(c.count!=1||!c.moveToFirst())null else columns.indices.map {c.getString(it) ?: return@use null}
                    }
                    val captured=route() ?: throw IOException("Original media route unavailable")
                    val file=File(captured.first())
                    require(file.isAbsolute&&file.canonicalPath==file.path) {"Original media path is not canonical"}
                    val direct=ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY)
                    val custody=OriginalDescriptorCustody.own(sourceKey,direct::close)
                    var original:OriginalAudioReadLease?=null
                    try {
                        custody.use {original=borrow(direct.fileDescriptor,0,-1,file.path,current,changed,sourceKey) {route()==captured}}
                        return@use requireNotNull(original)
                    } catch(error:Throwable) {
                        try {original?.close()}catch(close:Throwable){error.addSuppressed(close)}
                        throw error
                    }
                }
                val path=resolver.query(uri,arrayOf(column),null,null,null)?.use {if(it.moveToFirst())it.getString(0)else null}
                    ?: throw IOException("Original audio path unavailable for replacement observation")
                val asset=resolver.openAssetFileDescriptor(uri,"r") ?: throw java.io.FileNotFoundException("Original audio unavailable")
                val custody=OriginalDescriptorCustody.own(sourceKey,asset::close)
                var original:OriginalAudioReadLease?=null
                try {
                    custody.use {original=borrow(asset.fileDescriptor,asset.startOffset,asset.declaredLength,path,current,changed,sourceKey)}
                    requireNotNull(original)
                } catch(error:Throwable) {
                    try {original?.close()}catch(close:Throwable){error.addSuppressed(close)}
                    throw error
                }
            }
        }
    }
}
