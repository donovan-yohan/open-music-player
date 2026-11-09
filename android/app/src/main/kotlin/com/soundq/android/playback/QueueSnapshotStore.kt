package com.soundq.android.playback

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import kotlinx.serialization.json.*

/** Durable metadata pages, not a second queue. Only the atomic root publishes a revision.
 * JSON parsing stays bounded to the legacy page size; decoded metadata may be complete.
 * No audio, URL, credential or Play intent is stored here. */
internal class QueueSnapshotStore(private val file:File) {
    companion object {
        const val MAX_ITEMS=QueuePolicy.MAX_LOGICAL_TRACKS
        const val MAX_BYTES=QueuePolicy.MAX_METADATA_BYTES
        const val PAGE_ITEMS=500
        const val PAGE_BYTES=500_000
        // Serializes root replacement and page reclamation across handles in this process.
        private val lock=Any()
        private fun digest(bytes:ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {"%02x".format(it)}
    }
    private val pages get()=File(file.parentFile,file.name+".pages")
    private fun atomic(target:File,bytes:ByteArray) {
        target.parentFile!!.mkdirs()
        val stage=File.createTempFile("queue-", ".stage",target.parentFile)
        try {
            FileOutputStream(stage).use {it.write(bytes);it.fd.sync()}
            Files.move(stage.toPath(),target.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
        } finally {stage.delete()}
    }
    fun write(saved:QueueSnapshot,current:()->Boolean={true})=synchronized(lock) {
        require(saved.items.size<=MAX_ITEMS && saved.position>=0 && (saved.items.isEmpty()||saved.selected in saved.items.indices))
        require(saved.items.map {it.occurrence}.toSet().size==saved.items.size)
        val jamKeys=saved.items.mapNotNull {it.jam?.admissionKey}
        require(jamKeys.distinct().size==jamKeys.size)
        val descriptors=mutableListOf<Pair<String,Int>>()
        var bytes=0L
        fun page(rows:List<SavedOccurrence>) {
            check(current())
            val candidate=QueueSnapshot(saved.endpoint,saved.account,rows,0,0)
            val encoded=candidate.encode().toByteArray(Charsets.UTF_8)
            if(encoded.size>PAGE_BYTES && rows.size>1) {val middle=rows.size/2;page(rows.subList(0,middle));page(rows.subList(middle,rows.size));return}
            require(encoded.size<=PAGE_BYTES && QueueSnapshot.decode(encoded.toString(Charsets.UTF_8),saved.endpoint,saved.account)!=null)
            bytes+=encoded.size;require(bytes<=MAX_BYTES)
            val hash=digest(encoded);val target=File(pages,hash)
            if(!target.exists())atomic(target,encoded)
            else require(target.length()==encoded.size.toLong() && digest(target.readBytes())==hash)
            descriptors+=hash to rows.size
        }
        saved.items.chunked(PAGE_ITEMS).forEach(::page)
        val root=buildJsonObject {
            put("version",4);put("endpoint",saved.endpoint);put("account",saved.account)
            put("count",saved.items.size);put("selected",saved.selected);put("position",saved.position)
            put("shuffleEnabled",saved.shuffleEnabled);put("loopMode",saved.loopMode.wireValue)
            put("pages",buildJsonArray {descriptors.forEach {(hash,count)->add(buildJsonObject {put("sha256",hash);put("count",count)})}})
        }.toString().toByteArray(Charsets.UTF_8)
        require(root.size<=PAGE_BYTES)
        check(current());atomic(file,root)
        val retained=descriptors.mapTo(mutableSetOf()) {it.first}
        pages.listFiles()?.filter {it.name !in retained}?.forEach {it.delete()}
    }
    fun read(endpoint:String,account:String,current:()->Boolean={true}):QueueSnapshot?=synchronized(lock) {
        if(!file.exists())return@synchronized null
        require(file.length()<=PAGE_BYTES)
        val raw=file.readText(Charsets.UTF_8)
        val root=Json.parseToJsonElement(raw).jsonObject
        if(root["version"]?.jsonPrimitive?.int in setOf(1,3))return@synchronized requireNotNull(QueueSnapshot.decode(raw,endpoint,account))
        require(root.getValue("version").jsonPrimitive.int in setOf(2,4) && root.getValue("endpoint").jsonPrimitive.content==endpoint && root.getValue("account").jsonPrimitive.content==account)
        val count=root.getValue("count").jsonPrimitive.int.also {require(it in 0..MAX_ITEMS)}
        val descriptors=root.getValue("pages").jsonArray.also {require(it.size<=MAX_ITEMS)}
        val rows=ArrayList<SavedOccurrence>(count)
        var bytes=0L
        descriptors.forEach {entry->
            check(current())
            val descriptor=entry.jsonObject
            val hash=descriptor.getValue("sha256").jsonPrimitive.content.also {require(it.matches(Regex("[a-f0-9]{64}")))}
            val expected=descriptor.getValue("count").jsonPrimitive.int.also {require(it in 1..PAGE_ITEMS && rows.size.toLong()+it<=count)}
            val source=File(pages,hash);require(source.length() in 1..PAGE_BYTES.toLong())
            bytes+=source.length();require(bytes<=MAX_BYTES)
            val encoded=source.readBytes();require(digest(encoded)==hash)
            val page=requireNotNull(QueueSnapshot.decode(encoded.toString(Charsets.UTF_8),endpoint,account))
            require(page.items.size==expected);rows.addAll(page.items)
        }
        require(rows.size==count && rows.map {it.occurrence}.toSet().size==count)
        val jamKeys=rows.mapNotNull {it.jam?.admissionKey}
        require(jamKeys.distinct().size==jamKeys.size)
        val selected=root.getValue("selected").jsonPrimitive.int
        val position=root.getValue("position").jsonPrimitive.long
        require(position>=0 && (rows.isEmpty()||selected in rows.indices))
        val repeat=root.getValue("loopMode").jsonPrimitive.content.also {require(it in SavedRepeatMode.entries.map {mode->mode.wireValue})}
        check(current())
        val shuffle=root.getValue("shuffleEnabled").jsonPrimitive.also {require(!it.isString)}.boolean
        QueueSnapshot(endpoint,account,rows,selected,position,shuffle,SavedRepeatMode.fromWire(repeat))
    }
    fun delete()=synchronized(lock) {file.delete();pages.deleteRecursively();Unit}
}
