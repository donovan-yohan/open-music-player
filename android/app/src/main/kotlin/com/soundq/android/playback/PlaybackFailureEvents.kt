package com.soundq.android.playback

/** Monotonic feedback receipts, not playback state. Nothing here can alter readiness,
 * source selection, retained errors or transport. Equivalent native exceptions may
 * arrive every output poll; a canonical null error after Retry re-arms the episode. */
internal class PlaybackFailureEvents {
    var revision:Long=0
        private set
    private var observedAudioFailure:Pair<Int,String?>?=null
    fun audio(code:Int?,message:String?) {
        val failure=code?.let {it to message}
        if(failure!=null&&failure!=observedAudioFailure)revision++
        observedAudioFailure=failure
    }
    fun contextRefused() {revision++}
}
