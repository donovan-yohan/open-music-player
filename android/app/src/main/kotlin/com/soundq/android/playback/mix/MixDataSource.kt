package com.soundq.android.playback.mix

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.*
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.mix.SavedMix
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap

internal class MixGrant(val scope:AccountScope,val plan:SavedMix,internal val prepared:PreparedMix?=null):AutoCloseable {
    override fun close(){prepared?.close()}
}
/** Existing loader preparation, performed off the player looper before PLAY_MIX installation.
 * The grant retains the exact leases/private copies/compiled stream for loader reuse and seeks.
 */
internal class PreparedMix private constructor(private val session:AccountSession,private val downloads:com.soundq.android.data.offline.DeviceDownloads,private val scope:AccountScope):AutoCloseable {
    private val files=mutableListOf<File>()
    private val leases=mutableListOf<com.soundq.android.data.offline.LocalAudioLease>()
    private val rows=mutableListOf<com.soundq.android.data.offline.DeviceDownload>()
    private var stems:StemPreparation?=null
    private var stream:NativeMixStream?=null
    private var closed=false
    @Synchronized fun admits():Boolean=!closed && session.current(scope) && downloads.state.value.ready && !downloads.state.value.rejected && rows.all {row->downloads.state.value.rows.any {it===row}}
    @Synchronized fun size():Long {check(!closed);return stream!!.size}
    @Synchronized fun read(position:Long,buffer:ByteArray,offset:Int,length:Int):Int {check(!closed);session.checkScope(scope);return stream!!.read(position,buffer,offset,length)}
    @Synchronized override fun close(){if(closed)return;closed=true;try {stream?.close()}finally {stream=null;stems?.close();stems=null;leases.forEach {it.close()};leases.clear();files.forEach {it.delete()};files.clear();rows.clear()}}
    companion object {
        fun prepare(directory:File,session:AccountSession,downloads:com.soundq.android.data.offline.DeviceDownloads,api:SoundQApi,scope:AccountScope,client:okhttp3.OkHttpClient,plan:SavedMix,current:()->Boolean):PreparedMix {
            val prepared=PreparedMix(session,downloads,scope)
            fun checkCurrent(){check(current());session.checkScope(scope)}
            try {
                checkCurrent();require(plan.playable());downloads.load(scope)
                var encoded=0L
                fun reserve(bytes:Long){encoded=Math.addExact(encoded,bytes);require(encoded<=128L*1024*1024)}
                val paths=plan.clips.filter {it.stems==null}.map {it.track}.distinct().associateWith {id->
                    checkCurrent()
                    val row=downloads.state.value.rows.singleOrNull {it.track.id==TrackId(id)} ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
                    val lease=downloads.acquire(scope,TrackId(id)) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
                    prepared.rows+=row;prepared.leases+=lease;reserve(lease.size)
                    val file=Files.createTempFile(directory.toPath(),"mix-",".opus").toFile();prepared.files+=file
                    file.outputStream().use {output->
                        val bytes=ByteArray(64*1024);var copied=0L
                        while(copied<lease.size){checkCurrent();val n=lease.read(bytes,0,minOf(bytes.size.toLong(),lease.size-copied).toInt());check(n>0);output.write(bytes,0,n);copied+=n}
                    }
                    file.absolutePath
                }
                checkCurrent()
                prepared.stems=StemPreparation(directory,api,scope,client,{runCatching {checkCurrent();true}.getOrDefault(false)},::reserve)
                val stems=prepared.stems!!.prepare(plan)
                checkCurrent();prepared.stream=NativeMixStream(plan,paths,stems)
                checkCurrent();check(prepared.admits());return prepared
            }catch(error:Throwable){prepared.close();throw error}
        }
    }
}
/** Decode and compile only on the existing Exo loader. No second output/callback. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class MixDataSource(private val graph:AppGraph,private val grants:ConcurrentHashMap<String,MixGrant>):DataSource {
    private var uri:Uri?=null
    private var grant:MixGrant?=null
    private var stream:NativeMixStream?=null
    private var stemPreparation:StemPreparation?=null
    private val files=mutableListOf<File>()
    private val leases=mutableListOf<com.soundq.android.data.offline.LocalAudioLease>()
    private var position=0L
    private var remaining=0L
    private var prepared:PreparedMix?=null
    override fun addTransferListener(listener:TransferListener) {}
    private fun checkCurrent() {val p=grant ?: throw SafeFailure(SafeFailure.Reason.Retired);graph.session.checkScope(p.scope);if(grants[uri.toString()]!==p)throw SafeFailure(SafeFailure.Reason.Retired)}
    override fun open(dataSpec:DataSpec):Long {
        require(dataSpec.uri.scheme=="soundqmix")
        uri=dataSpec.uri;grant=grants[uri.toString()] ?: throw SafeFailure(SafeFailure.Reason.Retired)
        try {
            checkCurrent();val g=grant!!;require(g.plan.playable())
            g.prepared?.let {ready->
                prepared=ready;position=dataSpec.position;require(position<=ready.size())
                remaining=if(dataSpec.length==C.LENGTH_UNSET.toLong())ready.size()-position else minOf(dataSpec.length,ready.size()-position)
                checkCurrent();return remaining
            }
            graph.downloads.load(g.scope)
            var encoded=0L
            val paths=g.plan.clips.filter {it.stems==null}.map {it.track}.distinct().associateWith {id ->
                checkCurrent()
                val lease=graph.downloads.acquire(g.scope,TrackId(id)) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
                leases+=lease;encoded=Math.addExact(encoded,lease.size);require(encoded<=128L*1024*1024)
                // Private exclusive copy avoids exposing/moving the download owner's live path.
                val f=Files.createTempFile(graph.directory.toPath(),"mix-",".opus").toFile();files+=f
                f.outputStream().use {output ->
                    val bytes=ByteArray(64*1024);var copied=0L
                    while(copied<lease.size) {checkCurrent();val n=lease.read(bytes,0,minOf(bytes.size.toLong(),lease.size-copied).toInt());check(n>0);output.write(bytes,0,n);copied+=n}
                }
                f.absolutePath
            }
            checkCurrent()
            stemPreparation=StemPreparation(graph.directory,graph.api,g.scope,graph.mediaClient,{runCatching {checkCurrent();true}.getOrDefault(false)}) {bytes->encoded=Math.addExact(encoded,bytes);require(encoded<=128L*1024*1024)}
            val prepared=stemPreparation!!.prepare(g.plan)
            checkCurrent();stream=NativeMixStream(g.plan,paths,prepared);checkCurrent()
            position=dataSpec.position;require(position<=stream!!.size)
            remaining=if(dataSpec.length==C.LENGTH_UNSET.toLong())stream!!.size-position else minOf(dataSpec.length,stream!!.size-position)
            return remaining
        }catch(_:Throwable){close();throw SafeFailure(SafeFailure.Reason.AudioUnavailable)}
    }
    override fun read(buffer:ByteArray,offset:Int,length:Int):Int {
        checkCurrent();if(length==0)return 0;if(remaining==0L)return C.RESULT_END_OF_INPUT
        val n=try {prepared?.read(position,buffer,offset,minOf(length.toLong(),remaining).toInt()) ?: stream!!.read(position,buffer,offset,minOf(length.toLong(),remaining).toInt())}catch(_:Throwable){throw SafeFailure(SafeFailure.Reason.AudioUnavailable)}
        checkCurrent();if(n>0){position+=n;remaining-=n};return n
    }
    override fun getUri()=uri
    override fun close(){try {stream?.close()}finally {stream=null;stemPreparation?.close();stemPreparation=null;leases.forEach {it.close()};leases.clear();files.forEach {it.delete()};files.clear();prepared=null;uri=null;grant=null}}
}
