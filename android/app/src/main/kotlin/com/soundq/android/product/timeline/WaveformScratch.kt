package com.soundq.android.product.timeline

/** UI receives only a captured transient control adapter. No source/transport ownership. */
internal data class WaveformScratch(
    val armed:Boolean,
    val ready:Boolean,
    val sourceRate:Double=1.0,
    val status:String="Ready",
    val arm:()->Unit,
    val begin:(Long)->Boolean,
    val move:(Double,Long)->Unit,
    val finish:(Long,Boolean)->Unit,
    val audibleSourceMs:()->Double?,
)
