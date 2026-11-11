package com.soundq.android.playback

import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.Executor

/** Main-looper future wrapper. Disconnect is terminal for this exact connection, not reconnection. */
internal class ControllerConnection<C>(private val future:ListenableFuture<C>, executor:Executor, private val connected:(C)->Boolean,
    private val attach:(C)->Unit,private val detach:(C)->Unit,private val release:()->Unit,private val publish:(PlaybackProjection.Connection)->Unit):AutoCloseable {
    private var active=true
    private var terminal:C?=null
    private var attached:C?=null
    private var released=false
    init {
        future.addListener({
            if(active)try {
                val c=future.get()
                if(terminal===c || !connected(c)) {
                    terminal=c;publish(PlaybackProjection.Connection.Disconnected);releaseOnce()
                } else {attached=c;attach(c);if(accepts(c))publish(PlaybackProjection.Connection.Connected)}
            }catch(_:Exception){if(active&&terminal==null)publish(PlaybackProjection.Connection.Unavailable)}
        },executor)
    }
    fun disconnected(c:C){if(active){terminal=c;attached?.let(detach);attached=null;publish(PlaybackProjection.Connection.Disconnected)}}
    fun accepts(c:C):Boolean=active&&terminal!==c&&attached===c&&connected(c)
    private fun releaseOnce(){if(!released){released=true;release()}}
    override fun close(){if(!active)return;active=false;attached?.let(detach);attached=null;releaseOnce()}
}
