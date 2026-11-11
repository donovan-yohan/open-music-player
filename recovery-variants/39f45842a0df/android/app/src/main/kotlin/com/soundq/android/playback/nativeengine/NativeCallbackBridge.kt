package com.soundq.android.playback.nativeengine

/** JNI is private to the dedicated control owner. Never call this object from UI/IO workers. */
internal object NativeCallbackBridge {
    init { System.loadLibrary("soundq_callback_android") }

    @JvmStatic external fun open(): Long
    @JvmStatic external fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long): Boolean
    // Operation 9 is explicit paused output recovery, not Play or source release.
    @JvmStatic external fun control(handle: Long, operation: Int, deck: Int, value: Double, eventNanos: Long): Boolean
    // Six longs/clip: globalStart, sourceIn, sourceOut, fadeIn, fadeOut,
    // full-source catalog duration (sourceOut==sourceDuration only), otherwise zero.
    @JvmStatic external fun prepareSchedule(handle: Long, revision: Long, paths: Array<String>, values: LongArray): Boolean
    // V2 retains six longs/clip and adds eight doubles/clip. Plain clips are
    // all-zero; explicit preserved clips carry the shared absolute BPM law.
    @JvmStatic external fun prepareScheduleV2(handle: Long, revision: Long, paths: Array<String>, values: LongArray, tempo: DoubleArray): Boolean
    @JvmStatic external fun arrangement(handle: Long, operation: Int, value: Long): Boolean
    @JvmStatic external fun state(handle: Long): String
    @JvmStatic external fun scratch(handle: Long, operation: Int, instance: Long, gesture: Long, eventNanos: Long, rate: Double): Boolean
    @JvmStatic external fun sync(handle: Long, incoming: Long, reference: Long, beats: Int, referenceBpm: Double, referenceAnchorMs: Double, referenceOriginMs: Double, incomingBpm: Double, incomingAnchorMs: Double, incomingOriginMs: Double): Boolean
    @JvmStatic external fun liveTempo(handle: Long, revision: Long, instance: Long, tag: Long, sourceBpm: Double, targetBpm: Double, glideFrames: Long, reservation: Long): Boolean
    @JvmStatic external fun reserveTempo(handle: Long, revision: Long, instance: Long, sourceBpm: Double, originBpm: Double): Long
    @JvmStatic external fun restoreTempo(handle: Long, reservation: Long, tag: Long): Boolean
    @JvmStatic external fun releaseTempo(handle: Long, reservation: Long): Boolean
    @JvmStatic external fun close(handle: Long): Boolean
}

/** The only substituted boundary in Player tests, together with encoded source IO. */
internal interface NativeCallbackCalls {
    fun open(): Long
    fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long): Boolean
    fun control(handle: Long, operation: Int, deck: Int, value: Double, eventNanos: Long): Boolean
    fun prepareSchedule(handle: Long, revision: Long, paths: Array<String>, values: LongArray): Boolean = false
    fun prepareScheduleV2(handle: Long, revision: Long, paths: Array<String>, values: LongArray, tempo: DoubleArray): Boolean = false
    fun arrangement(handle: Long, operation: Int, value: Long): Boolean = false
    fun state(handle: Long): String
    fun scratch(handle: Long, operation: Int, instance: Long, gesture: Long, eventNanos: Long, rate: Double): Boolean = false
    fun sync(handle: Long, incoming: Long, reference: Long, beats: Int, referenceBpm: Double, referenceAnchorMs: Double, referenceOriginMs: Double, incomingBpm: Double, incomingAnchorMs: Double, incomingOriginMs: Double): Boolean = false
    fun liveTempo(handle: Long, revision: Long, instance: Long, tag: Long, sourceBpm: Double, targetBpm: Double, glideFrames: Long, reservation: Long): Boolean = false
    fun reserveTempo(handle: Long, revision: Long, instance: Long, sourceBpm: Double, originBpm: Double): Long = 0
    fun restoreTempo(handle: Long, reservation: Long, tag: Long): Boolean = false
    fun releaseTempo(handle: Long, reservation: Long): Boolean = false
    fun close(handle: Long): Boolean
}

internal object JniNativeCallbackCalls : NativeCallbackCalls {
    override fun open() = NativeCallbackBridge.open()
    override fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long) =
        NativeCallbackBridge.load(handle, deck, path, identity, generation, positionMs)
    override fun control(handle: Long, operation: Int, deck: Int, value: Double, eventNanos: Long) =
        NativeCallbackBridge.control(handle, operation, deck, value, eventNanos)
    override fun prepareSchedule(handle: Long, revision: Long, paths: Array<String>, values: LongArray) = NativeCallbackBridge.prepareSchedule(handle, revision, paths, values)
    override fun prepareScheduleV2(handle: Long, revision: Long, paths: Array<String>, values: LongArray, tempo: DoubleArray) = NativeCallbackBridge.prepareScheduleV2(handle, revision, paths, values, tempo)
    override fun arrangement(handle: Long, operation: Int, value: Long) = NativeCallbackBridge.arrangement(handle, operation, value)
    override fun state(handle: Long) = NativeCallbackBridge.state(handle)
    override fun scratch(handle: Long, operation: Int, instance: Long, gesture: Long, eventNanos: Long, rate: Double) = NativeCallbackBridge.scratch(handle, operation, instance, gesture, eventNanos, rate)
    override fun sync(handle: Long, incoming: Long, reference: Long, beats: Int, referenceBpm: Double, referenceAnchorMs: Double, referenceOriginMs: Double, incomingBpm: Double, incomingAnchorMs: Double, incomingOriginMs: Double) = NativeCallbackBridge.sync(handle, incoming, reference, beats, referenceBpm, referenceAnchorMs, referenceOriginMs, incomingBpm, incomingAnchorMs, incomingOriginMs)
    override fun liveTempo(handle: Long, revision: Long, instance: Long, tag: Long, sourceBpm: Double, targetBpm: Double, glideFrames: Long, reservation: Long) = NativeCallbackBridge.liveTempo(handle, revision, instance, tag, sourceBpm, targetBpm, glideFrames, reservation)
    override fun reserveTempo(handle: Long, revision: Long, instance: Long, sourceBpm: Double, originBpm: Double) = NativeCallbackBridge.reserveTempo(handle, revision, instance, sourceBpm, originBpm)
    override fun restoreTempo(handle: Long, reservation: Long, tag: Long) = NativeCallbackBridge.restoreTempo(handle, reservation, tag)
    override fun releaseTempo(handle: Long, reservation: Long) = NativeCallbackBridge.releaseTempo(handle, reservation)
    override fun close(handle: Long) = NativeCallbackBridge.close(handle)
}
