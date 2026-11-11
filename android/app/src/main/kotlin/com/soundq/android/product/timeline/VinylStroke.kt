package com.soundq.android.product.timeline

/** Pointer units only, never a playback clock or a source-position owner.
 * The captured scale is source seconds per physical pixel, fixed for one grab. */
internal class VinylStroke(private val sourceSecondsPerPixel:Double) {
    init {require(sourceSecondsPerPixel.isFinite()&&sourceSecondsPerPixel>0)}
    private var active=false
    private var lastX=0f
    private var lastNanos=0L
    fun begin(x:Float,eventNanos:Long) {
        require(x.isFinite()&&eventNanos>0)
        lastX=x;lastNanos=eventNanos;active=true
    }
    fun move(x:Float,eventNanos:Long):Double? {
        if(!active||!x.isFinite()||eventNanos<=lastNanos)return null
        val rate=(x.toDouble()-lastX.toDouble())*sourceSecondsPerPixel*1_000_000_000.0/(eventNanos-lastNanos).toDouble()
        lastX=x;lastNanos=eventNanos
        return rate.coerceIn(-8.0,8.0)
    }
    fun end(){active=false}
}
