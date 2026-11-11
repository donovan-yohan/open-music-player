package com.soundq.android.data.preferences

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*

enum class AppearanceError { Read, Write }
data class AppearanceState(val choice:Appearance=Appearance.System,val ready:Boolean=false,val error:AppearanceError?=null,val revision:Long=0)
class AppearanceCapture internal constructor(internal val owner:AppearancePreferences,internal val revision:Long)
/** Device-local accepted appearance. Rejected bytes never grant write authority. */
class AppearancePreferences(private val file:File) {
    private val mutable=MutableStateFlow(AppearanceState())
    val state:StateFlow<AppearanceState> = mutable
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
            val choice=if(raw==null)Appearance.System else Json.parseToJsonElement(raw.toString(Charsets.UTF_8)).jsonObject.let {
                require(it.keys==setOf("version","appearance"))
                val version=it.getValue("version").jsonPrimitive;require(!version.isString&&version.int==1)
                val value=it.getValue("appearance").jsonPrimitive;require(value.isString)
                requireNotNull(Appearance.fromWire(value.content))
            }
            accepted=raw;writable=true;mutable.value=AppearanceState(choice,true,revision=revision)
        }catch(_:Exception){mutable.value=mutable.value.copy(ready=true,error=AppearanceError.Read,revision=revision)}
    }
    @Synchronized fun capture():AppearanceCapture?=if(writable)AppearanceCapture(this,revision)else null
    @Synchronized fun setChoice(capture:AppearanceCapture,choice:Appearance,valid:()->Boolean):Boolean {
        if(!valid()||!writable||capture.owner!==this||capture.revision!=revision)return false
        revision++
        return try {
            val now=bytes();check(if(now==null)accepted==null else accepted?.contentEquals(now)==true)
            val parent=requireNotNull(file.parentFile)
            parent.mkdirs()
            val temp=Files.createTempFile(parent.toPath(),"appearance-",".new")
            val raw="""{"version":1,"appearance":"${choice.wire}"}""".toByteArray()
            try {
                FileOutputStream(temp.toFile()).use {it.write(raw);it.fd.sync()}
                check(valid())
                Files.move(temp,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
            }finally {Files.deleteIfExists(temp)}
            accepted=raw;mutable.value=AppearanceState(choice,true,revision=revision);true
        }catch(_:Exception){mutable.value=mutable.value.copy(error=AppearanceError.Write,revision=revision);false}
    }
}
