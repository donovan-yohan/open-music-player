package com.soundq.android.data.jam

import com.soundq.android.data.connect.*
import kotlinx.serialization.json.*
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import java.nio.file.attribute.BasicFileAttributes

internal data class ApprovalIntent(val fingerprint:String,val expectedVersion:Long,val hostSession:String,val generation:String,val confirmed:Boolean=false,val admissionKey:String?=null)

/** Consent/attempt/receipt custody only. This is not a queue or permission to replay. */
internal class AdmissionHistory(private val file:File?=null,private val binding:String?=null) {
    private data class Attempt(val key:String?,val receipt:AdmissionReceipt?)
    private val attempts=linkedMapOf<String,Attempt>()
    private val approvals=linkedMapOf<String,ApprovalIntent>()
    private var accepted:ByteArray?=null
    private var retainedDirectoryKey:Any?=null
    private var retainedFileKey:Any?=null
    init {
        require((file==null)==(binding==null))
        if(file!=null) {
            require(Regex("[0-9a-f]{64}").matches(binding!!))
            safePath();require(Files.isDirectory(file.parentFile!!.toPath(),NOFOLLOW_LINKS))
            retainedDirectoryKey=identity(file.parentFile!!)
            accepted=read()
            if(accepted!=null)retainedFileKey=identity(file)
            accepted?.let {raw ->
                val body=Json.parseToJsonElement(raw.toString(Charsets.UTF_8)).jsonObject
                val version=number(body,"version");require(version in 1L..2L)
                keys(body,setOf("version","binding","attempts")+if(version==2L)setOf("approvals")else emptySet());require(text(body,"binding",64)==binding)
                val rows=body.getValue("attempts").jsonArray;require(rows.size<=50)
                rows.forEach {element ->
                    val row=element.jsonObject;keys(row,setOf("requestId","admissionKey","receipt"))
                    val id=uuid(text(row,"requestId",36));require(id !in attempts)
                    val key=row["admissionKey"]?.takeUnless {it is JsonNull}?.jsonPrimitive?.let {require(it.isString&&Regex("[0-9a-f]{64}").matches(it.content));it.content}
                    val receipt=row["receipt"]?.takeUnless {it is JsonNull}?.jsonObject?.let {r ->
                        keys(r,setOf("requestId","sessionId","occurrenceId","ownerAfter"));require(text(r,"requestId",36)==id)
                        val after=r["ownerAfter"]?.takeUnless {it is JsonNull}?.jsonPrimitive?.let {require(it.isString&&it.content.isNotBlank()&&it.content.toByteArray().size<=128);it.content}
                        AdmissionReceipt(id,text(r,"sessionId",128).also {require(it.isNotBlank())},text(r,"occurrenceId",128).also {require(it.isNotBlank())},after)
                    }
                    attempts[id]=Attempt(key,receipt)
                }
                if(version==2L)body.getValue("approvals").jsonArray.also {require(it.size<=50)}.forEach {element ->
                    val row=element.jsonObject;keys(row,setOf("requestId","fingerprint","expectedVersion","hostSession","generation","confirmed","admissionKey"))
                    val id=uuid(text(row,"requestId",36));require(id !in approvals)
                    val confirmed=row.getValue("confirmed").jsonPrimitive.also {require(!it.isString)}.boolean
                    val key=row["admissionKey"]?.takeUnless {it is JsonNull}?.jsonPrimitive?.also {require(it.isString)}?.content
                    approvals[id]=checked(ApprovalIntent(text(row,"fingerprint",64),number(row,"expectedVersion",min=1),text(row,"hostSession",128),text(row,"generation",36),confirmed,key))
                }
            }
        }
    }
    @Synchronized fun attempted(id:String)=attempts.containsKey(id)
    @Synchronized fun approval(id:String)=approvals[id]
    @Synchronized fun approvals():Map<String,ApprovalIntent> = approvals.toMap()
    /** Save the immutable exact approval payload before its first network write. */
    @Synchronized fun beginApproval(id:String,intent:ApprovalIntent):ApprovalIntent {
        uuid(id);checked(intent)
        approvals[id]?.let {require(it.fingerprint==intent.fingerprint&&it.hostSession==intent.hostSession);return it}
        require(approvals.size<50&&!intent.confirmed&&intent.admissionKey==null)
        val next=LinkedHashMap(approvals);next[id]=intent;commit(LinkedHashMap(attempts),next);return intent
    }
    @Synchronized fun confirmApproval(id:String,key:String) {
        val before=approvals.getValue(id);require(before.admissionKey==null||before.admissionKey==key)
        val next=LinkedHashMap(approvals);next[id]=checked(before.copy(confirmed=true,admissionKey=key));commit(LinkedHashMap(attempts),next)
    }
    /** Only the caller's actual authorized insertion receipt may advance siblings. */
    @Synchronized fun advanceApprovals(session:String,before:String,after:String) {
        uuid(before);uuid(after)
        val next=LinkedHashMap(approvals.mapValues {(_,intent)->if(intent.hostSession==session&&intent.generation==before)intent.copy(generation=after)else intent})
        if(next!=approvals)commit(LinkedHashMap(attempts),next)
    }
    private fun checked(intent:ApprovalIntent):ApprovalIntent {
        require(Regex("[0-9a-f]{64}").matches(intent.fingerprint)&&intent.expectedVersion>0&&intent.hostSession.isNotBlank()&&intent.hostSession.toByteArray().size<=128)
        uuid(intent.generation)
        require(intent.confirmed==(intent.admissionKey!=null));intent.admissionKey?.let {require(Regex("[0-9a-f]{64}").matches(it))}
        return intent
    }
    @Synchronized fun receipt(id:String,key:String?=null):AdmissionReceipt? {
        val attempt=attempts[id] ?: return null
        require(attempt.key==key)
        return attempt.receipt
    }
    @Synchronized fun begin(id:String,key:String?=null):Boolean {
        if(attempts.containsKey(id)||attempts.size>=50)return false
        if(file!=null)uuid(id)
        if(key!=null)require(Regex("[0-9a-f]{64}").matches(key))
        approvals[id]?.let {require(it.confirmed&&it.admissionKey==key)}
        val next=LinkedHashMap(attempts);next[id]=Attempt(key,null);commit(next);return true
    }
    @Synchronized fun admitted(id:String,receipt:AdmissionReceipt?) {
        val before=attempts.getValue(id)
        if(receipt!=null)require(receipt.requestId==id&&receipt.sessionId.isNotBlank()&&receipt.occurrenceId.isNotBlank())
        if(before.receipt!=null)require(receipt==before.receipt)
        val next=LinkedHashMap(attempts);next[id]=before.copy(receipt=receipt);commit(next)
    }
    private fun safePath() {
        var cursor:File?=file!!.absoluteFile
        while(cursor!=null){require(!Files.isSymbolicLink(cursor.toPath()));cursor=cursor.parentFile}
    }
    private fun read():ByteArray? {
        safePath()
        if(!Files.exists(file!!.toPath(),NOFOLLOW_LINKS))return null
        require(Files.isRegularFile(file.toPath(),NOFOLLOW_LINKS)&&file.length() in 1..65536)
        return file.readBytes().also {require(it.size in 1..65536)}
    }
    private fun identity(file:File)=Files.readAttributes(file.toPath(),BasicFileAttributes::class.java,NOFOLLOW_LINKS).fileKey().also {require(it!=null)}
    private fun unchanged() {
        safePath();check(identity(file!!.parentFile!!)==retainedDirectoryKey)
        val current=read()
        check(if(current==null)retainedFileKey==null else identity(file)==retainedFileKey)
        check(if(current==null)accepted==null else accepted?.contentEquals(current)==true)
    }
    private fun commit(next:LinkedHashMap<String,Attempt>,nextApprovals:LinkedHashMap<String,ApprovalIntent> = LinkedHashMap(approvals)) {
        if(file==null){attempts.clear();attempts.putAll(next);approvals.clear();approvals.putAll(nextApprovals);return}
        val bytes=buildJsonObject {
            put("version",2);put("binding",binding)
            put("attempts",buildJsonArray {next.forEach {(id,attempt)->add(buildJsonObject {
                put("requestId",id);put("admissionKey",attempt.key?.let(::JsonPrimitive) ?: JsonNull)
                put("receipt",attempt.receipt?.let {receipt ->JsonObject(receipt.json()+mapOf("ownerAfter" to (receipt.ownerAfter?.let(::JsonPrimitive) ?: JsonNull)))} ?: JsonNull)
            })}})
            put("approvals",buildJsonArray {nextApprovals.forEach {(id,intent)->add(buildJsonObject {
                put("requestId",id);put("fingerprint",intent.fingerprint);put("expectedVersion",intent.expectedVersion)
                put("hostSession",intent.hostSession);put("generation",intent.generation);put("confirmed",intent.confirmed)
                put("admissionKey",intent.admissionKey?.let(::JsonPrimitive) ?: JsonNull)
            })}})
        }.toString().toByteArray()
        require(bytes.size<=65536);unchanged()
        safePath()
        val parent=file.parentFile!!;val parentKey=identity(parent)
        val stage=Files.createTempFile(parent.toPath(),"admission-",".new").toFile()
        val stageKey=identity(stage)
        fun owned()=runCatching {safePath();identity(parent)==parentKey&&identity(stage)==stageKey}.getOrDefault(false)
        try {
            FileOutputStream(stage).use {it.write(bytes);it.fd.sync()}
            unchanged();check(owned())
            Files.move(stage.toPath(),file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
            check(identity(parent)==retainedDirectoryKey&&identity(file)==stageKey)
            accepted=bytes;retainedFileKey=stageKey;attempts.clear();attempts.putAll(next);approvals.clear();approvals.putAll(nextApprovals)
        }finally {if(owned())stage.delete()}
    }
}
