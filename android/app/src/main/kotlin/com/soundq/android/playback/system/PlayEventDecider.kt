package com.soundq.android.playback.system

/** Flutter-compatible raw-position milestone. This is deliberately not elapsed listening time. */
internal class PlayEventDecider {
    private var occurrence:String?=null
    private var track:Long?=null
    private var recorded=false
    fun observePosition(occurrence:String,track:Long,positionMs:Long):Long? {
        if(this.track!=track){this.track=track;recorded=false}
        this.occurrence=occurrence
        return if(positionMs>=30_000)record() else null
    }
    fun completed(occurrence:String,track:Long):Long? =
        if(this.occurrence==occurrence && this.track==track)record() else null
    private fun record():Long? {if(recorded)return null;recorded=true;return track}
    fun reset(){occurrence=null;track=null;recorded=false}
}
