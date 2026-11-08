package com.soundq.android.data.timeline

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class TimelineFadeSafetyTest {
    private fun sources()=listOf("out","in").map {TimelineSource(it,7,"Duplicate",10000,QueueSegment.Context)}
    @Test fun trimCannotMoveAnAuthoredFadeEndpointOrDiscardItsEnvelope() {
        val clips=sequentialTimeline(sources()).mapIndexed {i,c->if(i==0)c.copy(fadeOutMs=2000) else c.copy(globalStartMs=8000,fadeInMs=2000)}
        var disk="""{"version":1,"document":${Json.encodeToString(TimelineDocument(4,clips))}}"""
        val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
        val d=owner.state.value.document;val before=disk
        assertFalse("Trimming a faded endpoint must not silently retime its envelope",owner.commit(TimelineEdit(d.revision,d.clips.first(),EditKind.TrimOut,9000)))
        assertEquals(d,owner.state.value.document);assertEquals(before,disk)
    }
    @Test fun malformedEnvelopeRefusesDraftWithoutReplacingBytes() {
        val c=sequentialTimeline(sources()).first().copy(fadeInMs=6000,fadeOutMs=6000)
        var disk="""{"version":1,"document":${Json.encodeToString(TimelineDocument(4,listOf(c)))}}"""
        val before=disk;val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
        assertFalse(owner.state.value.writable);assertEquals(before,disk)
    }
}
