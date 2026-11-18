package com.soundq.android.data.acquisition

import com.soundq.android.data.imports.ImportJobId
import kotlinx.serialization.json.*
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/** Minimal no-backup receipt journal. No URLs, credentials, source text or server errors. */
data class IntakeReceipt(val operation:Long,val kind:String,val phase:String,val job:String?,val sessionId:String?=null,val candidateId:String?=null,val decisionId:String?=null,val playlistId:Long?=null)
class IntakeReceipts(private val file:File?=null) {
    private var records=linkedMapOf<String,List<IntakeReceipt>>()
    private var loaded=false
    private var rejected=false
    private fun key(endpoint:String,account:String)=buildJsonArray {add(endpoint);add(account)}.toString()
    private fun load() {
        if(loaded)return
        loaded=true
        if(file?.exists()!=true)return
        try {
            require(file.length()<=1_000_000)
            val body=Json.parseToJsonElement(file.readText()).jsonObject
            require(body.getValue("version").jsonPrimitive.int==1)
            records=body.getValue("owners").jsonObject.mapValues {(_,v)->v.jsonArray.map {e->val o=e.jsonObject
                val op=o.getValue("operation").jsonPrimitive.let {require(!it.isString);it.long.also {n->require(n>0)}}
                val kind=o.getValue("kind").jsonPrimitive.content.also {require(it in setOf("download","source","playlist","research","queue","review","playlist-sync"))}
                val phase=o.getValue("phase").jsonPrimitive.content.also {require(it in setOf("pending","accepted","uncertain","refused"))}
                val job=o["job"]?.takeIf {it!=JsonNull}?.jsonPrimitive?.content?.also {ImportJobId(it)}
                val playlist=o["playlistId"]?.let {p->p.jsonPrimitive.let {require(!it.isString&&kind in setOf("source","playlist-sync"));it.long.also {n->require(n>0)}}}
                IntakeReceipt(op,kind,phase,job,o["sessionId"]?.jsonPrimitive?.content?.also {ImportJobId(it)},o["candidateId"]?.jsonPrimitive?.content?.also {require(it.isNotBlank()&&it.length<=1024)},o["decisionId"]?.jsonPrimitive?.content?.also {ImportJobId(it)},playlist)
            }.also {r->require(r.zipWithNext().all {it.first.operation<it.second.operation})}}.let {LinkedHashMap(it)}
        }catch(_:Exception){rejected=true;records=linkedMapOf()}
    }
    private fun save(next:Map<String,List<IntakeReceipt>>) {
        check(!rejected)
        if(file!=null){
            file.parentFile?.mkdirs()
            val body=buildJsonObject {put("version",1);put("owners",buildJsonObject {next.forEach {(owner,rows)->put(owner,buildJsonArray {rows.forEach {r->add(buildJsonObject {put("operation",r.operation);put("kind",r.kind);put("phase",r.phase);r.job?.let {put("job",it)};r.sessionId?.let {put("sessionId",it)};r.candidateId?.let {put("candidateId",it)};r.decisionId?.let {put("decisionId",it)};r.playlistId?.let {put("playlistId",it)}})}})}})}
            val temp=File(file.parentFile,file.name+".pending")
            try {temp.outputStream().use {it.write(body.toString().toByteArray());it.fd.sync()};Files.move(temp.toPath(),file.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)} finally {temp.delete()}
        }
        records=LinkedHashMap(next)
    }
    @Synchronized fun entries(endpoint:String,account:String):List<IntakeReceipt> {load();check(!rejected);return records[key(endpoint,account)].orEmpty()}
    @Synchronized fun begin(endpoint:String,account:String,kind:String,sessionId:String?=null,candidateId:String?=null,decisionId:String?=null,job:String?=null,playlistId:Long?=null):IntakeReceipt {
        load();check(!rejected);job?.let {ImportJobId(it)}
        require(playlistId==null||kind in setOf("source","playlist-sync")&&playlistId>0)
        val k=key(endpoint,account);val previous=records[k].orEmpty()
        val receipt=IntakeReceipt((previous.lastOrNull()?.operation ?: 0)+1,kind,"pending",job,sessionId,candidateId,decisionId,playlistId)
        save(records+(k to (previous+receipt)));return receipt
    }
    @Synchronized fun finish(endpoint:String,account:String,receipt:IntakeReceipt,phase:String,job:String?=null,decisionId:String?=receipt.decisionId) {
        load();check(!rejected);job?.let {ImportJobId(it)}
        val k=key(endpoint,account);val previous=records[k].orEmpty();require(previous.any {it.operation==receipt.operation})
        save(records+(k to previous.map {if(it.operation==receipt.operation)it.copy(phase=phase,job=job,decisionId=decisionId) else it}))
    }
    /** Source-sync failure may settle only the same unresolved durable intent.
     * Sibling acquisition journals intentionally retain their existing finish contract. */
    @Synchronized fun failSourceSync(endpoint:String,account:String,receipt:IntakeReceipt,refused:Boolean) {
        require(receipt.kind=="playlist-sync")
        load();check(!rejected)
        val k=key(endpoint,account);val previous=records[k].orEmpty()
        val current=previous.singleOrNull {it.operation==receipt.operation} ?: return
        if(current.copy(phase=receipt.phase)!=receipt||current.phase !in setOf("pending","uncertain"))return
        save(records+(k to previous.map {if(it===current)it.copy(phase=if(refused)"refused"else "uncertain")else it}))
    }
}
