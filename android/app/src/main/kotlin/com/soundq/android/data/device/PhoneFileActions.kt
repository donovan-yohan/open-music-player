package com.soundq.android.data.device

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.system.Os
import android.system.StructStat
import com.soundq.android.AppGraph
import com.soundq.android.playback.PlaybackRef
import com.soundq.android.playback.nativeengine.OriginalAudioReadLease
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

internal data class OriginalFileStamp(val device:Long,val inode:Long,val bytes:Long,val modified:Long,val modifiedNs:Long?,val changed:Long,val changedNs:Long?) {
    val deletionSafe:Boolean get()=modifiedNs!=null&&changedNs!=null
    companion object {
        fun of(s:StructStat):OriginalFileStamp = if(Build.VERSION.SDK_INT>=27) Api27.stamp(s) else {
            // API26 supports read-only location handoff, not a seconds-only destructive proof.
            @Suppress("DEPRECATION")
            OriginalFileStamp(s.st_dev,s.st_ino,s.st_size,s.st_mtime,null,s.st_ctime,null)
        }
    }
    @androidx.annotation.RequiresApi(27)
    private object Api27 {
        fun stamp(s:StructStat)=OriginalFileStamp(s.st_dev,s.st_ino,s.st_size,s.st_mtim.tv_sec,s.st_mtim.tv_nsec,s.st_ctim.tv_sec,s.st_ctim.tv_nsec)
    }
}
internal data class PhoneFileTarget internal constructor(
    val ref:PlaybackRef.Device,val version:Long,val admission:PhoneSourceAdmission,
    val uri:Uri,val path:String,val stamp:OriginalFileStamp,val providerValues:List<Pair<String,String>>,
    val folder:Uri?,
)
internal enum class FileDeleteOutcome { Deleted, Changed, Missing, Refused, Unconfirmed }

/** Explicit user mutations of originals. Playback cleanup never invokes this owner. */
internal class PhoneFileActions(private val graph:AppGraph) {
    val deleteUnavailableReason:String? get()=if(Build.VERSION.SDK_INT<27)"Delete file needs Android 8.1 or later." else null
    private val resolver=graph.applicationContext.contentResolver
    private val mutation=Mutex()
    private fun current(target:PhoneFileTarget)=graph.phoneAudio.current(target.version)&&graph.session.owns(target.version)
    suspend fun capture(ref:PlaybackRef.Device,valid:()->Boolean):PhoneFileTarget?=withContext(Dispatchers.IO) {
        if(!valid()||!graph.phoneAudio.platform.storageAllowed())return@withContext null
        val row=graph.phoneAudio.observed(ref) ?: return@withContext null
        val admission=graph.phoneAudio.admit(row) ?: return@withContext null
        val uri=Uri.parse(row.aliases.firstOrNull {it.state==com.soundq.android.data.deviceaudio.AccessState.AVAILABLE}?.locator?.value ?: return@withContext null)
        if(uri.authority!=MediaStore.AUTHORITY)return@withContext null
        @Suppress("DEPRECATION") val pathColumn=MediaStore.MediaColumns.DATA
        val columns=mutableListOf(pathColumn,MediaStore.MediaColumns.SIZE,MediaStore.MediaColumns.DATE_MODIFIED)
        if(Build.VERSION.SDK_INT>=30)columns+=listOf(MediaStore.MediaColumns.GENERATION_ADDED,MediaStore.MediaColumns.GENERATION_MODIFIED)
        val facts=resolver.query(uri,columns.toTypedArray(),null,null,null)?.use {c->
            if(c.count!=1||!c.moveToFirst())null else columns.mapIndexed {i,name->name to (c.getString(i) ?: return@use null)}
        } ?: return@withContext null
        val path=facts.first().second
        val file=File(path)
        if(!file.isAbsolute||file.canonicalPath!=path)return@withContext null
        val stamp=OriginalAudioReadLease.open(resolver,uri.toString(),{valid()&&graph.phoneAudio.platform.storageAllowed()&&graph.phoneAudio.current(admission.sessionVersion)&&graph.session.owns(admission.sessionVersion)}).use {original->
            original.stamp.takeIf {original.path==path&&original.offset==0L&&original.length==ref.bytes}
        } ?: return@withContext null
        val parent=file.parentFile ?: return@withContext null
        val root=if(Build.VERSION.SDK_INT>=30)graph.applicationContext.getSystemService(StorageManager::class.java).storageVolumes
            .mapNotNull {v->v.directory?.canonicalFile?.let {Triple(it,if(v.isPrimary)"primary" else v.uuid,v.isPrimary)}}
            .filter {parent.toPath().startsWith(it.first.toPath())}.maxByOrNull {it.first.path.length}?.let {it.first to it.second}
        else Environment.getExternalStorageDirectory().canonicalFile.let {it to "primary"}.takeIf {parent.toPath().startsWith(it.first.toPath())}
        val folder=root?.let {(directory,volume)->volume?.let {DocumentsContract.buildDocumentUri("com.android.externalstorage.documents",it+":"+directory.toPath().relativize(parent.toPath()).toString())}}
        PhoneFileTarget(ref,admission.sessionVersion,admission,uri,path,stamp,facts,folder).takeIf {valid()&&current(it)&&graph.phoneAudio.observed(ref)!=null}
    }
    suspend fun open(target:PhoneFileTarget,valid:()->Boolean):Boolean=withContext(Dispatchers.IO) {
        if(!valid()||!matches(target)||target.folder==null)return@withContext false
        val intent=Intent(Intent.ACTION_VIEW).setDataAndType(target.folder,"vnd.android.document/directory").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        withContext(Dispatchers.Main) {
            if(!valid()||!current(target))false else runCatching {graph.applicationContext.startActivity(intent);true}.getOrDefault(false)
        }
    }
    private fun matches(target:PhoneFileTarget):Boolean=runCatching {
        current(target)&&graph.phoneAudio.platform.storageAllowed()&&
            OriginalFileStamp.of(Os.stat(target.path))==target.stamp&&
            OriginalAudioReadLease.open(resolver,target.uri.toString(),{current(target)&&graph.phoneAudio.platform.storageAllowed()}).use {
                it.path==target.path&&it.offset==0L&&it.length==target.ref.bytes&&it.stamp==target.stamp
            }&&
            resolver.query(target.uri,target.providerValues.map {it.first}.toTypedArray(),null,null,null)?.use {c->
                c.count==1&&c.moveToFirst()&&target.providerValues.withIndex().all {(i,fact)->c.getString(i)==fact.second}
            }==true
    }.getOrDefault(false)

