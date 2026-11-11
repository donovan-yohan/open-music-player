package com.soundq.android.playback
/** Confined to the controller application/main looper. */
internal class ConnectionLifetime(private val release: () -> Unit) : AutoCloseable {
    var active: Boolean = true
        private set
    override fun close() {
        if (!active) return
        active = false
        release()
    }
}
