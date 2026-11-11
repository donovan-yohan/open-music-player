package com.soundq.android.playback.mix

/** Single Exo loader-thread ownership. None of these calls runs in an audio callback. */
internal object NativeMix {
    init {System.getProperty("soundq.mix.library")?.let(System::load) ?: System.loadLibrary("soundq_mix_android")}
    external fun open(paths:Array<String>,clips:LongArray,gains:FloatArray,events:LongArray,eventGains:FloatArray):Long
    external fun render(handle:Long,startFrame:Long,frameCount:Int,bytes:ByteArray)
    external fun probe(path:String,expectedFrames:Long,expectedPreSkip:Long)
    external fun close(handle:Long)
    /** Synchronous stereo48k windows. Clip fields are exact frames, never milliseconds. */
    external fun renderPcmBlock(originFrame:Long,frameCount:Int,clips:LongArray,windows:Array<FloatArray>,gains:FloatArray,bytes:ByteArray)
}