    /** Confirmation capture survives the UI, but cannot retarget a replacement file. */
    suspend fun delete(target:PhoneFileTarget,valid:()->Boolean,retire:suspend ()->Boolean):FileDeleteOutcome=mutation.withLock {
        withContext(Dispatchers.IO) {
            if(deleteUnavailableReason!=null||!target.stamp.deletionSafe)return@withContext FileDeleteOutcome.Refused
            if(!graph.phoneAudio.platform.storageAllowed())return@withContext FileDeleteOutcome.Refused
            if(!valid()||!matches(target))return@withContext FileDeleteOutcome.Changed
            // Delete is deliberate, not startup: retain exact-content checking before destructive IO.
            if(runCatching {graph.phoneAudio.platform.proof(target.uri.toString()) {valid()&&current(target)}}.getOrNull()!=AudioContentProof(target.ref.bytes,target.ref.sha256))return@withContext FileDeleteOutcome.Changed
            val fence=graph.phoneAudio.beginFileMutation(target.ref) ?: return@withContext FileDeleteOutcome.Refused
            try {
                if(!retire()||!valid()||!matches(target))return@withContext FileDeleteOutcome.Refused
                withContext(NonCancellable) {
                    val where=target.providerValues.joinToString(" AND ") {"${it.first}=?"}
                    val count=runCatching {resolver.delete(target.uri,where,target.providerValues.map {it.second}.toTypedArray())}.getOrNull()
                        ?: return@withContext FileDeleteOutcome.Refused
                    if(count!=1)return@withContext FileDeleteOutcome.Changed
                    val absent=runCatching {resolver.query(target.uri,arrayOf(MediaStore.MediaColumns._ID),null,null,null)?.use {!it.moveToFirst()} ?: true}.getOrDefault(false)
                    if(!absent||File(target.path).exists())return@withContext FileDeleteOutcome.Unconfirmed
                    if(graph.phoneAudio.markFileMissing(target.admission,target.uri.toString()))FileDeleteOutcome.Deleted else FileDeleteOutcome.Unconfirmed
                }
            } finally {graph.phoneAudio.endFileMutation(fence)}
        }
    }
}
