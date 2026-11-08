package com.soundq.android.data.offline

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** Explicit device copies, independent of backend import jobs and playback state. */
enum class DownloadStatus { Downloading, Complete, Cancelled, Failed, Interrupted }
data class DeviceDownload(val track:Track,val status:DownloadStatus,val bytes:Long=0,val expected:Long?=null,internal val transferId:String?=null)
data class DownloadsState(val rows:List<DeviceDownload> = emptyList(),val ready:Boolean=false,val rejected:Boolean=false)
class DownloadTicket internal constructor(internal val scope:AccountScope,internal val track:Track,internal val generation:Long) {
    internal val id=UUID.randomUUID().toString()
    internal val started=AtomicBoolean(false)
    @Volatile internal var cancelled=false
    @Volatile internal var call:Call?=null
}
/** Private read handle, never a file URI or a path in a controller snapshot. */
class LocalAudioLease internal constructor(private val file:RandomAccessFile,val size:Long,private val valid:()->Boolean,private val release:()->Unit):AutoCloseable {
    private var closed=false
    @Synchronized fun seek(position:Long) {check(!closed && valid());require(position in 0..size);file.seek(position)}
    @Synchronized fun read(bytes:ByteArray,offset:Int,length:Int):Int {check(!closed && valid());return file.read(bytes,offset,length)}
    @Synchronized override fun close() {if(!closed){closed=true;try {file.close()} finally {release()}}}
}
private data class Artifact(val name:String,val size:Long,val digest:String,val type:String,val etag:String?,val version:String?)
private data class Stored(val row:DeviceDownload,val artifact:Artifact?=null)
private data class OwnedTemp(val file:File,val directoryKey:Any,val fileKey:Any)

