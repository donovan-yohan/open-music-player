package com.soundq.android.product.timeline

import android.os.SystemClock
import com.soundq.android.playback.ArrangementIdentity
import com.soundq.android.playback.ControllerProjection
import com.soundq.android.playback.ScratchLease

/** One contact may wait for admission, but its last Move and terminal are bounded.
 * A late Begin reply can only be cancelled, never revive a released pointer. */
internal class LiveScratchContact(
    private val controller:ControllerProjection,
    private val identity:ArrangementIdentity,
    private val occurrence:String,
    private val current:()->Boolean,
) {
    private var lease:ScratchLease?=null
    private var latest:Pair<Double,Long>?=null
    private var ended=false
    private var beganAt=0L
    private var lastInput=0L
    fun begin(eventNanos:Long):Boolean {
        if(beganAt!=0L||!current())return false
        beganAt=eventNanos
        lastInput=eventNanos
        controller.beginScratch(identity,occurrence,eventNanos) {accepted->
            if(accepted==null){ended=true;latest=null;return@beginScratch}
            if(ended||!current()) {
                controller.cancelScratch(accepted,maxOf(SystemClock.uptimeMillis()*1_000_000L,lastInput+1))
            } else {
                lease=accepted
                latest?.let {(rate,time)->controller.moveScratch(accepted,rate,time)}
                latest=null
            }
        }
        return true
    }
    fun move(rate:Double,eventNanos:Long) {
        if(ended||!rate.isFinite()||rate !in -8.0..8.0||eventNanos<=lastInput)return
        lastInput=eventNanos
        if(!current()){finish(eventNanos,true);return}
        val accepted=lease
        if(accepted==null)latest=rate to eventNanos else controller.moveScratch(accepted,rate,eventNanos)
    }
    fun finish(eventNanos:Long,cancel:Boolean) {
        if(ended)return
        ended=true;latest=null
        val accepted=lease ?: return
        lease=null
        // Up can share a millisecond with Move; coroutine cancellation has no
        // newer physical event. Terminal ordering is causal, not another Move.
        val time=maxOf(eventNanos,lastInput+1)
        if(cancel||!current())controller.cancelScratch(accepted,time) else controller.endScratch(accepted,time)
    }
    fun retire()=finish(SystemClock.uptimeMillis()*1_000_000L,true)
}
