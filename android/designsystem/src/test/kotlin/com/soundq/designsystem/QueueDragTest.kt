package com.soundq.designsystem

import org.junit.Assert.*
import org.junit.Test

class QueueDragTest {
    private val order = listOf("a", "b", "c", "d")
    private val measured = listOf(QueueItemBounds("a",0,0f,60f), QueueItemBounds("b",1,60f,120f), QueueItemBounds("c",2,180f,80f), QueueItemBounds("d",3,260f,100f))
    @Test fun consumedScrollKeepsLiftedRowUnderHeldPointerAndUpdatesInsertion() {
        val drag=QueueDragSession(order,"a",30f,0f,60f)
        drag.follow(100f,measured);drag.scrolled(150f)
        drag.follow(100f,measured)
        assertEquals(220f,drag.translation,0f)
        assertEquals(2,drag.target)
    }
    @Test fun variableHeightInsertionCrossesNeighborMidpointNotNearestCenter() {
        val drag=QueueDragSession(order,"a",30f,0f,60f)
        drag.follow(100f,measured)
        assertEquals(0,drag.target)
    }
    @Test fun heldEdgeFramesAdvanceWithoutAnotherPointerEvent() {
        val drag=QueueDragSession(order,"a",30f,0f,60f)
        drag.follow(400f,measured)
        assertEquals(8.96f,drag.edgeStep(0f,360f,48f,0.56f,16f),0.001f)
        assertEquals(8.96f,drag.edgeStep(0f,360f,48f,0.56f,16f),0.001f)
        drag.release()
        assertEquals(0f,drag.edgeStep(0f,360f,48f,0.56f,16f),0f)
    }
    @Test fun cancellationDuringSettlePermanentlyRetiresCompletion() {
        val drag = QueueDragSession(order,"a",30f,0f,60f)
        drag.follow(240f,measured);drag.release();drag.cancel()
        assertNull(drag.complete());drag.release();assertNull(drag.complete())
    }
    @Test fun reversalToOriginNeverCommits() {
        val drag = QueueDragSession(order,"a",30f,0f,60f)
        drag.follow(240f,measured);drag.follow(30f,measured);drag.release()
        assertNull(drag.complete())
    }
    @Test fun releaseWaitsForActualCompletionAndPublishesExactlyOnce() {
        val drag = QueueDragSession(order, "a", 30f, 0f, 60f)
        drag.follow(240f, measured)
        assertNull(drag.release())
        assertEquals(QueueMoveIntent("a",order,2),drag.complete())
        assertNull(drag.complete())
    }
    @Test fun insertionUsesMeasuredHeightWithoutChangingAuthoritativeOrder() {
        val drag = QueueDragSession(order, "a", 30f, 0f, 60f)
        drag.follow(240f, measured)
        assertEquals(2, drag.target)
        assertEquals(-60f, drag.neighborOffset(1), 0f)
        assertEquals(-60f, drag.neighborOffset(2), 0f)
        assertEquals(0f, drag.neighborOffset(3), 0f)
        assertEquals(listOf("a","b","c","d"),order)
        assertEquals(listOf("b","c","a","d"),drag.intent().insertedOrder())
        assertEquals(200f,drag.settleOffset(measured),0f)
    }
}
