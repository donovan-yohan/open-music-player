package com.soundq.android.data.imports

import com.soundq.android.data.*
import kotlinx.serialization.json.*

internal object ImportJson {
    private fun string(body:JsonObject,key:String):String {
        val scalar=body[key] as? JsonPrimitive ?: error("scalar")
        require(scalar.isString)
        return scalar.content
    }
    private inline fun <T> decode(block:()->T):T = try {block()}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
    private fun status(body:JsonObject)=ImportStatus.entries.single {it.wire==string(body,"status")}
    fun acknowledgement(body:JsonObject):ImportAcknowledgement=decode {
        ImportAcknowledgement(ImportJobId(string(body,"job_id")),status(body))
    }
    fun job(body:JsonObject,expected:ImportJobId?=null):ImportJob=decode {
        val id=ImportJobId(string(body,"job_id"));require(expected==null || id==expected)
        val progress=body.getValue("progress") as JsonPrimitive
        require(!progress.isString && progress.intOrNull in 0..100)
        val rawTrack=body["track_id"]
        val track=if(rawTrack==null || rawTrack==JsonNull)null else {
            val n=rawTrack as JsonPrimitive;require(!n.isString);TrackId(n.long)
        }
        val provider=string(body,"source_type");require(provider in listOf("youtube","soundcloud"))
        java.time.Instant.parse(string(body,"created_at"))
        for(key in listOf("started_at","completed_at"))if(body[key]!=null && body[key]!=JsonNull)java.time.Instant.parse(string(body,key))
        // Source URL and server error deliberately never enter presentation or diagnostic models.
        ImportJob(id,status(body),progress.int,track,provider)
    }
    fun recent(body:JsonObject):List<ImportJob> = decode {
        val jobs=body.getValue("jobs").jsonArray.map {job(it.jsonObject)}
        require(jobs.map {it.id}.distinct().size==jobs.size)
        jobs
    }
}
