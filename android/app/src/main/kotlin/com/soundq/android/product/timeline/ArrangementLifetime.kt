package com.soundq.android.product.timeline

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.setValue

/** Pending intent only. Losing foreground permanently retires captured admissions,
 * not an accepted player's background playback or an uncertain write's ownership. */
internal class ArrangementLifetime(private val lifecycle:Lifecycle):LifecycleEventObserver {
    private var generation by mutableLongStateOf(0L)
    private var closed=false
    private var resumed=lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    @Synchronized override fun onStateChanged(source:LifecycleOwner,event:Lifecycle.Event) {
        val next=lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
        if(resumed&&!next)generation++
        resumed=next
    }
    @Synchronized fun capture(valid:()->Boolean):()->Boolean {
        val held=generation
        val eligible=resumed&&!closed
        return {synchronized(this){eligible&&!closed&&resumed&&held==generation&&valid()}}
    }
    @Synchronized fun close(){closed=true;generation++}
}
