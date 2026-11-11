package com.soundq.designsystem

/** One contact owns only an unsaved numeric value. Audio and persistence remain caller-owned. */
class PrecisionBpmGesture(initialBpm:Double,private val minimum:Double,private val maximum:Double,x:Double,yDp:Double) {
    private val original=initialBpm
    var bpm=initialBpm
        private set
    private var previousX=x.coerceIn(0.0,1.0)
    private var previousY=yDp
    private var active=true
    init {
        require(listOf(initialBpm,minimum,maximum,x,yDp).all {it.isFinite()})
        require(minimum>0.0&&maximum>=minimum&&initialBpm in minimum..maximum)
    }
    fun move(x:Double,yDp:Double):Double {
        if(active&&x.isFinite()&&yDp.isFinite()) {
            val nextX=x.coerceIn(0.0,1.0)
            val logRange=kotlin.math.ln(100.0)
            fun gain(at:Double)=0.2*kotlin.math.exp(-logRange*at)
            // Integrate the sensitivity along a diagonal rather than depending
            // on how frequently Android delivered pointer samples.
            val distance=nextX-previousX
            val sensitivity=if(kotlin.math.abs(distance)<1e-9)gain((previousX+nextX)/2)
                else (gain(previousX)-gain(nextX))/(logRange*distance)
            bpm=(bpm+(previousY-yDp)*sensitivity).coerceIn(minimum,maximum)
            previousX=nextX;previousY=yDp
        }
        return bpm
    }
    fun finish():Double {active=false;return bpm}
    fun cancel():Double {if(active)bpm=original;active=false;return bpm}
}
enum class BpmRelation { Below,Original,Above }
fun bpmRelation(value:Double,original:Double):BpmRelation=when {value>original->BpmRelation.Above;value<original->BpmRelation.Below;else->BpmRelation.Original}
fun precisionBpmReset(from:Double,original:Double,progress:Double):Double {
    val t=progress.coerceIn(0.0,1.0)
    return when(t){0.0->from;1.0->original;else->from+(original-from)*t*t*(3.0-2.0*t)}
}
