package com.soundq.android.data.preferences

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*

data class SwipeQueueState(val mode:SwipeQueue=ListeningPreferences().swipeQueue,val ready:Boolean=false,val error:Boolean=false,val revision:Long=0)
class SwipeQueueCapture internal constructor(internal val owner:SwipeQueuePreferences,internal val revision:Long)
/** Strict accepted installation choice. Rejected bytes are never overwritten. No playback side effects. */
class SwipeQueuePreferences(private val file:File) {
    private val mutable=MutableStateFlow(SwipeQueueState())
    val state:StateFlow<SwipeQueueState> = mutable
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
            val mode=if(raw==null)ListeningPreferences().swipeQueue else Json.parseToJsonElement(raw.toString(Charsets.UTF_8)).jsonObject.let {
                require(it.keys==setOf("version","swipeQueue"))
                val version=it.getValue("version").jsonPrimitive;require(!version.isString&&version.int==1)
                val value=it.getValue("swipeQueue").jsonPrimitive;require(value.isString)
                when(value.content){"addToQueue"->SwipeQueue.AddToQueue;"playNext"->SwipeQueue.PlayNext;else->error("Unknown mode")}
            }
            accepted=raw;writable=true;mutable.value=SwipeQueueState(mode,true,revision=revision)
        }catch(_:Exception){mutable.value=mutable.value.copy(ready=true,error=true,revision=revision)}
    }
    @Synchronized fun capture():SwipeQueueCapture?=if(writable)SwipeQueueCapture(this,revision)else null
    @Synchronized fun setMode(capture:SwipeQueueCapture,mode:SwipeQueue,valid:()->Boolean):Boolean {
        if(!valid()||!writable||capture.owner!==this||capture.revision!=revision)return false
        revision++
        return try {
            val now=bytes();check(if(now==null)accepted==null else accepted?.contentEquals(now)==true)
            file.parentFile!!.mkdirs()
            val temp=Files.createTempFile(file.parentFile!!.toPath(),"swipe-queue-",".new")
            val raw="""{"version":1,"swipeQueue":"${if(mode==SwipeQueue.AddToQueue)"addToQueue" else "playNext"}"}""".toByteArray()
            try {FileOutputStream(temp.toFile()).use {it.write(raw);it.fd.sync()};check(valid());Files.move(temp,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)}finally {Files.deleteIfExists(temp)}
            accepted=raw;mutable.value=SwipeQueueState(mode,true,revision=revision);true
        }catch(_:Exception){writable=false;mutable.value=mutable.value.copy(error=true,revision=revision);false}
    }
}
