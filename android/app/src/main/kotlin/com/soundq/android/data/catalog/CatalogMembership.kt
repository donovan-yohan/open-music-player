package com.soundq.android.data.catalog

import com.soundq.android.data.*
import kotlinx.serialization.json.*
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.OffsetDateTime
import java.util.UUID

internal fun canonicalMembershipId(value:String) {
    require(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").matches(value)&&value!="00000000-0000-0000-0000-000000000000")
}
/** Only finite protocol codes survive transport. No server message or raw error body. */
class CatalogMembershipRefusal(val code:Code):Exception() {
    enum class Code { VALIDATION_ERROR, UNAUTHORIZED, TARGET_UNAVAILABLE, TARGET_MISMATCH, NEEDS_REVIEW, SERVICE_DISABLED, UNAVAILABLE }
}
object CatalogMembershipJson {
    fun ack(body:JsonObject,recording:RecordingMbid,account:String,track:Long) {
        try {
            canonicalMembershipId(recording.value);canonicalMembershipId(account);require(track>0)
            require(body.keys==setOf("recordingMbid","userId","trackId","status","addedAt"))
            fun text(key:String)=body.getValue(key).jsonPrimitive.let {require(it.isString);it.content}
            require(text("recordingMbid")==recording.value&&text("userId")==account&&text("status")=="member")
            body.getValue("trackId").jsonPrimitive.let {require(!it.isString&&Regex("[1-9][0-9]*").matches(it.content)&&it.long==track)}
            val time=text("addedAt");require(time.length in 20..40&&Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})").matches(time));OffsetDateTime.parse(time)
        } catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
    }
    fun refusal(status:Int,body:JsonObject):CatalogMembershipRefusal.Code? {
        val expected=when(status){400->setOf("VALIDATION_ERROR");401->setOf("UNAUTHORIZED");404->setOf("TARGET_UNAVAILABLE");409->setOf("TARGET_MISMATCH","NEEDS_REVIEW");503->setOf("SERVICE_DISABLED");else->emptySet()}
        val declared=(body["code"] as? JsonPrimitive)?.takeIf {it.isString}?.content
        return declared?.takeIf {it in expected}?.let {CatalogMembershipRefusal.Code.valueOf(it)}
    }
}
/** Durable intended edition/occurrence facts. Never contains credentials, URLs or response bytes. */
data class CatalogMembershipIntent(val operation:String,val endpoint:String,val account:String,val recording:String,val track:Long,val edition:String,val occurrence:Int,val title:String) {
    init {
        canonicalMembershipId(operation);canonicalMembershipId(account);canonicalMembershipId(recording);canonicalMembershipId(edition)
        require(ApiEndpoint.parse(endpoint).identity==endpoint&&track>0&&occurrence in 0..100000&&title.length in 1..16384&&title.none {it.code<32&&it !in "\n\t"})
    }
}
data class CatalogMembershipRecovery(val intent:CatalogMembershipIntent,val status:String="Unconfirmed",val retryEligible:Boolean=false,val busy:Boolean=false)
class CatalogMembershipRequest internal constructor(internal val view:CatalogView,internal val intent:CatalogMembershipIntent,internal val selection:CatalogSelection?,internal val write:Boolean,internal val navigation:Long) {
    internal var consumed=false
}
private const val MEMBERSHIP_JOURNAL_MAX_BYTES=1_000_000
/** Bounded atomic no-backup journal. Rejected bytes are preserved and disable writes only. */
class CatalogMembershipJournal(private val file:File?=null) {
    private var rows:List<CatalogMembershipIntent>?=null
    private var rejected=false
    private fun load():List<CatalogMembershipIntent> {
        check(!rejected)
        rows?.let {return it}
        try {
            val result=if(file?.exists()!=true)emptyList() else {
                require(file.length() in 1..MEMBERSHIP_JOURNAL_MAX_BYTES)
                val root=Json.parseToJsonElement(file.readText()).jsonObject
                require(root.keys==setOf("version","entries"));root.getValue("version").jsonPrimitive.let {require(!it.isString&&it.content=="1")}
                root.getValue("entries").jsonArray.map {element->val o=element.jsonObject
                    require(o.keys==setOf("operation","endpoint","account","recording","track","edition","occurrence","title","origin"));require(o.getValue("origin").jsonPrimitive.let {it.isString&&it.content=="catalog"})
                    fun s(k:String)=o.getValue(k).jsonPrimitive.let {require(it.isString);it.content}
                    fun n(k:String)=o.getValue(k).jsonPrimitive.let {require(!it.isString&&Regex("0|[1-9][0-9]*").matches(it.content));it.long}
                    CatalogMembershipIntent(s("operation"),s("endpoint"),s("account"),s("recording"),n("track"),s("edition"),n("occurrence").also {require(it<=100000)}.toInt(),s("title"))
                }.also {list->require(list.size<=32&&list.map {it.operation}.distinct().size==list.size&&list.map {Triple(it.endpoint,it.account,it.recording)}.distinct().size==list.size)}
            }
            rows=result;return result
        } catch(e:Exception){rejected=true;throw e}
    }
    private fun save(next:List<CatalogMembershipIntent>) {
        check(!rejected)
        val body=buildJsonObject {put("version",1);put("entries",buildJsonArray {next.forEach {i->add(buildJsonObject {put("origin","catalog");put("operation",i.operation);put("endpoint",i.endpoint);put("account",i.account);put("recording",i.recording);put("track",i.track);put("edition",i.edition);put("occurrence",i.occurrence);put("title",i.title)})}})}
        val bytes=body.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size in 1..MEMBERSHIP_JOURNAL_MAX_BYTES)
        if(file!=null) {
            file.parentFile?.mkdirs()
            val temp=File(file.parentFile,file.name+".pending")
            try {temp.outputStream().use {it.write(bytes);it.fd.sync()};Files.move(temp.toPath(),file.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)} finally {temp.delete()}
        }
        rows=next
    }
    @Synchronized fun entries(endpoint:String,account:String)=load().filter {it.endpoint==endpoint&&it.account==account}
    @Synchronized fun prepare(intent:CatalogMembershipIntent) {
        val old=load();old.singleOrNull {it.operation==intent.operation}?.let {require(it==intent);return}
        require(old.size<32&&old.none {it.endpoint==intent.endpoint&&it.account==intent.account&&it.recording==intent.recording})
        save(old+intent)
    }
    @Synchronized fun confirm(intent:CatalogMembershipIntent) {val old=load();require(old.any {it==intent});save(old.filterNot {it==intent})}
}
