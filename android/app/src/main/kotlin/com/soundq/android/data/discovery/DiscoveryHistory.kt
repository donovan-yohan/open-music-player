package com.soundq.android.data.discovery

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import java.security.MessageDigest
import kotlinx.serialization.json.*

/** Optional local history, never source consent. Rejected bytes are not overwritten. */
internal class DiscoveryHistory(private val directory:File?) {
    private var memoryOwner:Pair<String,String>?=null
    private var memory=emptyList<String>()
    private fun file(endpoint:String,account:String):File? {
        val key=buildJsonArray {add(endpoint);add(account)}.toString().toByteArray()
        val name=MessageDigest.getInstance("SHA-256").digest(key).joinToString("") {"%02x".format(it)}
        return directory?.let {File(it,"$name.json")}
    }
    private fun read(file:File?):Pair<ByteArray?,List<String>> {
        if(file==null)return null to memory
        require(!Files.isSymbolicLink(file.toPath()))
        if(!Files.exists(file.toPath(),NOFOLLOW_LINKS))return null to emptyList()
        require(Files.isRegularFile(file.toPath(),NOFOLLOW_LINKS)&&file.length() in 1..16384)
        val raw=file.readBytes();require(raw.size in 1..16384)
        val body=Json.parseToJsonElement(raw.decodeToString(throwOnInvalidSequence=true)).jsonObject
        require(body.keys==setOf("version","queries"))
        body.getValue("version").jsonPrimitive.let {require(!it.isString&&it.int==1)}
        val rows=body.getValue("queries").jsonArray.map {it.jsonPrimitive.let {p->require(p.isString);p.content.also {q->require(q.isNotBlank()&&q==q.trim()&&q.toByteArray().size<=512)}}}
        require(rows.size<=20&&rows.map {it.lowercase(java.util.Locale.ROOT)}.distinct().size==rows.size)
        return raw to rows
    }
    private fun owner(endpoint:String,account:String) {
        if(memoryOwner!=(endpoint to account)){memoryOwner=endpoint to account;memory=emptyList()}
    }
    @Synchronized fun load(endpoint:String,account:String):List<String> {
        owner(endpoint,account)
        return runCatching {read(file(endpoint,account)).second}.getOrDefault(emptyList())
    }
    @Synchronized fun add(endpoint:String,account:String,query:String):List<String> = change(endpoint,account) {rows->
        val q=query.trim();require(q.isNotEmpty()&&q.toByteArray().size<=512)
        (listOf(q)+rows.filterNot {it.equals(q,ignoreCase=true)}).take(20)
    }
    @Synchronized fun clear(endpoint:String,account:String):List<String> = change(endpoint,account){emptyList()}
    private fun change(endpoint:String,account:String,transform:(List<String>)->List<String>):List<String> {
        owner(endpoint,account)
        return try {
            val file=file(endpoint,account);val (accepted,rows)=read(file);val next=transform(rows)
            if(file!=null) {
                val raw=buildJsonObject {put("version",1);put("queries",buildJsonArray {next.forEach {add(it)}})}.toString().toByteArray()
                require(raw.size<=16384);requireNotNull(file.parentFile).mkdirs()
                val temp=Files.createTempFile(file.parentFile.toPath(),"discover-history-",".new")
                try {
                    FileOutputStream(temp.toFile()).use {it.write(raw);it.fd.sync()}
                    val current=read(file).first
                    check(if(accepted==null)current==null else current?.contentEquals(accepted)==true)
                    Files.move(temp,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
                } finally {Files.deleteIfExists(temp)}
            }
            memory=next;next
        } catch(_:Exception){emptyList()} // A local history failure cannot block ordinary search.
    }
}
