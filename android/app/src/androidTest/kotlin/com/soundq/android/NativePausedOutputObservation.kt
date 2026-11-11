package com.soundq.android

import androidx.media3.common.Player
import kotlinx.coroutines.Job
import org.json.JSONObject

/** Read-only, ordinary-source native counterpart of pendingOperationAcks. 1 means
 * NOT observed settled, not a fabricated JNI ACK count. The session-facing player
 * remains the authority for every queue/selection/cursor assertion in the callers.
 * Pinned to NativeCallbackPlayer/Owner and callback_host's diagnostic schema. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal fun nativePausedOutputPending(output:Player):Int {
    check(android.os.Looper.myLooper()==android.os.Looper.getMainLooper())
    check(output.applicationLooper==android.os.Looper.getMainLooper())
    check(output.javaClass.name=="com.soundq.android.playback.nativeengine.NativeCallbackPlayer")
    fun field(owner:Any,name:String):Any? = owner.javaClass.getDeclaredField(name).apply {isAccessible=true}.get(owner)
    fun flag(name:String)=field(output,name) as Boolean
    fun current(name:String)=output.javaClass.getDeclaredMethod(name).apply {isAccessible=true}.invoke(output) as Boolean
    val owner=checkNotNull(field(output,"owner"))
    val epoch=field(output,"epoch") as Long
    val transport=field(output,"transportRevision") as Long
    val seek=field(output,"seekRevision") as Long
    val observation=field(owner,"observationRevision") as Long
    val tail=field(output,"tail") as Job?
    val item=output.currentMediaItem
    val loaded=flag("selectedLoaded")
    val position=field(output,"position") as Long
    fun stable()=field(output,"epoch")==epoch && field(output,"transportRevision")==transport &&
        field(output,"seekRevision")==seek && field(owner,"observationRevision")==observation &&
        field(output,"tail")===tail && output.currentMediaItem===item && flag("selectedLoaded")==loaded &&
        field(output,"position")==position
    fun drained():Boolean {
        val lifetime=field(output,"lifetime") as kotlinx.coroutines.CoroutineScope
        val lifetimeJob=checkNotNull(lifetime.coroutineContext[Job])
        return lifetimeJob.isActive && lifetimeJob.children.none { !it.isCompleted } &&
            (tail==null || tail.isCompleted) && field(output,"pending")==null &&
            (field(output,"preparing") as java.util.concurrent.atomic.AtomicInteger).get()==0
    }
    fun paused()= !flag("released") && !flag("intent") && !flag("acknowledgedPlaying") &&
        !flag("outputUnavailable") && field(output,"error")==null && field(output,"outputRecoveryRevision")==null &&
        field(output,"desiredSeek")==null && field(output,"submittedSeek")==null &&
        !output.playWhenReady && !output.isPlaying && output.playerError==null
    fun notReady():Int { nativePauseSamples.remove(output);return 1 }
    // These callers observe ordinary queues only. Do not infer synthetic graph
    // receipts from deck zero or let an arrangement masquerade as unloaded output.
    check(field(output,"arrangement")==null) {"Unsupported native paused arrangement observation"}
    if(!paused() || !drained())return notReady()
    if(loaded) {
        if(item==null || !current("assignmentCurrent") || output.playbackState!=Player.STATE_READY)return notReady()
    } else if(output.playbackState!=Player.STATE_IDLE || item!=null && !current("currentScope"))return notReady()
    // nativeDiagnostics reads Owner's volatile cache. It does NOT poll JNI, pump
    // transport, publish player state, register a listener or submit any command.
    val text=output.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true}.invoke(output) as String
    if(text=="{}")return notReady() // Owner has not published its first poll.
    val root=JSONObject(text)
    if(!root.getBoolean("coherent") || root.getInt("error")!=0 || root.getLong("scheduleRevision")!=0L ||
        root.getBoolean("scheduleRetiring"))return notReady()
    val decks=root.getJSONArray("decks")
    check(decks.length()>0) {"Unsupported empty native deck diagnostics"}
    if(loaded) {
        val deck=decks.getJSONObject(0)
        if(deck.getLong("identity")!=epoch || deck.getLong("generation")!=epoch ||
            !deck.getBoolean("ready") || deck.getBoolean("preparing") || deck.getBoolean("playing") ||
            deck.getInt("error")!=0 || deck.getLong("positionMs")!=position || output.currentPosition!=position)return notReady()
    } else {
        // Empty / never-prepared Jam queues are valid without acquiring a source,
        // but prior output must have its actual unload/decoder-release receipt.
        for(i in 0 until decks.length()) {
            val deck=decks.getJSONObject(i)
            if(deck.getLong("identity")!=0L || deck.getBoolean("ready") || deck.getBoolean("preparing") ||
                deck.getBoolean("playing") || deck.getInt("openDecoders")!=0 || deck.getInt("error")!=0)return notReady()
        }
    }
    if(!stable() || !paused() || !drained() || loaded && !current("assignmentCurrent"))return notReady()
    val frame=root.getLong("renderedFrames")
    if(frame<=0)return notReady()
    val before=nativePauseSamples[output]
    // dispatchIntent/seek/volume are lifetime children, NOT tail. After all of
    // them finish, require two subsequent coherent callback-frame advances in
    // this exact source/transport/recovery epoch. An old paused cache, including
    // a poll that straddled control admission, cannot acknowledge new transport.
    val same=before!=null && before.epoch==epoch && before.transport==transport && before.seek==seek &&
        before.observation==observation && before.tail?.get()===tail && before.item===item &&
        before.loaded==loaded && before.position==position
    val advances=if(same && frame>before.frame)before.advances+1 else if(same && frame==before.frame)before.advances else 0
    // Hold no strong reference back through a completed transport coroutine.
    nativePauseSamples[output]=NativePauseSample(epoch,transport,seek,observation,tail?.let {java.lang.ref.WeakReference(it)},item,loaded,position,frame,minOf(advances,2))
    return if(advances>=2)0 else 1
}

private data class NativePauseSample(
    val epoch:Long,val transport:Long,val seek:Long,val observation:Long,val tail:java.lang.ref.WeakReference<Job>?,val item:Any?,
    val loaded:Boolean,val position:Long,val frame:Long,val advances:Int,
)
// Accessed only on main; weak keys do not retain a retired service/player.
private val nativePauseSamples=java.util.WeakHashMap<Player,NativePauseSample>()
