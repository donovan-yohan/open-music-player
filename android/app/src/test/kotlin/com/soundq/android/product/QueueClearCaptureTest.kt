package com.soundq.android.product

import com.soundq.android.playback.*
import org.junit.Assert.*
import org.junit.Test

class QueueClearCaptureTest {
    private val a1=QueueOccurrence("a-first",7,"A","Artist",false,12000)
    private val b=QueueOccurrence("b",8,"B","Artist",false,8000)
    private val a2=a1.copy(occurrenceId="a-second")
    private val paused=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,title="A",artist="Artist",
        queue=listOf(a1,b,a2),selectedOccurrence=a2.occurrenceId,positionMs=4300,durationMs=12000,
        accountEpoch=4,sessionIdentity="service",sourceQueueIncarnation="queue",selectionIncarnation=9,queueRevision=3)

    @Test fun cancelDoesNotIssueAnyCommandAndConfirmedAbaClearsOnce() {
        var writes=0
        QueueClearCapture(paused) // Dismissal/cancellation drops the capture only.
        assertEquals(0,writes)
        val capture=QueueClearCapture(paused)
        assertTrue(capture.confirm(paused,{true}){writes++})
        assertFalse(capture.confirm(paused,{true}){writes++})
        assertEquals(1,writes)
        assertEquals("a-second",paused.selectedOccurrence)
        assertEquals(4300L,paused.positionMs)
        assertFalse(paused.isPlaying)
    }
    @Test fun ticksAreNotQueueChangesButAbaReorderAndSelectionAre() {
        var writes=0
        assertTrue(QueueClearCapture(paused).confirm(paused.copy(positionMs=4500),{true}){writes++})
        listOf(paused.copy(queueRevision=5),paused.copy(selectionIncarnation=11),
            paused.copy(queue=listOf(a2,b,a1)),paused.copy(selectedOccurrence=a1.occurrenceId)).forEach {changed->
            assertFalse(QueueClearCapture(paused).confirm(changed,{true}){writes++})
        }
        assertEquals(1,writes)
    }
    @Test fun accountServiceQueueSourceDisposalAndConnectionChangesRefuse() {
        var writes=0
        listOf(paused.copy(accountEpoch=6),paused.copy(sessionIdentity="replacement"),
            paused.copy(sourceQueueIncarnation="replacement"),paused.copy(source=PlaybackSource.Arrangement),
            paused.copy(connection=PlaybackProjection.Connection.Disconnected)).forEach {changed->
            assertFalse(QueueClearCapture(paused).confirm(changed,{true}){writes++})
        }
        val capture=QueueClearCapture(paused)
        assertFalse(capture.confirm(paused,{false}){writes++})
        assertFalse(capture.confirm(paused,{true}){writes++})
        assertFalse(QueueClearCapture(paused.copy(queue=emptyList())).confirm(paused.copy(queue=emptyList()),{true}){writes++})
        assertEquals(0,writes)
    }
}