/** One bounded scoped index + staged artifacts. No signed URLs or credentials are persisted. */
class DeviceDownloads(private val root:File,private val session:AccountSession,private val api:SoundQApi,client:OkHttpClient) {
    private val http=client.newBuilder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).callTimeout(5,java.util.concurrent.TimeUnit.MINUTES).build()
    private val mutable=MutableStateFlow(DownloadsState())
    val state:StateFlow<DownloadsState> = mutable
    private var owner:AccountScope?=null
    private var generation=0L
    private var directory:File?=null
    private var accepted:ByteArray?=null
    private var writable=false
    private val entries=linkedMapOf<TrackId,Stored>()
    private val flights=mutableMapOf<TrackId,DownloadTicket>()
    private val leases=mutableMapOf<String,Int>()
    private val deferred=mutableMapOf<String,Pair<File,Artifact>>()
    // Test observation at the real post-byte/pre-promotion boundary, not a replacement transfer.
    internal var beforePromotion:(()->Unit)?=null
    internal var onProgress:((Long)->Unit)?=null
    private fun key(scope:AccountScope)=digest((session.endpoint.identity+"\u0000"+scope.accountId).toByteArray())
    private fun same(scope:AccountScope)=owner?.let {it.owner===scope.owner&&it.epoch==scope.epoch}==true
    private fun safeDirectory(file:File) {
        var cursor:File?=file.absoluteFile
        while(cursor!=null){require(!Files.isSymbolicLink(cursor.toPath()));cursor=cursor.parentFile}
        require(!file.exists()||Files.isDirectory(file.toPath(),NOFOLLOW_LINKS))
    }
    private fun index():File=File(directory!!,"index.v1.json")
    private fun bytes(file:File):ByteArray? {
        require(!Files.isSymbolicLink(file.toPath()))
        if(!Files.exists(file.toPath(),NOFOLLOW_LINKS))return null
        require(Files.isRegularFile(file.toPath(),NOFOLLOW_LINKS)&&file.length() in 1..MAX_INDEX)
        return file.readBytes().also {require(it.size.toLong() in 1..MAX_INDEX)}
    }
    private fun unchanged() {
        check(writable);safeDirectory(directory!!)
        val now=bytes(index());check(if(now==null)accepted==null else accepted?.contentEquals(now)==true)
    }
    @Synchronized fun load(scope:AccountScope) {
        if(!session.current(scope))return
        if(same(scope)&&mutable.value.ready&&!mutable.value.rejected) {
            try {
                unchanged()
                entries.toMap().forEach {(id,entry)->entry.artifact?.let {a ->
                    if(!validArtifact(directory!!,a))entries[id]=Stored(entry.row.copy(status=DownloadStatus.Failed))
                }}
                publish()
            }catch(_:Exception){writable=false;publish()}
            return
        }
        retire();owner=scope
        directory=File(root,key(scope))
        try {
            safeDirectory(root);safeDirectory(directory!!)
            accepted=bytes(index())
            if(accepted==null)require(directory!!.listFiles().isNullOrEmpty())
            else decode(accepted!!,scope).forEach {entries[it.row.track.id]=it}
            writable=true;publish()
        } catch(_:Exception) {writable=false;entries.clear();mutable.value=DownloadsState(ready=true,rejected=true)}
    }
    @Synchronized fun retire() {
        generation++;flights.values.forEach {it.cancelled=true;it.call?.cancel()};flights.clear()
        owner=null;directory=null;accepted=null;writable=false;entries.clear();mutable.value=DownloadsState()
    }
    private fun publish() {mutable.value=DownloadsState(entries.values.map {it.row},ready=true,rejected=!writable)}
    private fun persist() {
        unchanged()
        require(entries.size<=MAX_ROWS)
        val scope=owner!!;session.checkScope(scope)
        val body=buildJsonObject {
            put("version",1);put("scope",key(scope));put("rows",buildJsonArray {
                entries.values.forEach {entry -> add(buildJsonObject {
                    val r=entry.row;put("id",r.track.id.value);put("title",r.track.title);put("artist",r.track.artist);put("album",r.track.album);put("duration",r.track.durationMs)
                    put("status",r.status.name);put("bytes",r.bytes);r.expected?.let {put("expected",it)}
                    entry.artifact?.let {a -> put("artifact",buildJsonObject {
                        put("name",a.name);put("size",a.size);put("sha256",a.digest);put("type",a.type);a.etag?.let {put("etag",it)};a.version?.let {put("storageVersion",it)}
                    })}
                })}
            })
        }.toString().toByteArray()
        require(body.size<=MAX_INDEX)
        directory!!.mkdirs();safeDirectory(directory!!)
        val temp=createOwnedTemp(directory!!,"index-",".new")
        try {FileOutputStream(temp.file).use {it.write(body);it.fd.sync()};unchanged();session.checkScope(scope);check(ownsTemp(temp))
            Files.move(temp.file.toPath(),index().toPath(),ATOMIC_MOVE,REPLACE_EXISTING);accepted=body
        } finally {cleanupOwnedTemp(temp)}
    }
    private fun decode(data:ByteArray,scope:AccountScope):List<Stored> {
        val b=Json.parseToJsonElement(data.toString(Charsets.UTF_8)).jsonObject
        require(b.keys==setOf("version","scope","rows")&&number(b,"version")==1L&&text(b,"scope")==key(scope))
        val rows=b.getValue("rows").jsonArray;require(rows.size<=MAX_ROWS)
        val result=rows.map {element ->
            val r=element.jsonObject
            require(r.keys.all {it in setOf("id","title","artist","album","duration","status","bytes","expected","artifact")})
            val track=Track(TrackId(number(r,"id")),text(r,"title"),text(r,"artist"),text(r,"album"),number(r,"duration").also {require(it>=0)})
            val status=DownloadStatus.valueOf(text(r,"status"));val count=number(r,"bytes").also {require(it>=0)}
            val expected=r["expected"]?.let {number(r,"expected").also {require(it in 1..MAX_AUDIO)}}
            val artifact=r["artifact"]?.jsonObject?.let {a ->
                require(a.keys.all {it in setOf("name","size","sha256","type","etag","storageVersion")})
                Artifact(text(a,"name").also {require(NAME.matches(it))},number(a,"size").also {require(it in 1..MAX_AUDIO)},text(a,"sha256").also {require(Regex("[0-9a-f]{64}").matches(it))},text(a,"type"),a["etag"]?.let {text(a,"etag")},a["storageVersion"]?.let {text(a,"storageVersion")})
            }
            require((status==DownloadStatus.Complete)==(artifact!=null))
            if(artifact!=null)require(count==artifact.size&&(expected==null||expected==artifact.size))
            val available=artifact==null||validArtifact(directory!!,artifact)
            Stored(DeviceDownload(track,if(status==DownloadStatus.Downloading)DownloadStatus.Interrupted else if(!available)DownloadStatus.Failed else status,count,expected),if(available)artifact else null)
        }
        require(result.map {it.row.track.id}.distinct().size==result.size)
        require(result.mapNotNull {it.artifact?.name}.distinct().size==result.count {it.artifact!=null})
        return result
    }
    @Synchronized fun claim(scope:AccountScope,track:Track,valid:()->Boolean):DownloadTicket? {
        if(!session.remoteCurrent(scope)||!same(scope)||!writable||!valid())return null
        flights[track.id]?.let {return it}
        if(entries[track.id]?.row?.status==DownloadStatus.Complete)return null
        if(track.title.length>4096||track.artist.length>4096||track.album.length>4096||track.durationMs<0)return null
        return try {
            unchanged();val ticket=DownloadTicket(scope,track,generation)
            entries[track.id]=Stored(DeviceDownload(track,DownloadStatus.Downloading,transferId=ticket.id));persist();flights[track.id]=ticket;publish();ticket
        } catch(_:Exception){writable=false;publish();null}
    }
    private fun current(t:DownloadTicket)=session.current(t.scope)&&same(t.scope)&&generation==t.generation&&flights[t.track.id]===t&&!t.cancelled&&writable
    private fun check(t:DownloadTicket) {synchronized(this){check(current(t))}}
    fun transfer(ticket:DownloadTicket) {
        if(!ticket.started.compareAndSet(false,true))return
        var stage:OwnedTemp?=null;var promoted:OwnedTemp?=null;var receipt:OwnedTemp?=null
        try {
            check(ticket)
            val descriptor=api.descriptor(ticket.scope,ticket.track.id){synchronized(this){current(ticket)}}
            val expected=descriptor.sizeBytes ?: error("missing size")
            require(expected in 1..MAX_AUDIO && descriptor.contentType in TYPES && descriptor.expires.isAfter(Instant.now()))
            val dir=synchronized(this){check(current(ticket));unchanged();directory!!.also {it.mkdirs();safeDirectory(it)}}
            stage=createOwnedTemp(dir,"transfer-",".part")
            val media=http.newBuilder().addNetworkInterceptor {chain ->
                check(ticket);require(chain.request().header("Authorization")==null);chain.proceed(chain.request())
            }.build()
            val call=media.newCall(Request.Builder().url(descriptor.url).build());ticket.call=call;check(ticket)
            var total=0L
            call.execute().use {response ->
                require(response.code==200)
                val length=response.body.contentLength();require(length==-1L||length==expected)
                FileOutputStream(stage.file).use {out ->
                    val input=response.body.byteStream();val buffer=ByteArray(32*1024)
                    while(true){check(ticket);val n=input.read(buffer);if(n<0)break;total+=n;require(total<=expected);out.write(buffer,0,n)
                        synchronized(this){check(current(ticket));entries[ticket.track.id]=Stored(DeviceDownload(ticket.track,DownloadStatus.Downloading,total,expected,ticket.id));publish()}
                        onProgress?.invoke(total)
                    }
                    out.fd.sync()
                }
            }
            require(total==expected&&stage.file.length()==expected)
            beforePromotion?.invoke();check(ticket)
            check(ownsTemp(stage))
            val a=Artifact(UUID.randomUUID().toString()+".audio",total,hashFile(stage.file),descriptor.contentType!!,descriptor.etag,descriptor.storageKeyVersion)
            synchronized(this) {
                check(current(ticket));unchanged();check(ownsTemp(stage))
                val destination=File(dir,a.name);require(!Files.exists(destination.toPath(),NOFOLLOW_LINKS))
                val ownership=File(dir,a.name+".owner")
                require(!Files.exists(ownership.toPath(),NOFOLLOW_LINKS))
                val receiptStage=createOwnedTemp(dir,"ownership-",".new")
                try {
                    FileOutputStream(receiptStage.file).use {it.write(ownershipBytes(dir,a));it.fd.sync()}
                    check(ownsTemp(receiptStage))
                    Files.move(receiptStage.file.toPath(),ownership.toPath(),ATOMIC_MOVE);receipt=receiptStage.copy(file=ownership)
                } finally {cleanupOwnedTemp(receiptStage)}
                check(ownsTemp(stage))
                Files.move(stage.file.toPath(),destination.toPath(),ATOMIC_MOVE);promoted=stage.copy(file=destination)
                entries[ticket.track.id]=Stored(DeviceDownload(ticket.track,DownloadStatus.Complete,total,expected),a)
                persist();flights.remove(ticket.track.id);publish();promoted=null;receipt=null
            }
        } catch(_:Exception) {
            synchronized(this) {
                if(current(ticket)){
                    entries[ticket.track.id]=Stored(entries[ticket.track.id]!!.row.copy(status=DownloadStatus.Failed))
                    try {persist()}catch(_:Exception){writable=false}
                    flights.remove(ticket.track.id);publish()
                }
            }
        } finally {ticket.call=null;stage?.let(::cleanupOwnedTemp);promoted?.let(::cleanupOwnedTemp);receipt?.let(::cleanupOwnedTemp)}
    }
    @Synchronized fun cancel(scope:AccountScope,row:DeviceDownload):Boolean {
        if(!session.current(scope)||!same(scope))return false
        val t=flights[row.track.id] ?: return false
        if(row.transferId!=t.id)return false
        flights.remove(row.track.id);t.cancelled=true;t.call?.cancel()
        entries[row.track.id]=Stored(entries[row.track.id]!!.row.copy(status=DownloadStatus.Cancelled,transferId=null))
        try {persist()}catch(_:Exception){writable=false};publish();return true
    }
    /** Cheap exact-row admission. Does not read or hash audio during composition/gestures. */
    @Synchronized fun ownsComplete(scope:AccountScope,row:DeviceDownload):Boolean =
        session.current(scope)&&same(scope)&&writable&&row.status==DownloadStatus.Complete&&entries[row.track.id]?.row===row&&entries[row.track.id]?.artifact!=null
    /** Off-main admission only. No playback lease is retained for a queued occurrence. */
    @Synchronized fun validateComplete(scope:AccountScope,row:DeviceDownload):Boolean {
        if(!ownsComplete(scope,row))return false
        return try {
            unchanged()
            validArtifact(directory!!,entries[row.track.id]!!.artifact!!)&&ownsComplete(scope,row)
        }catch(_:Exception){false}
    }
    @Synchronized fun acquire(scope:AccountScope,track:TrackId):LocalAudioLease? {
        if(!session.current(scope)||!same(scope)||!writable)return null
        return try {
            unchanged();val a=entries[track]?.artifact ?: return null;val dir=directory!!
            if(!validArtifact(dir,a))return null
            val file=RandomAccessFile(File(dir,a.name),"r");val leaseKey=dir.name+"/"+a.name
            leases[leaseKey]=(leases[leaseKey] ?: 0)+1
            LocalAudioLease(file,a.size,{session.current(scope)}) {synchronized(this){
                val count=(leases[leaseKey] ?: 1)-1
                if(count==0){leases.remove(leaseKey);deferred.remove(leaseKey)?.let {(d,artifact)->deleteOwned(d,artifact)}}else leases[leaseKey]=count
            }}
        } catch(_:Exception){null}
    }
    /** Caller must capture the exact displayed rows before opening confirmation. */
    @Synchronized fun remove(scope:AccountScope,rows:List<DeviceDownload>):Boolean {
        if(!session.current(scope)||!same(scope)||!writable||rows.isEmpty()||rows.any {entries[it.track.id]?.row!==it||it.status==DownloadStatus.Downloading})return false
        return try {
            unchanged();val dir=directory!!;val removed=rows.mapNotNull {entries[it.track.id]?.artifact}
            val before=entries.toMap();rows.forEach {entries.remove(it.track.id)}
            try {persist()}catch(e:Exception){entries.clear();entries.putAll(before);throw e}
            removed.forEach {a -> val k=dir.name+"/"+a.name;if((leases[k] ?: 0)>0)deferred[k]=dir to a else deleteOwned(dir,a)}
            publish();true
        }catch(_:Exception){writable=false;publish();false}
    }
    private fun createOwnedTemp(dir:File,prefix:String,suffix:String):OwnedTemp {
        safeDirectory(dir)
        val directoryKey=fileIdentity(dir,true)
        val file=Files.createTempFile(dir.toPath(),prefix,suffix).toFile()
        return OwnedTemp(file,directoryKey,fileIdentity(file,false)).also {check(ownsTemp(it))}
    }
    private fun fileIdentity(file:File,directory:Boolean):Any {
        val attributes=Files.readAttributes(file.toPath(),BasicFileAttributes::class.java,NOFOLLOW_LINKS)
        require(if(directory)attributes.isDirectory else attributes.isRegularFile)
        return requireNotNull(attributes.fileKey())
    }
    private fun ownsTemp(temp:OwnedTemp):Boolean=try {
        val dir=temp.file.parentFile!!
        safeDirectory(dir)
        fileIdentity(dir,true)==temp.directoryKey && fileIdentity(temp.file,false)==temp.fileKey
    }catch(_:Exception){false}
    private fun cleanupOwnedTemp(temp:OwnedTemp) {
        try {if(ownsTemp(temp))temp.file.delete()}catch(_:Exception){/* Preserve bytes when custody or deletion is unavailable. */}
    }
    private fun ownershipBytes(dir:File,a:Artifact)=("soundq-device-artifact-v1\n"+dir.name+"\n"+a.name+"\n"+a.size+"\n"+a.digest).toByteArray()
    private fun deleteOwned(dir:File,a:Artifact){if(validArtifact(dir,a)&&File(dir,a.name).delete())File(dir,a.name+".owner").delete()}
    private fun validArtifact(dir:File,a:Artifact):Boolean=try {
        safeDirectory(dir);val f=File(dir,a.name)
        val receipt=File(dir,a.name+".owner")
        NAME.matches(a.name)&&Files.isRegularFile(receipt.toPath(),NOFOLLOW_LINKS)&&receipt.length()<512&&receipt.readBytes().contentEquals(ownershipBytes(dir,a))&&Files.isRegularFile(f.toPath(),NOFOLLOW_LINKS)&&f.length()==a.size&&hashFile(f)==a.digest
    }catch(_:Exception){false}
    companion object {
        private const val MAX_INDEX=2_000_000L
        private const val MAX_AUDIO=2_147_483_648L
        private const val MAX_ROWS=1000
        private val NAME=Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.audio")
        private val TYPES=setOf("audio/mpeg","audio/mp4","audio/aac","audio/ogg","audio/opus","audio/flac","audio/wav","audio/x-wav","audio/webm","video/webm")
        private fun digest(data:ByteArray)=MessageDigest.getInstance("SHA-256").digest(data).joinToString(""){"%02x".format(it)}
        private fun hashFile(file:File):String {val d=MessageDigest.getInstance("SHA-256");file.inputStream().use {input ->val b=ByteArray(64*1024);while(true){val n=input.read(b);if(n<0)break;d.update(b,0,n)}};return d.digest().joinToString(""){"%02x".format(it)}}
        private fun text(o:JsonObject,k:String):String=o.getValue(k).jsonPrimitive.let {require(it.isString&&it.content.length<=4096);it.content}
        private fun number(o:JsonObject,k:String):Long=o.getValue(k).jsonPrimitive.let {require(!it.isString);it.long}
    }
}
