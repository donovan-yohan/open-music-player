package com.soundq.android.product

import android.content.Context
import android.widget.Toast

/** Root-owned delivery receipt only: never changes the canonical error or transport.
 * Revisions come from accepted controller error events, not cursor/preparation polling.
 * Consume ineligible failures too, so foreground/panel return cannot replay them. */
internal class PlayerFailureFeedback(private val context:Context):AutoCloseable {
    private var observedRevision:Long?=null
    private var owner:Any?=null
    private var toast:Toast?=null
    private var closed=false

    fun observe(currentOwner:Any?,revision:Long,message:String?,eligible:Boolean) {
        if(closed)return
        if(owner!=currentOwner||!eligible||message==null) {
            toast?.cancel();toast=null
        }
        owner=currentOwner
        val previous=observedRevision
        if(previous==null||revision>previous)observedRevision=revision
        // First read is a baseline, not a new user failure; reopening must stay silent.
        if(previous==null||revision<=previous||currentOwner==null||!eligible||message==null)return
        toast?.cancel()
        toast=Toast.makeText(context,message,Toast.LENGTH_LONG).also {it.show()}
    }
    override fun close() {closed=true;toast?.cancel();toast=null;owner=null}
}
