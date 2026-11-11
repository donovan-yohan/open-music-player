package com.soundq.android.data.jam

import com.soundq.android.data.connect.*
import kotlinx.serialization.json.*
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*

/** Non-secret exact read target only. Never restores a writer, consent or session. */
internal class JamRecoveryTarget(private val file:File,private val binding:String) {
    private fun safe() {
        var path:File?=file.absoluteFile
        while(path!=null){require(!Files.isSymbolicLink(path.toPath()));path=path.parentFile}
        require(Files.isDirectory(file.parentFile!!.toPath(),NOFOLLOW_LINKS))
    }
    fun read():String? {
        safe();if(!Files.exists(file.toPath(),NOFOLLOW_LINKS))return null
        require(Files.isRegularFile(file.toPath(),NOFOLLOW_LINKS)&&file.length() in 1..1024)
        val row=Json.parseToJsonElement(file.readText()).jsonObject
        keys(row,setOf("version","binding","jamId"));require(number(row,"version")==1L&&text(row,"binding",64)==binding)
        return row["jamId"]?.takeUnless {it is JsonNull}?.let {uuid(text(row,"jamId",36))}
    }
    fun save(id:String?) {
        safe();id?.let(::uuid);read() // Preserve rejected bytes instead of silently replacing them.
        val bytes=buildJsonObject {put("version",1);put("binding",binding);put("jamId",id?.let(::JsonPrimitive) ?: JsonNull)}.toString().toByteArray()
        val stage=Files.createTempFile(file.parentFile!!.toPath(),"jam-target-",".new")
        try {
            FileOutputStream(stage.toFile()).use {it.write(bytes);it.fd.sync()}
            safe();Files.move(stage,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
        }finally {Files.deleteIfExists(stage)}
    }
}
