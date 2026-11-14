package com.soundq.android.playback.nativeengine

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Properties

/** Durable live-original version observations. These are NOT SHA proofs.
 * A changed observation is persisted before any successor may inherit progress.
 * Bad/unknown storage is refused, never replaced by a recovered empty document.
 */
internal class LiveOriginalVersions(private val file:File) {
    private val values=Properties()
    init {
        if(file.exists()) {
            require(file.length() in 1..8L*1024*1024)
            file.inputStream().use {values.load(it)}
            require(values.getProperty("format")=="soundq-live-original-v1" && values.size<=20001)
        } else values.setProperty("format","soundq-live-original-v1")
    }
    enum class Observation { First, Matching, Changed }
    @Synchronized fun observe(key:String,version:String,beforeChange:()->Unit={}):Observation {
        require(key.isNotBlank() && key!="format" && key.length<=8192 && version.isNotBlank() && version.length<=1024)
        val old=values.getProperty(key)
        if(old==version)return Observation.Matching
        if(old!=null)beforeChange() // canonical reset MUST precede successor stamp
        val next=Properties().also {it.putAll(values);it.setProperty(key,version)}
        require(next.size<=20001)
        file.parentFile!!.mkdirs()
        val stage=File.createTempFile("live-version-",".pending",file.parentFile)
        try {
            FileOutputStream(stage).use {next.store(it,"Live original versions, not content hashes");it.fd.sync()}
            Files.move(stage.toPath(),file.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
            values.clear();values.putAll(next)
        } finally {stage.delete()}
        return if(old==null)Observation.First else Observation.Changed
    }
}
