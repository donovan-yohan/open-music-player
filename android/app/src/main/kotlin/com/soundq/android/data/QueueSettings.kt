package com.soundq.android.data

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.serialization.json.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class QueueSettingsState(val keepQueued:Boolean=true,val loading:Boolean=true,val error:Boolean=false,val writable:Boolean=false)
class QueueSettingsCapture internal constructor(internal val version:Long)
interface QueuePreferencesStore {
    fun load():Boolean
    fun save(keepQueued:Boolean)
}
class FileQueuePreferencesStore(private val file:File):QueuePreferencesStore {
    private var loaded=false
    private var acceptedBytes:ByteArray?=null
    @Synchronized override fun load():Boolean {
        loaded=false
        if(!file.exists()){acceptedBytes=null;loaded=true;return true}
        require(file.length() in 1..4096)
        val bytes=file.readBytes();require(bytes.size in 1..4096)
        val body=Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
        require(body.keys==setOf("version","preserveManualQueue"))
        val version=body.getValue("version").jsonPrimitive
        require(!version.isString && version.int==1)
        val value=body.getValue("preserveManualQueue").jsonPrimitive
        require(!value.isString)
        return value.boolean.also {acceptedBytes=bytes;loaded=true}
    }
    @Synchronized override fun save(keepQueued:Boolean) {
        check(loaded)
        val current=if(file.exists()){require(file.length() in 1..4096);file.readBytes()}else null
        check(if(current==null)acceptedBytes==null else acceptedBytes?.contentEquals(current)==true)
        file.parentFile!!.mkdirs()
        val temp=Files.createTempFile(file.parentFile.toPath(),"queue-preferences-",".new").toFile()
        try {
            val bytes="""{"version":1,"preserveManualQueue":$keepQueued}""".toByteArray()
            FileOutputStream(temp).use {it.write(bytes);it.fd.sync()}
            Files.move(temp.toPath(),file.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
            acceptedBytes=bytes
        } finally {temp.delete()}
    }
}
class QueueSettingsRepository(private val store:QueuePreferencesStore) {
    private val mutable=MutableStateFlow(QueueSettingsState())
    val state:StateFlow<QueueSettingsState> = mutable
    private var version=0L
    @Synchronized fun load() {
        version++
        mutable.value=mutable.value.copy(loading=true,error=false,writable=false)
        mutable.value=try {QueueSettingsState(keepQueued=store.load(),loading=false,writable=true)}
        catch(_:Exception){mutable.value.copy(loading=false,error=true,writable=false)}
    }
    @Synchronized fun capture():QueueSettingsCapture?=if(mutable.value.writable && !mutable.value.loading)QueueSettingsCapture(version)else null
    @Synchronized fun setKeepQueued(capture:QueueSettingsCapture,keepQueued:Boolean,valid:()->Boolean = {true}):Boolean {
        if(!valid() || capture.version!=version || !mutable.value.writable || mutable.value.loading)return false
        version++
        return try {store.save(keepQueued);mutable.value=QueueSettingsState(keepQueued=keepQueued,loading=false,writable=true);true}
        catch(_:Exception){mutable.value=mutable.value.copy(error=true);false}
    }
}
