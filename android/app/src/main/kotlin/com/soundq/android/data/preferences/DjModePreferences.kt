package com.soundq.android.data.preferences

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*

enum class DjModeError { Read, Write }
data class DjModeState(val enabled:Boolean=ListeningPreferences().djMode,val ready:Boolean=false,val error:DjModeError?=null,val revision:Long=0)
class DjModeCapture internal constructor(internal val owner:DjModePreferences,internal val revision:Long)
/** Strict installation-local accepted choice. Unreadable bytes never enable this feature. */
class DjModePreferences(private val file:File) {
    private val mutable=MutableStateFlow(DjModeState())
    val state:StateFlow<DjModeState> = mutable
    private var revision=0L
    private var accepted:ByteArray?=null
    private var writable=false
    private fun bytes():ByteArray? {
        require(!Files.isSymbolicLink(file.toPath()))
        if(!Files.exists(file.toPath(),NOFOLLOW_LINKS))return null
        require(Files.isRegularFile(file.toPath(),NOFOLLOW_LINKS)&&file.length() in 1..4096)
        return file.readBytes().also {require(it.size in 1..4096)}
    }
    private fun unchanged(raw:ByteArray?)=if(raw==null)accepted==null else accepted?.contentEquals(raw)==true
    @Synchronized fun load() {
        revision++;writable=false
        try {
            val raw=bytes()
            val enabled=if(raw==null)ListeningPreferences().djMode else Json.parseToJsonElement(raw.decodeToString(throwOnInvalidSequence=true)).jsonObject.let {
                require(it.keys==setOf("version","djMode"))
                val version=it.getValue("version").jsonPrimitive;require(!version.isString&&version.int==1)
                val value=it.getValue("djMode").jsonPrimitive;require(!value.isString);value.boolean
            }
            accepted=raw;writable=true;mutable.value=DjModeState(enabled,true,revision=revision)
        }catch(_:Exception){mutable.value=mutable.value.copy(ready=true,error=DjModeError.Read,revision=revision)}
    }
    @Synchronized fun enabled()=writable&&mutable.value.ready&&mutable.value.enabled
    @Synchronized fun capture():DjModeCapture?=if(writable)DjModeCapture(this,revision)else null
    @Synchronized fun setEnabled(capture:DjModeCapture,enabled:Boolean,valid:()->Boolean):Boolean {
        if(!valid()||!writable||capture.owner!==this||capture.revision!=revision)return false
        revision++
        try {check(unchanged(bytes()))}catch(_:Exception){writable=false;mutable.value=mutable.value.copy(error=DjModeError.Read,revision=revision);return false}
        return try {
            val parent=requireNotNull(file.parentFile);parent.mkdirs()
            val temp=Files.createTempFile(parent.toPath(),"dj-mode-",".new")
            val raw="""{"version":1,"djMode":$enabled}""".toByteArray()
            try {
                FileOutputStream(temp.toFile()).use {it.write(raw);it.fd.sync()}
                check(valid())
                try {check(unchanged(bytes()))}catch(e:Exception){writable=false;throw e}
                Files.move(temp,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
            }finally {Files.deleteIfExists(temp)}
            accepted=raw;mutable.value=DjModeState(enabled,true,revision=revision);true
        }catch(_:Exception){mutable.value=mutable.value.copy(error=if(writable)DjModeError.Write else DjModeError.Read,revision=revision);false}
    }
}
