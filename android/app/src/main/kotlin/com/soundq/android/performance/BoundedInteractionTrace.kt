package com.soundq.android.performance

internal data class FrameSample(val totalNs:Long,val inputNs:Long,val layoutNs:Long,val drawNs:Long,val deadlineNs:Long,val droppedCallbacks:Int)
internal data class InputSample(val dispatchNs:Long,val eventAgeNs:Long)
internal class BoundedInteractionTrace(val capacity:Int=600) {
    val frames=ArrayList<FrameSample>();val inputs=ArrayList<InputSample>()
    var discardedFrames=0;private set
    var discardedInputs=0;private set
    init {require(capacity in 1..3600)}
    @Synchronized fun frame(sample:FrameSample) {if(frames.size<capacity)frames.add(sample) else discardedFrames++}
    @Synchronized fun input(sample:InputSample) {if(inputs.size<capacity)inputs.add(sample) else discardedInputs++}
}
