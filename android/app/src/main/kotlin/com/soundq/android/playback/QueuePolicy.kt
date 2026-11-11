package com.soundq.android.playback

/** Pure policies over a snapshot of Media3's authoritative timeline, never another queue owner. */
object QueuePolicy {
    const val MAX_CONTEXT_TRACKS = 500
    // Legacy eager/mix and individual durable-page bound, not the legal collection size.
    const val MAX_LOGICAL_TRACKS = 100_000
    const val MAX_METADATA_BYTES = 64L*1024*1024
    const val CONTEXT_LIMIT_MESSAGE = "Playback metadata exceeds the safe storage budget. The existing queue is unchanged."
    fun acceptsContext(count: Int): Boolean = count in 1..MAX_LOGICAL_TRACKS
    fun acceptsAppend(count:Int,added:Int):Boolean = count>=0 && added>=0 && count.toLong()+added<=MAX_LOGICAL_TRACKS
    /** Conservative JSON/UTF-8 upper bound, including the saved row and page envelope.
     * Six bytes per UTF-16 unit covers JSON control escaping and all UTF-8 sequences. */
    fun metadataBytes(occurrence:String,title:String,artist:String):Long =
        512L+6L*(occurrence.length.toLong()+title.length+artist.length)
    fun manualInsert(origins: List<Boolean>, current: Int): Int {
        var i=(current+1).coerceIn(0,origins.size)
        while(i<origins.size && origins[i]) i++
        return i
    }
    fun carriedManual(origins: List<Boolean>, current: Int, keepQueued: Boolean = true): List<Int> = if(keepQueued)origins.indices.filter {it>current && origins[it]}else emptyList()
}
