package com.soundq.designsystem

/** Measured lazy item bounds, in viewport pixels. No fixed row-height assumption. */
data class QueueItemBounds(val occurrence:String,val index:Int,val top:Float,val height:Float)
data class QueueMoveIntent(val occurrence:String,val originalOrder:List<String>,val to:Int) {
    fun insertedOrder():List<String> = originalOrder.toMutableList().apply {add(to,removeAt(indexOf(occurrence)))}
}
/** Pure preview math and one-shot completion token, consumed by the mounted queue. */
internal class QueueDragSession(val order:List<String>,val occurrence:String,val startPointer:Float,val startTop:Float,val height:Float) {
    val from=order.indexOf(occurrence)
    var target=from;private set
    var pointer=startPointer;private set
    var scroll=0f;private set
    val translation:Float get()=pointer-startPointer+scroll
    fun scrolled(pixels:Float) {if(!finished&&!settling)scroll+=pixels}
    fun follow(y:Float,bounds:List<QueueItemBounds>) {
        if(finished||settling)return
        pointer=y
        val center=startTop+height/2+translation
        var next=from
        for(item in bounds.sortedBy {it.index}) {
            if(item.index==from)continue
            if(center>item.top+item.height/2)next=maxOf(next,item.index)
            else if(item.index<from){next=item.index;break}
        }
        target=next
    }
    fun neighborOffset(index:Int):Float = when {
        target>from && index in (from+1)..target -> -height
        target<from && index in target until from -> height
        else -> 0f
    }
    var settling=false;private set
    private var finished=false
    fun release():QueueMoveIntent? {if(!finished)settling=true;return null}
    fun edgeStep(top:Float,bottom:Float,zone:Float,pixelsPerMs:Float,elapsedMs:Float):Float {
        if(finished||settling||zone<=0f)return 0f
        val direction=when {pointer<top+zone -> -(1f-(pointer-top)/zone);pointer>bottom-zone -> 1f-(bottom-pointer)/zone;else -> 0f}
        return direction.coerceIn(-1f,1f)*pixelsPerMs*elapsedMs
    }
    fun cancel() {finished=true;settling=false}
    fun complete():QueueMoveIntent? {
        if(!settling||finished)return null
        finished=true;settling=false
        return intent().takeIf {target!=from}
    }
    fun intent()=QueueMoveIntent(occurrence,order,target)
    fun settleOffset(bounds:List<QueueItemBounds>):Float {
        val destination=bounds.firstOrNull {it.index==target} ?: return pointer-startPointer
        return (if(target>from)destination.top+destination.height-height else destination.top)-startTop
    }
}
