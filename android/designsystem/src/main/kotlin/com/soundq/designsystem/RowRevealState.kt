package com.soundq.designsystem

import androidx.compose.runtime.*

/** Ephemeral presentation only. No row identity, account, queue or mutation truth. */
class RowRevealOwner {
    private var active:RowRevealState?=null
    internal fun take(row:RowRevealState) {if(active!==row){active?.close();active=row}}
    internal fun release(row:RowRevealState) {if(active===row)active=null}
    fun outside(x:Float,y:Float) {active?.let {if(!it.contains(x,y))close()}}
    fun close() {val old=active;active=null;old?.close()}
}

enum class RowRevealPhase { Closed, Dragging, Settling, Open }
class RowRevealState(private val owner:RowRevealOwner) {
    var phase by mutableStateOf(RowRevealPhase.Closed); private set
    var offset by mutableFloatStateOf(0f); private set
    var revision by mutableLongStateOf(0L); private set
    var targetOpen by mutableStateOf(false); private set
    private var originOpen=false
    private var origin=0f
    private var alive=true
    private var armAt=160f
    private var lastLeft=false
    var armed by mutableStateOf(false); private set
    var contains:(Float,Float)->Boolean={_,_->false}
    val actionable get()=alive&&phase==RowRevealPhase.Open
    fun begin(displayed:Float,armDistance:Float=160f):Boolean {
        if(!alive)return false
        originOpen=targetOpen;origin=displayed;offset=displayed;armed=false;armAt=armDistance;lastLeft=false
        owner.take(this);revision++;phase=RowRevealPhase.Dragging
        return true
    }
    /** True only on a new leftward threshold crossing. Caller owns platform feedback. */
    fun follow(displacement:Float,maximum:Float):Boolean {
        if(!alive||phase!=RowRevealPhase.Dragging)return false
        val previous=offset
        offset=(origin+displacement).coerceIn(-maximum,0f)
        if(offset!=previous)lastLeft=offset<previous
        val crossing=!armed&&offset<previous&&-offset>=armAt
        armed=if(-offset<armAt)false else armed||crossing
        return crossing
    }
    /** One release effect, independent from visual settle completion. */
    fun end(reveal:Float,commit:Float,velocity:Float,reverseVelocity:Float,cancel:Boolean=false):Boolean {
        if(!alive||phase!=RowRevealPhase.Dragging)return false
        val queue=armed&&!cancel
        request(if(queue)false else if(cancel)originOpen else -offset>=reveal*commit&&lastLeft&&velocity<=reverseVelocity)
        return queue
    }
    var settleStart:Float?=null; private set
    fun request(open:Boolean) {
        if(!alive)return
        settleStart=if(phase==RowRevealPhase.Dragging)offset else null
        if(open)owner.take(this) else owner.release(this)
        armed=false;targetOpen=open;revision++;phase=RowRevealPhase.Settling
    }
    fun complete(ticket:Long,reveal:Float):Boolean {
        if(!alive||revision!=ticket||phase!=RowRevealPhase.Settling)return false
        offset=if(targetOpen)-reveal else 0f
        phase=if(targetOpen)RowRevealPhase.Open else RowRevealPhase.Closed
        return true
    }
    /** Captured callbacks from a prior opening cannot act after close/open ABA. */
    fun admit(ticket:Long):Boolean {if(!actionable||revision!=ticket)return false;close();return true}
    fun frontTap():Boolean {if(!alive)return false;if(phase==RowRevealPhase.Closed)return true;close();return false}
    fun close() {request(false)}
    fun dispose() {owner.release(this);alive=false;revision++;targetOpen=false;offset=0f;phase=RowRevealPhase.Closed}
}
