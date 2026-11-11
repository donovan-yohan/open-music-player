package com.soundq.designsystem

import androidx.compose.ui.unit.Dp
import soundq.design.generated.SoundQQuickQueueRoles as Q

/** Fixed tray geometry; overtravel never changes the action cells or settled reveal. */
data class SwipeQueueGeometry(val cellSize:Dp,val reveal:Dp,val arm:Dp,val maximum:Dp) {
    fun fits(width:Dp):Boolean=width>=arm+Q.remainingFrontMin
}

fun swipeQueueGeometry(rowHeight:Dp,likeEnabled:Boolean):SwipeQueueGeometry {
    val reveal=rowHeight*(if(likeEnabled)2 else 1)
    val arm=reveal+(rowHeight*Q.armExtraRowHeightRatio).coerceIn(Q.armExtraMin,Q.armExtraMax)
    return SwipeQueueGeometry(cellSize=rowHeight,reveal=reveal,arm=arm,maximum=arm+Q.overtravel)
}
