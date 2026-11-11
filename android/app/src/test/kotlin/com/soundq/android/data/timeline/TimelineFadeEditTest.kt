package com.soundq.android.data.timeline

import org.junit.Assert.*
import org.junit.Test

/** Reflection is only an API-discovery tracer. The JSON-to-plan test is the behavioral predecessor RED. */
class TimelineFadeEditTest {
    @Test fun explicitPairAcceptancePersistsBothEndpointFadesThroughTheExistingOwner() {
        var disk:String?=null
        val owner=TimelineOwner({disk},{disk=it})
        val sources=listOf("out","in").map {TimelineSource(it,7,"Duplicate",10000,QueueSegment.Context)}
        owner.observe(sources)
        var d=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,8000)))
        d=owner.state.value.document
        val type=runCatching {Class.forName("com.soundq.android.data.timeline.TimelineFadeEdit")}.getOrNull()
        val edit=type?.constructors?.firstOrNull {it.parameterCount==4}?.newInstance(d.revision,d.clips[0],d.clips[1],2000L)
        val method=owner.javaClass.methods.firstOrNull {it.name=="commit"&&it.parameterTypes.firstOrNull()==type}
        val accepted=if(edit==null||method==null)false else method.invoke(owner,edit,{true}) as Boolean
        assertTrue("Existing durable owner must accept the explicitly captured occurrence pair",accepted)
        assertTrue(disk!!.contains("\"version\":2"))
        val restored=TimelineOwner({disk},{error("Readback must not write")});restored.observe(sources)
        val raw=kotlinx.serialization.json.Json.encodeToString(TimelineDocument.serializer(),restored.state.value.document)
        assertTrue(raw.contains("\"fadeOutMs\":2000"));assertTrue(raw.contains("\"fadeInMs\":2000"))
    }
}
