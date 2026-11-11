package com.soundq.android.playback.system

/** Resume belongs to the transport generation at loss, never just to a later focus gain. */
internal class InterruptionPolicy(private val playing:()->Boolean,private val pause:()->Unit,private val resume:()->Unit) {
    private var generation=0L
    private var pending:Long?=null
    fun command() {generation++;pending=null}
    fun loss(transient:Boolean) {
        val mayResume=pending==generation || (pending==null && playing())
        pending=null
        pause()
        if(transient && mayResume)pending=generation
    }
    fun gain() {
        val accepted=pending==generation
        pending=null
        if(accepted)resume()
    }
}
