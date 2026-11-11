package com.soundq.android.playback

/** Pure policies over a snapshot of Media3's authoritative timeline, never another queue owner. */
object QueuePolicy {
    const val MAX_CONTEXT_TRACKS = 500
    const val CONTEXT_LIMIT_MESSAGE = "This playlist is too large to play. Playback supports up to 500 tracks."
    fun acceptsContext(count: Int): Boolean = count in 1..MAX_CONTEXT_TRACKS
    fun manualInsert(origins: List<Boolean>, current: Int): Int {
        var i=(current+1).coerceIn(0,origins.size)
        while(i<origins.size && origins[i]) i++
        return i
    }
    fun carriedManual(origins: List<Boolean>, current: Int, keepQueued: Boolean = true): List<Int> = if(keepQueued)origins.indices.filter {it>current && origins[it]}else emptyList()
}
