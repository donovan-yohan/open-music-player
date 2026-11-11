package com.soundq.android.playback.system

import android.content.*
import android.media.*
import android.os.*
import androidx.media3.common.Player

/** One focus request for the service player. No telephony permission or second audio output. */
internal class SystemAudioInterruption(context:Context,private val player:Player,private val current:()->Boolean,private val invalidatePreparation:()->Unit):AutoCloseable {
    private val app=context.applicationContext
    private val audio=app.getSystemService(AudioManager::class.java)
    private val handler=Handler(Looper.getMainLooper())
    private var closed=false
    private var focused=false
    private var internal=false
    private val policy=InterruptionPolicy({player.isPlaying},{invalidatePreparation();internal=true;try {player.pause()}finally {internal=false}},{if(!closed&&current())player.play()})
    private val request=AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
        .setWillPauseWhenDucked(true).setAcceptsDelayedFocusGain(false)
        .setOnAudioFocusChangeListener({change -> if(!closed)when(change) {
            AudioManager.AUDIOFOCUS_GAIN->{focused=true;policy.gain()}
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK->{focused=false;policy.loss(true)}
            AudioManager.AUDIOFOCUS_LOSS->{focused=false;policy.loss(false)}
        }},handler).build()
    private val listener=object:Player.Listener {
        override fun onPlayWhenReadyChanged(playWhenReady:Boolean,reason:Int) {
            if(closed||internal)return
            if(playWhenReady)reconcileFocus() else abandon()
        }
        override fun onPlaybackStateChanged(playbackState:Int) {
            if(closed||internal)return
            when(playbackState) {
                Player.STATE_ENDED,Player.STATE_IDLE->abandon()
                // Terminal states retain play intent. Requalify before deferred native motion,
                // even when a backward seek does not emit another playWhenReady edge.
                Player.STATE_READY,Player.STATE_BUFFERING->if(player.playWhenReady)reconcileFocus()
            }
        }
    }
    private val noisy=object:BroadcastReceiver(){override fun onReceive(context:Context,intent:Intent){if(intent.action==AudioManager.ACTION_AUDIO_BECOMING_NOISY)policy.loss(false)}}
    private val routes=object:AudioDeviceCallback(){override fun onAudioDevicesRemoved(removed:Array<out AudioDeviceInfo>) {
        // Removal never selects speaker and auto-resumes. Even a concurrent noisy callback is safe.
        if(removed.any {it.isSink && it.type in setOf(AudioDeviceInfo.TYPE_WIRED_HEADPHONES,AudioDeviceInfo.TYPE_WIRED_HEADSET,AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,AudioDeviceInfo.TYPE_BLUETOOTH_SCO,AudioDeviceInfo.TYPE_BLE_HEADSET,AudioDeviceInfo.TYPE_USB_HEADSET)})policy.loss(false)
    }}
    init {
        player.addListener(listener)
        if(Build.VERSION.SDK_INT>=33)app.registerReceiver(noisy,IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),Context.RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") app.registerReceiver(noisy,IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        audio.registerAudioDeviceCallback(routes,handler)
    }
    /** Any explicit controller transport/mutation supersedes an interruption's resume token. */
    fun command(){policy.command()}
    private fun reconcileFocus() {
        if(!current() || (!focused && audio.requestAudioFocus(request)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED))policy.loss(false)
        else focused=true
    }
    private fun abandon(){if(focused){focused=false;audio.abandonAudioFocusRequest(request)}}
    override fun close(){if(closed)return;closed=true;policy.command();player.removeListener(listener);app.unregisterReceiver(noisy);audio.unregisterAudioDeviceCallback(routes);abandon()}
}
