package com.soundq.android.data.acquisition

import com.soundq.android.data.*
import com.soundq.android.data.imports.ImportJobId
import kotlinx.serialization.json.*
import java.time.Instant

class ResearchEvent(val sequence:Long,val kind:String)
class ResearchEvents(val after:Long,val rows:List<ResearchEvent>)
fun researchEvents(body:JsonObject,id:ImportJobId,after:Long):ResearchEvents=AcquisitionJson.parse {
    require(AcquisitionJson.number(body,"afterSequence")==after&&AcquisitionJson.number(body,"limit")==50L)
    var previous=after
    val rows=body.getValue("events").jsonArray.map {e->val r=e.jsonObject
        require(AcquisitionJson.string(r,"jobId")==id.value)
        val sequence=AcquisitionJson.number(r,"sequence");require(sequence>previous);previous=sequence
        val kind=AcquisitionJson.string(r,"kind");require(kind in setOf("created","revision_appended","claimed","lease_renewed","lease_recovered","degraded","cancel_requested","cancelled","retried","completed","reviewed","runner_terminal"))
        Instant.parse(AcquisitionJson.string(r,"createdAt"));ResearchEvent(sequence,kind)
    }
    require(rows.size<=50);ResearchEvents(after,rows)
}
