package com.soundq.android.data.timeline

/** One ephemeral transaction. Cancellation never writes and finish consumes ownership exactly once. */
class TimelineGesture(private val validate:(TimelineEdit)->EditDecision,private val submit:(TimelineEdit)->Unit) {
    var preview:TimelineEdit?=null;private set
    var decision=EditDecision(true);private set
    private var original:TimelineEdit?=null
    val active:Boolean get()=original!=null
    fun begin(revision:Long,clip:TimelineClip,kind:EditKind) {original=TimelineEdit(revision,clip,kind,when(kind){EditKind.Placement->clip.globalStartMs;EditKind.TrimIn->clip.sourceInMs;EditKind.TrimOut->clip.sourceOutMs})}
    fun update(value:Long) {original?.copy(valueMs=value)?.let {preview=it;decision=validate(it)}}
    fun cancel() {original=null;preview=null;decision=EditDecision(true)}
    fun finish() {val edit=preview;val accepted=decision.accepted;cancel();if(edit!=null&&accepted)submit(edit)}
}
