package com.soundq.android.data.timeline
import org.junit.Assert.*
import org.junit.Test
class TimelineGestureTest {
    @Test fun cancelRetiresAcceptedPreviewAndReleaseSubmitsExactlyOnce() {
        val owner=TimelineOwner({null},{})
        owner.observe(listOf(TimelineSource("W1",7,"Same",10000,QueueSegment.Context)))
        var writes=0
        val gesture=TimelineGesture(owner::preview){writes++;owner.commit(it)}
        val d=owner.state.value.document;val clip=d.clips.single()
        gesture.begin(d.revision,clip,EditKind.TrimIn);gesture.update(2000)
        assertTrue(gesture.decision.accepted);gesture.cancel();gesture.finish()
        assertEquals(0,writes);assertEquals(d,owner.state.value.document)
        gesture.begin(d.revision,clip,EditKind.TrimIn);gesture.update(3000);gesture.finish();gesture.finish()
        assertEquals(1,writes);assertEquals(3000L,owner.state.value.document.clips.single().sourceInMs)
    }
}
