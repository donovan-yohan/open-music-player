package com.soundq.android.data.cache

import com.soundq.android.data.*
import com.soundq.android.data.offline.LocalAudioLease
import java.io.*
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import kotlinx.serialization.json.*

data class CacheStatus(val bytes:Long?,val files:Int,val deferredFiles:Int,val failedFiles:Int,val writingFiles:Int)
data class CacheClearResult(val removedFiles:Int,val deferredFiles:Int,val failedFiles:Int)
class CacheClearCapture internal constructor(internal val owner:TemporaryAudioCache,internal val names:Set<String>,internal val stages:Set<TemporaryAudioCache.Write>)
internal data class OwnedFile(val file:File,val directoryKey:String,val fileKey:String)
private data class Entry(val scope:String,val track:Long,val owned:OwnedFile,val receipt:OwnedFile,val size:Long,val hash:String,var retired:Boolean=false,var leases:Int=0)

/** Only this cache's positively owned files. Explicit downloads and artwork are never enumerated. */
class TemporaryAudioCache(private val root:File,private val session:AccountSession) {
    private val index=File(root,"temporary-audio.v1.json")
    private val entries=linkedMapOf<String,Entry>()
    private val stages=mutableSetOf<Write>()
    private var accepted:ByteArray?=null
    private var writable=true
    init {
        try {
            safeDirectory(root)
            if(index.exists()) {
                require(Files.isRegularFile(index.toPath(),NOFOLLOW_LINKS)&&index.length() in 1..MAX_INDEX)
                val raw=index.readBytes();val body=Json.parseToJsonElement(raw.toString(Charsets.UTF_8)).jsonObject
                require(body.keys==setOf("version","entries")&&body.getValue("version").jsonPrimitive.int==1)
                val rows=body.getValue("entries").jsonArray;require(rows.size<=256)
                rows.forEach {item -> val o=item.jsonObject
                    require(o.keys==setOf("name","scope","track","directoryKey","fileKey","receiptKey","size","hash","retired"))
                    val name=o.getValue("name").jsonPrimitive.content;require(NAME.matches(name))
                    val e=Entry(o.getValue("scope").jsonPrimitive.content,o.getValue("track").jsonPrimitive.long,
                        OwnedFile(File(root,name),o.getValue("directoryKey").jsonPrimitive.content,o.getValue("fileKey").jsonPrimitive.content),
                        OwnedFile(File(root,name+".owner"),o.getValue("directoryKey").jsonPrimitive.content,o.getValue("receiptKey").jsonPrimitive.content),
                        o.getValue("size").jsonPrimitive.long,o.getValue("hash").jsonPrimitive.content,o.getValue("retired").jsonPrimitive.boolean)
                    require(e.size in 1..MAX_AUDIO&&e.track>0&&Regex("[0-9a-f]{64}").matches(e.scope)&&Regex("[0-9a-f]{64}").matches(e.hash)&&valid(e))
                    require(entries.put(name,e)==null)
                }
                accepted=raw
            }
        }catch(_:Exception){entries.clear();writable=false}
    }
    private fun scope(s:AccountScope)=digest((session.endpoint.identity+"\u0000"+s.accountId).toByteArray())
    private fun safeDirectory(dir:File) {
        var p:File?=dir.absoluteFile
        while(p!=null){require(!Files.isSymbolicLink(p.toPath()));p=p.parentFile}
        require(!dir.exists()||Files.isDirectory(dir.toPath(),NOFOLLOW_LINKS))
    }
    private fun identity(file:File,directory:Boolean):String {
        val a=Files.readAttributes(file.toPath(),BasicFileAttributes::class.java,NOFOLLOW_LINKS)
        require(if(directory)a.isDirectory else a.isRegularFile)
        return requireNotNull(a.fileKey()).toString()
    }
    private fun owns(o:OwnedFile)=try {safeDirectory(root);identity(root,true)==o.directoryKey&&identity(o.file,false)==o.fileKey}catch(_:Exception){false}
    private fun receiptBytes(e:Entry)=("soundq-temporary-artifact-v1\n"+e.scope+"\n"+e.track+"\n"+e.owned.file.name+"\n"+e.owned.directoryKey+"\n"+e.owned.fileKey+"\n"+e.size+"\n"+e.hash).toByteArray()
    private fun valid(e:Entry)=try {owns(e.owned)&&owns(e.receipt)&&e.receipt.file.length() in 1..2048&&e.receipt.file.readBytes().contentEquals(receiptBytes(e))&&e.owned.file.length()==e.size&&hash(e.owned.file)==e.hash}catch(_:Exception){false}
    private fun deleteEntry(e:Entry):Boolean {
        if(!valid(e)||!delete(e.owned))return false
        return delete(e.receipt)
    }
    private fun delete(o:OwnedFile):Boolean=try {owns(o)&&o.file.delete()}catch(_:Exception){false}
    private fun unchanged() {
        check(writable);safeDirectory(root);require(!Files.isSymbolicLink(index.toPath()))
        val now=if(index.exists()){require(index.length() in 1..MAX_INDEX);index.readBytes()}else null
        check(if(now==null)accepted==null else accepted?.contentEquals(now)==true)
    }
    private fun persist() {
        unchanged();root.mkdirs();safeDirectory(root)
        val raw=buildJsonObject {put("version",1);put("entries",buildJsonArray {entries.forEach {(name,e)->add(buildJsonObject {
            put("name",name);put("scope",e.scope);put("track",e.track);put("directoryKey",e.owned.directoryKey);put("fileKey",e.owned.fileKey);put("receiptKey",e.receipt.fileKey);put("size",e.size);put("hash",e.hash);put("retired",e.retired)
        })}})}.toString().toByteArray();require(raw.size<=MAX_INDEX)
        val temp=Files.createTempFile(root.toPath(),"cache-index-",".new").toFile()
        val owned=OwnedFile(temp,identity(root,true),identity(temp,false))
        try {FileOutputStream(temp).use {it.write(raw);it.fd.sync()};unchanged();check(owns(owned));Files.move(temp.toPath(),index.toPath(),ATOMIC_MOVE,REPLACE_EXISTING);accepted=raw}finally {delete(owned)}
    }
    @Synchronized fun status():CacheStatus {
        return try {
            unchanged()
            val failed=entries.values.count {!valid(it)}
            // Unknown files are retained and make complete byte accounting unavailable, never zero.
            val known=entries.keys+entries.values.map {it.receipt.file.name}+stages.map {it.owned.file.name}+index.name
            val unknown=root.listFiles()?.any {it.name !in known}==true
            CacheStatus(if(failed==0&&!unknown)entries.values.sumOf {it.size}+stages.sumOf {it.count} else null,entries.size,entries.values.count {it.retired&&it.leases>0},failed,stages.size)
        }catch(_:Exception){CacheStatus(null,entries.size,entries.values.count {it.retired&&it.leases>0},1,stages.size)}
    }
    @Synchronized fun begin(s:AccountScope,track:TrackId,size:Long):Write? {
        if(!session.remoteCurrent(s)||size !in 1..MAX_AUDIO||!writable||entries.size>=256||entries.values.sumOf {it.size}+stages.sumOf {it.expected}+size>MAX_TOTAL)return null
        return try {
            unchanged();root.mkdirs();safeDirectory(root)
            val file=Files.createTempFile(root.toPath(),"audio-",".part").toFile()
            Write(s,track,size,OwnedFile(file,identity(root,true),identity(file,false))).also {stages.add(it)}
        }catch(_:Exception){null}
    }
    inner class Write internal constructor(private val account:AccountScope,private val track:TrackId,internal val expected:Long,internal val owned:OwnedFile):AutoCloseable {
        internal var count=0L
        private var done=false
        internal var promotedName:String?=null
        fun append(bytes:ByteArray,offset:Int,length:Int) = synchronized(this@TemporaryAudioCache) {
            check(!done&&session.current(account)&&owns(owned));require(length>=0&&count+length<=expected)
            FileOutputStream(owned.file,true).use {it.write(bytes,offset,length)};count+=length
        }
        fun finish():Boolean = synchronized(this@TemporaryAudioCache) {
            if(done)return false
            done=true;stages.remove(this)
            var promoted:OwnedFile?=null
            var receipt:OwnedFile?=null
            try {
                check(session.current(account)&&count==expected&&owns(owned)&&owned.file.length()==expected)
                unchanged();val file=File(root,java.util.UUID.randomUUID().toString()+".audio")
                Files.move(owned.file.toPath(),file.toPath(),ATOMIC_MOVE);promoted=owned.copy(file=file)
                val receiptFile=File(root,file.name+".owner")
                check(receiptFile.createNewFile())
                receipt=OwnedFile(receiptFile,identity(root,true),identity(receiptFile,false))
                val e=Entry(scope(account),track.value,promoted,receipt,expected,hash(file))
                FileOutputStream(receiptFile).use {it.write(receiptBytes(e));it.fd.sync()}
                check(valid(e))
                entries[file.name]=e
                try {persist()}catch(error:Exception){entries.remove(file.name);throw error}
                promotedName=file.name;promoted=null;receipt=null;true
            }catch(_:Exception){false}finally {delete(owned);promoted?.let {delete(it)};receipt?.let {delete(it)}}
        }
        override fun close() = synchronized(this@TemporaryAudioCache) {if(!done){done=true;stages.remove(this);delete(owned)};Unit}
    }
    @Synchronized fun acquire(s:AccountScope,track:TrackId):LocalAudioLease? {
        if(!session.current(s))return null
        return try {
            unchanged();val e=entries.values.lastOrNull {it.scope==scope(s)&&it.track==track.value&&!it.retired} ?: return null
            if(!valid(e))return null
            val handle=RandomAccessFile(e.owned.file,"r");e.leases++
            LocalAudioLease(handle,e.size,{session.current(s)}) {synchronized(this){
                e.leases--
                if(e.retired&&e.leases==0) {try {unchanged();if(deleteEntry(e)){entries.remove(e.owned.file.name);persist()}}catch(_:Exception){writable=false}}
            }}
        }catch(_:Exception){null}
    }
    /** Accepted clear retires discovery immediately. Actual leased bytes stay represented until close. */
    @Synchronized fun captureClear()=CacheClearCapture(this,entries.keys.toSet(),stages.toSet())
    @Synchronized fun clear(capture:CacheClearCapture=captureClear()):CacheClearResult {
        if(capture.owner!==this)return CacheClearResult(0,0,1)
        capture.stages.forEach {it.close()}
        var removed=0;var deferred=0;var failed=0
        try {
            unchanged();val targets=(capture.names+capture.stages.mapNotNull {it.promotedName}).mapNotNull(entries::get);targets.forEach {it.retired=true};persist()
            targets.forEach {e ->
                if(e.leases>0)deferred++ else if(deleteEntry(e)){entries.remove(e.owned.file.name);removed++}else failed++
            }
            persist()
        }catch(_:Exception){writable=false;failed++}
        return CacheClearResult(removed,deferred,failed)
    }
    companion object {
        private const val MAX_AUDIO=128L*1024*1024
        private const val MAX_TOTAL=512L*1024*1024
        private const val MAX_INDEX=256L*1024
        private val NAME=Regex("[0-9a-f-]{36}\\.audio")
        private fun digest(bytes:ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(""){"%02x".format(it)}
        private fun hash(file:File):String {val d=MessageDigest.getInstance("SHA-256");file.inputStream().use {input->val b=ByteArray(32768);while(true){val n=input.read(b);if(n<0)break;d.update(b,0,n)}};return d.digest().joinToString(""){"%02x".format(it)}}
    }
}
