package com.soundq.designsystem

import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Test

class SwipeQueueGeometryTest {
    @Test fun queueOnlyRevealsOneRowHeightSquare() {
        val geometry=swipeQueueGeometry(72.dp,likeEnabled=false)
        assertEquals(72.dp,geometry.cellSize)
        assertEquals(72.dp,geometry.reveal)
        assertEquals(120.dp,geometry.arm)
        assertEquals(144.dp,geometry.maximum)
    }

    @Test fun likeAndQueueRevealTwoTouchingRowHeightSquares() {
        val geometry=swipeQueueGeometry(72.dp,likeEnabled=true)
        assertEquals(72.dp,geometry.cellSize)
        assertEquals(144.dp,geometry.reveal)
        assertEquals(192.dp,geometry.arm)
        assertEquals(216.dp,geometry.maximum)
    }

    @Test fun measuredHeightControlsBothCellsAndReveal() {
        val geometry=swipeQueueGeometry(80.dp,likeEnabled=true)
        assertEquals(80.dp,geometry.cellSize)
        assertEquals(160.dp,geometry.reveal)
        assertEquals(208.dp,geometry.arm)
        assertEquals(232.dp,geometry.maximum)
    }

    @Test fun armExtraUsesRowHeightBetweenMinimumAndMaximum() {
        val geometry=swipeQueueGeometry(120.dp,likeEnabled=true)
        assertEquals(240.dp,geometry.reveal)
        assertEquals(300.dp,geometry.arm)
        assertEquals(324.dp,geometry.maximum)
    }

    @Test fun tallRowsClampArmExtraWithoutShrinkingCells() {
        val geometry=swipeQueueGeometry(200.dp,likeEnabled=true)
        assertEquals(200.dp,geometry.cellSize)
        assertEquals(400.dp,geometry.reveal)
        assertEquals(480.dp,geometry.arm)
        assertEquals(504.dp,geometry.maximum)
    }

    @Test fun shortcutFitsAtArmPlusRemainingFrontBoundary() {
        val geometry=swipeQueueGeometry(72.dp,likeEnabled=true)
        assertFalse(geometry.fits(239.5.dp))
        assertTrue(geometry.fits(240.dp))
        assertTrue(geometry.fits(240.5.dp))
    }

    @Test fun narrowRowsKeepExplicitRevealGeometryWithoutLoweringArm() {
        val geometry=swipeQueueGeometry(72.dp,likeEnabled=true)
        assertFalse(geometry.fits(200.dp))
        assertEquals(144.dp,geometry.reveal)
        assertEquals(192.dp,geometry.arm)
        assertEquals(216.dp,geometry.maximum)
    }

    @Test fun hidingLikeChangesShortcutFitWithoutChangingCellSize() {
        val queueOnly=swipeQueueGeometry(72.dp,likeEnabled=false)
        val withLike=swipeQueueGeometry(72.dp,likeEnabled=true)
        assertEquals(queueOnly.cellSize,withLike.cellSize)
        assertFalse(queueOnly.fits(167.5.dp))
        assertTrue(queueOnly.fits(168.dp))
        assertTrue(queueOnly.fits(200.dp))
        assertFalse(withLike.fits(200.dp))
    }
}
