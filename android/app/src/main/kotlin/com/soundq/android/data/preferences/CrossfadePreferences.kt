package com.soundq.android.data.preferences

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*

data class CrossfadeState(val seconds:Int=ListeningPreferences().crossfadeSeconds,val ready:Boolean=false,val error:Boolean=false,val revision:Long=0)
class CrossfadeCapture internal constructor(internal val revision:Long)
/** Accepted device-local ordinary transition length. Loading never prepares or starts playback. */
class CrossfadePreferences(private val file:File) {
    private val mutable=MutableStateFlow(CrossfadeState())
    val state:StateFlow<CrossfadeState> = mutable
    private var revision=0L
    private var accepted:ByteArray?=null
    private var writable=false
    private fun bytes():ByteArray? {
        require(!Files.isSymbolicLink(file.toPath()))
        if(!Files.exists(file.toPath(),NOFOLLOW_LINKS))return null
        require(Files.isRegularFile(file.toPath(),NOFOLLOW_LINKS)&&file.length() in 1..4096)
        return file.readBytes().also {require(it.size in 1..4096)}
    }
    @Synchronized fun load() {
        revision++;writable=false
        try {
            val raw=bytes()
            val seconds=if(raw==null)ListeningPreferences().crossfadeSeconds else raw.toString(Charsets.UTF_8).let { text ->
                // This owned v1 file contains exactly two literal property names
                // and integer values. Refuse duplicates/escaped aliases before
                // JsonObject can collapse them; preserve the suspect bytes.
                require(text.count { it=='"' }==4 && '\\' !in text)
                Json.parseToJsonElement(text).jsonObject
            }.let {
                require(it.keys==setOf("version","crossfadeSeconds"))
                val version=it.getValue("version").jsonPrimitive;require(!version.isString&&version.content=="1")
                val value=it.getValue("crossfadeSeconds").jsonPrimitive
                require(!value.isString&&value.content.matches(Regex("0|[1-9][0-9]*")))
                value.int.also {seconds->require(seconds in 0..12)}
            }
            accepted=raw;writable=true;mutable.value=CrossfadeState(seconds,true,revision=revision)
        }catch(_:Exception){mutable.value=mutable.value.copy(ready=true,error=true,revision=revision)}
    }
    @Synchronized fun capture():CrossfadeCapture?=if(writable)CrossfadeCapture(revision)else null
    @Synchronized fun setSeconds(capture:CrossfadeCapture,seconds:Int,valid:()->Boolean):Boolean {
        if(seconds !in 0..12||!valid()||!writable||capture.revision!=revision)return false
        revision++
        return try {
            val now=bytes();check(if(now==null)accepted==null else accepted?.contentEquals(now)==true)
            file.parentFile!!.mkdirs()
            val temp=Files.createTempFile(file.parentFile!!.toPath(),"crossfade-",".new")
            val raw="""{"version":1,"crossfadeSeconds":$seconds}""".toByteArray()
            try {FileOutputStream(temp.toFile()).use {it.write(raw);it.fd.sync()};check(valid());Files.move(temp,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)}finally {Files.deleteIfExists(temp)}
            accepted=raw;mutable.value=CrossfadeState(seconds,true,revision=revision);true
        }catch(_:Exception){writable=false;mutable.value=mutable.value.copy(error=true,revision=revision);false}
    }
}
