package com.soundq.android.data.preferences

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*

data class StoragePreferenceState(val temporaryAudioEnabled:Boolean=true,val ready:Boolean=false,val error:Boolean=false)
class StoragePreferenceCapture internal constructor(internal val owner:StoragePreferences,internal val version:Long)
/** Installation choice only. Non-secret, bounded and ACK-only. Unknown bytes remain untouched. */
class StoragePreferences(private val file:File) {
    private val mutable=MutableStateFlow(StoragePreferenceState())
    val state:StateFlow<StoragePreferenceState> = mutable
    private var version=0L
    private var accepted:ByteArray?=null
    private var writable=false
    private fun bytes():ByteArray? {
        require(!Files.isSymbolicLink(file.toPath()))
        if(!Files.exists(file.toPath(),NOFOLLOW_LINKS))return null
        require(Files.isRegularFile(file.toPath(),NOFOLLOW_LINKS)&&file.length() in 1..4096)
        return file.readBytes().also {require(it.size in 1..4096)}
    }
    @Synchronized fun load() {
        version++;writable=false
        try {
            val raw=bytes()
            val enabled=if(raw==null)true else Json.parseToJsonElement(raw.toString(Charsets.UTF_8)).jsonObject.let {
                require(it.keys==setOf("version","temporaryAudioEnabled"))
                require(!it.getValue("version").jsonPrimitive.isString&&it.getValue("version").jsonPrimitive.int==1)
                val v=it.getValue("temporaryAudioEnabled").jsonPrimitive;require(!v.isString);v.boolean
            }
            accepted=raw;writable=true;mutable.value=StoragePreferenceState(enabled,true)
        }catch(_:Exception){mutable.value=mutable.value.copy(ready=true,error=true)}
    }
    @Synchronized fun capture():StoragePreferenceCapture?=if(writable)StoragePreferenceCapture(this,version)else null
    @Synchronized fun setTemporaryAudio(capture:StoragePreferenceCapture,enabled:Boolean,valid:()->Boolean):Boolean {
        if(!valid()||!writable||capture.owner!==this||capture.version!=version)return false
        version++
        return try {
            val now=bytes();check(if(now==null)accepted==null else accepted?.contentEquals(now)==true)
            file.parentFile!!.mkdirs()
            val temp=Files.createTempFile(file.parentFile!!.toPath(),"storage-preferences-",".new")
            val raw="""{"version":1,"temporaryAudioEnabled":$enabled}""".toByteArray()
            try {FileOutputStream(temp.toFile()).use {it.write(raw);it.fd.sync()};check(valid());Files.move(temp,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)}finally {Files.deleteIfExists(temp)}
            accepted=raw;mutable.value=StoragePreferenceState(enabled,true);true
        }catch(_:Exception){writable=false;mutable.value=mutable.value.copy(error=true);false}
    }
}
