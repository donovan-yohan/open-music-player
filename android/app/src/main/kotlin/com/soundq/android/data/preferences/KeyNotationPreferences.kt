package com.soundq.android.data.preferences

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*

enum class KeyNotationError { Read, Write }
data class KeyNotationState(val choice:KeyNotation=KeyNotation.Camelot,val ready:Boolean=false,val error:KeyNotationError?=null,val revision:Long=0)
class KeyNotationCapture internal constructor(internal val owner:KeyNotationPreferences,internal val revision:Long)
/** Installation-local accepted bytes. Rejected or externally replaced data requires explicit Reload. */
class KeyNotationPreferences(private val file:File) {
    private val mutable=MutableStateFlow(KeyNotationState())
    val state:StateFlow<KeyNotationState> = mutable
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
            val choice=if(raw==null)KeyNotation.Camelot else Json.parseToJsonElement(raw.decodeToString(throwOnInvalidSequence=true)).jsonObject.let {
                require(it.keys==setOf("version","keyNotation"))
                val version=it.getValue("version").jsonPrimitive;require(!version.isString&&version.int==1)
                val value=it.getValue("keyNotation").jsonPrimitive;require(value.isString)
                requireNotNull(KeyNotation.fromWire(value.content))
            }
            accepted=raw;writable=true;mutable.value=KeyNotationState(choice,true,revision=revision)
        }catch(_:Exception){mutable.value=mutable.value.copy(ready=true,error=KeyNotationError.Read,revision=revision)}
    }
    @Synchronized fun capture():KeyNotationCapture?=if(writable)KeyNotationCapture(this,revision)else null
    @Synchronized fun setChoice(capture:KeyNotationCapture,choice:KeyNotation,valid:()->Boolean):Boolean {
        if(!valid()||!writable||capture.owner!==this||capture.revision!=revision)return false
        revision++
        try {
            check(unchanged(bytes()))
        }catch(_:Exception){writable=false;mutable.value=mutable.value.copy(error=KeyNotationError.Read,revision=revision);return false}
        return try {
            val parent=requireNotNull(file.parentFile);parent.mkdirs()
            val temp=Files.createTempFile(parent.toPath(),"key-notation-",".new")
            val raw="""{"version":1,"keyNotation":"${choice.wire}"}""".toByteArray()
            try {
                FileOutputStream(temp.toFile()).use {it.write(raw);it.fd.sync()}
                check(valid())
                try {check(unchanged(bytes()))}catch(e:Exception){writable=false;throw e}
                Files.move(temp,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
            }finally {Files.deleteIfExists(temp)}
            accepted=raw;mutable.value=KeyNotationState(choice,true,revision=revision);true
        }catch(_:Exception){mutable.value=mutable.value.copy(error=if(writable)KeyNotationError.Write else KeyNotationError.Read,revision=revision);false}
    }
}
