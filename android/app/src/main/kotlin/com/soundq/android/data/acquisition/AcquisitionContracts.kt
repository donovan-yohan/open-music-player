package com.soundq.android.data.acquisition

import com.soundq.android.data.*
import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
import kotlinx.serialization.json.*
import java.time.Instant

class ServerImportItem internal constructor(val id:String,val position:Int,val title:String,val status:String,val progress:Int,val retry:Boolean,val remove:Boolean,val job:ImportJobId?)
class ServerImportQueue internal constructor(val items:List<ServerImportItem>)
class PlaylistImportItem internal constructor(val id:Long,val title:String,val status:String,val track:TrackId?,val job:ImportJobId?,val error:String?=null)
class PlaylistImportProgress internal constructor(val id:ImportJobId,val playlistId:Long,val status:String,val total:Int,val imported:Int,val queued:Int,val failed:Int,val skipped:Int,val items:List<PlaylistImportItem>,val sourceTitle:String?=null,val error:String?=null)
/** Producer errors can contain downloader diagnostics. Expose facts, never raw logs or URLs. */
private fun playlistError(raw:String):String=when {
    raw.contains("private",true)->"Private video"
    raw.contains("duplicate",true)->"Duplicate source entry"
    raw.contains("disabled",true)->"Download processing is disabled"
    raw.contains("unavailable",true)->"Source entry unavailable"
    raw.contains("copyright",true)->"Unavailable due to copyright"
    raw.contains("age",true)&&raw.contains("restrict",true)->"Age-restricted video"
    raw.contains("region",true)||raw.contains("country",true)->"Unavailable in the server's region"
    else->"The server could not import this source."
}
class ResearchProgress internal constructor(val id:ImportJobId,val status:String,val retrySafe:Boolean,val attempts:Int,val maxAttempts:Int,val revision:Int,val revisionId:String,val stage:String,val degradation:String?,val retryable:Boolean,val candidates:List<SourceCandidate>,val recommended:String?) {
    val active get()=status in setOf("queued","running","cancel_requested")
    val canRetry get()=status=="degraded"&&retrySafe&&attempts<maxAttempts&&retryable
}
class ResearchReview internal constructor(val decision:String,val candidate:String)
object AcquisitionJson {
    fun string(o:JsonObject,k:String)=o.getValue(k).jsonPrimitive.let {require(it.isString);it.content}
    fun number(o:JsonObject,k:String)=o.getValue(k).jsonPrimitive.let {require(!it.isString);it.long}
    fun bool(o:JsonObject,k:String)=o.getValue(k).jsonPrimitive.let {require(!it.isString);it.boolean}
    private fun id(s:String)=ImportJobId(s)
    private fun optional(o:JsonObject,k:String)=o[k]?.takeIf {it!=JsonNull}
    inline fun <T> parse(block:()->T):T=try {block()}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
    fun queue(o:JsonObject):ServerImportQueue=parse {
        val body=o["queue"]?.jsonObject ?: o
        Instant.parse(string(body,"updatedAt"));number(body,"currentPosition").also {require(it>=0)}
        val rows=body.getValue("items").jsonArray.map {e->val r=e.jsonObject
            val key=string(r,"queueItemId");require(key.isNotBlank()&&key.length<=128&&Regex("[A-Za-z0-9_-]+").matches(key))
            val position=number(r,"position");require(position in 0..Int.MAX_VALUE)
            val state=string(r,"playbackState");require(state in setOf("pending","queued","downloading","processing","uploading","playable","failed"))
            val progress=number(r,"progress");require(progress in 0..100)
            ServerImportItem(key,position.toInt(),optional(r,"title")?.jsonPrimitive?.let {require(it.isString);it.content} ?: "Server import",state,progress.toInt(),bool(r,"canRetry"),bool(r,"canRemove"),optional(r,"downloadJobId")?.let {id(it.jsonPrimitive.let {p->require(p.isString);p.content})})
        }
        require(rows.map {it.id}.distinct().size==rows.size)
        require(rows.map {it.position}==rows.indices.toList())
        ServerImportQueue(rows)
    }
    fun playlist(o:JsonObject,expected:ImportJobId?=null):PlaylistImportProgress=parse {
        val job=id(string(o,"id"));require(expected==null||job==expected)
        val playlist=number(o,"playlistId");require(playlist>0)
        val status=string(o,"status");require(status in setOf("resolving","importing","complete","partial_failure","failed","cancelled"))
        val counts=listOf("totalItems","importedItems","queuedItems","failedItems","skippedItems").map {number(o,it).also {n->require(n in 0..1000)}.toInt()}
        require(counts.drop(1).sum()<=counts[0])
        val items=o.getValue("items").jsonArray.map {e->val r=e.jsonObject
            val itemId=number(r,"id");require(itemId>0)
            val state=string(r,"status");require(state in setOf("pending","queued","imported","failed","skipped_duplicate"))
            PlaylistImportItem(itemId,if("title" in r)string(r,"title") else "Playlist item #$itemId",state,optional(r,"trackId")?.let {p->require(!p.jsonPrimitive.isString);TrackId(p.jsonPrimitive.long)},optional(r,"downloadJobId")?.let {p->id(p.jsonPrimitive.let {require(it.isString);it.content})},if("error" in r)playlistError(string(r,"error"))else null)
        }
        require(items.size==counts[0]&&items.map {it.id}.distinct().size==items.size)
        PlaylistImportProgress(job,playlist,status,counts[0],counts[1],counts[2],counts[3],counts[4],items,if("sourceTitle" in o)string(o,"sourceTitle")else null,if("error" in o)playlistError(string(o,"error"))else null)
    }
    fun research(o:JsonObject,expected:ImportJobId?=null):ResearchProgress=parse {
        val job=o.getValue("job").jsonObject;val key=id(string(job,"id"));require(expected==null||key==expected)
        val status=string(job,"status");require(status in setOf("queued","running","cancel_requested","completed","degraded","cancelled"))
        val attempts=number(job,"attempts");val max=number(job,"maxAttempts");require(attempts in 0..10&&max in 1..10)
        val version=number(job,"latestRevision");require(version>0&&version<=Int.MAX_VALUE)
        val latest=string(job,"latestRevisionId");id(latest)
        val revisions=o.getValue("revisions").jsonArray.map {it.jsonObject};require(revisions.isNotEmpty())
        require(revisions.map {number(it,"number")}.distinct().size==revisions.size)
        revisions.forEach {require(string(it,"jobId")==key.value&&number(it,"number") in 1..version);id(string(it,"id"))}
        val revision=revisions.single {string(it,"id")==latest&&number(it,"number")==version}
        val payload=revision.getValue("payload").jsonObject;require(string(payload,"schemaVersion")=="omp.research.revision.v1")
        val stage=string(payload,"stage");require(stage in setOf("baseline","direct_judge","deep_agent"))
        val candidates=payload.getValue("candidates").jsonArray.map {DiscoveryJson.candidate(it.jsonObject)}
        require(candidates.size<=25&&candidates.map {it.id}.distinct().size==candidates.size)
        val recommendations=payload.getValue("recommendations").jsonArray.map {it.jsonObject}
        require(recommendations.size<=10)
        recommendations.forEachIndexed {index,r->require(number(r,"rank")==index+1L&&candidates.any {it.id==string(r,"candidateId")})}
        val recommended=recommendations.firstOrNull()?.let {string(it,"candidateId")}
        val degradation=optional(o,"latestDegradation")?.jsonObject
        val code=degradation?.let {string(it,"code").also {c->require(c in setOf("model_disabled","model_unavailable","budget_exhausted","transient","timeout","runner_terminal","validation_rejected","safety_rejected","enhancement_rejected","lease_expired","no_candidates"))}}
        ResearchProgress(key,status,bool(job,"retrySafe"),attempts.toInt(),max.toInt(),version.toInt(),latest,stage,code,degradation?.let {bool(it,"retryable")} ?: false,candidates,recommended)
    }
    fun review(o:JsonObject,candidate:SourceCandidate,action:String):ResearchReview=parse {
        val decision=string(o,"id");id(decision)
        require(string(o,"selectedCandidateId")==candidate.id&&string(o,"action")==action)
        val selected=DiscoveryJson.candidate(o.getValue("selectedCandidate").jsonObject)
        require(selected.id==candidate.id&&selected.source.url==candidate.source.url)
        ResearchReview(decision,candidate.id)
    }
}
