package com.soundq.android.data

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import java.security.MessageDigest
import kotlinx.serialization.json.*

data class LibrarySortChoice(val sort:LibrarySort=LibrarySort.Added,val ascending:Boolean=false)
/** Per endpoint AND account. Rejected/external bytes are not silently replaced. */
class LibrarySortStore(private val directory:File) {
    private val accepted=mutableMapOf<String,ByteArray?>()
    private fun key(endpoint:String,account:String)=MessageDigest.getInstance("SHA-256").digest(
        JsonArray(listOf(JsonPrimitive(endpoint),JsonPrimitive(account))).toString().toByteArray()).joinToString("") {"%02x".format(it)}
    private fun bytes(file:File):ByteArray? {
        require(!Files.isSymbolicLink(directory.toPath())&&!Files.isSymbolicLink(file.toPath()))
        if(!Files.exists(file.toPath(),NOFOLLOW_LINKS))return null
        require(Files.isRegularFile(file.toPath(),NOFOLLOW_LINKS)&&file.length() in 1..4096)
        return file.readBytes().also {require(it.size in 1..4096)}
    }
    @Synchronized fun load(endpoint:String,account:String):LibrarySortChoice {
        val key=key(endpoint,account)
        val raw=bytes(File(directory,"$key.json"))
        val choice=if(raw==null)LibrarySortChoice() else Json.parseToJsonElement(raw.toString(Charsets.UTF_8)).jsonObject.let {
            require(it.keys==setOf("version","sort","ascending"))
            require(!it.getValue("version").jsonPrimitive.isString&&it.getValue("version").jsonPrimitive.int==1)
            val sort=it.getValue("sort").jsonPrimitive;val order=it.getValue("ascending").jsonPrimitive
            require(sort.isString&&!order.isString)
            LibrarySortChoice(LibrarySort.entries.single {s->s.wire==sort.content},order.boolean)
        }
        accepted[key]=raw
        return choice
    }
    @Synchronized fun save(endpoint:String,account:String,choice:LibrarySortChoice,valid:()->Boolean) {
        val key=key(endpoint,account);check(accepted.containsKey(key)&&valid())
        val file=File(directory,"$key.json");val now=bytes(file);val prior=accepted[key]
        check(if(now==null)prior==null else prior?.contentEquals(now)==true)
        check(directory.isDirectory||directory.mkdirs())
        val raw=buildJsonObject {put("version",1);put("sort",choice.sort.wire);put("ascending",choice.ascending)}.toString().toByteArray()
        val temp=Files.createTempFile(directory.toPath(),"library-sort-",".new")
        try {
            FileOutputStream(temp.toFile()).use {it.write(raw);it.fd.sync()}
            check(valid());Files.move(temp,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
            accepted[key]=raw
        } finally {Files.deleteIfExists(temp)}
    }
}
