package com.soundq.android.playback.nativeengine

import com.soundq.android.data.deviceaudio.*
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/** One ordinary native assignment's journal consumer. All store calls run on repository IO.
 * The atomic intent fence is callable before scheduling IO/native seek. Native revision is
 * adopted only by a source-cursor acknowledgement, never by command admission or old polls.
 */
internal class NativeListeningBinding(
    private val store:DeviceListeningStore, private var source:SourceCapture,
    private val occurrence:UUID, private val generation:Long, val deck:Int,
    val resumeMs:Long, private val durationMs:Long, private val current:()->Boolean,
) {
    private val fence=AtomicLong(0)
    private var observedFence=0L
    private var traversal=store.beginTraversal(source,occurrence,generation,1,0,durationMs)
    private var nativeRevision=0L
    private var sequence=0L
    private var consumed=0L
    private var previous:NativeCallbackDeck?=null
    private var played=false
    private var started=false
    private var completed=false
    private var checkpoint=-1L
    @Volatile private var seeking=false
    @Volatile private var retired=false
    fun stamp()=fence.get()
    fun fenceIntent()=fence.incrementAndGet()
    fun adoptIntent(stamp:Long,playing:Boolean) {if(!retired&&fence.get()==stamp&&!seeking){observedFence=stamp;previous=null;if(playing)started=false}}
    fun fenceSeek():Long {seeking=true;return fence.incrementAndGet()}
    fun fenceRetirement() {retired=true;fence.incrementAndGet()}
    fun consumedCount()=consumed
    fun beginSeek(identity:Long,baseline:Long):Boolean {
        if(retired||!current())return false
        if(completed) {
            val next=when(val key=source.owner.key){
                is HistoryKey.Device->store.captureSource(source.access,key.id)
                is HistoryKey.Server->store.bindServerContent(source.access,key,source.owner.revision,durationMs)
            } ?: return false
            source=next;traversal=store.beginTraversal(next,occurrence,generation,identity,baseline,durationMs)
            completed=false;played=false;started=false;checkpoint=-1
        }else traversal=traversal?.let {store.beginSeek(it,identity,baseline)}
        observedFence=fence.get();sequence=0;previous=null;consumed=baseline
        return traversal!=null
    }
    fun acknowledgeSeek(revision:Long,position:Long) {
        if(retired||!current()||revision<=nativeRevision)return
        nativeRevision=revision;previous=null;seeking=false
        traversal?.let {if(played&&durationMs>600000)store.checkpoint(SourcePositionCheckpoint(it,++sequence,position.coerceIn(0,durationMs)))}
    }
    fun observe(value:NativeCallbackDeck,atEpochMs:Long,stamp:Long=stamp(),allowNatural:Boolean=true) {
        if(retired||completed||!current()||seeking||stamp!=fence.get()||observedFence!=stamp||value.identity!=generation||value.generation!=generation||value.error!=0||!value.ready||value.preparing||value.scratching||value.traversalRevision<=0)return
        if(nativeRevision==0L)nativeRevision=value.traversalRevision
        if(value.traversalRevision!=nativeRevision)return
        val t=traversal ?: return
        val old=previous
        val advanced=old!=null&&old.traversalRevision==value.traversalRevision&&old.playing&&value.positionMs>old.positionMs&&value.rate>0
        if(advanced&&!started) {
            if(store.played(SuccessfulPlaybackReceipt(t,++sequence,atEpochMs))==Mutation.REFUSED)return
            played=true;started=true
        }
        val end=value.naturalEnd
        if(allowNatural&&played&&end!=null&&end.generation==generation&&end.identity==generation&&end.traversalRevision==nativeRevision&&end.count>consumed) {
            if(store.complete(QualifiedNaturalEnd(t,++sequence,occurrence,generation,t.seekIdentity,end.count))!=Mutation.REFUSED){completed=true;consumed=end.count}
        } else if(played&&(checkpoint<0||kotlin.math.abs(value.positionMs-checkpoint)>=5000||old?.playing==true&&!value.playing)) {
            if(store.checkpoint(SourcePositionCheckpoint(t,++sequence,value.positionMs.coerceIn(0,durationMs)))!=Mutation.REFUSED)checkpoint=value.positionMs
        }
        if(!value.playing)started=false
        previous=value
    }
    /** Final already-acknowledged cursor, not another successful-play or completion event. */
    fun finish(value:NativeCallbackDeck?) {
        val t=traversal ?: return
        if(!completed&&played&&value!=null&&value.identity==generation&&value.generation==generation&&value.error==0&&value.ready&&!seeking&&value.traversalRevision==nativeRevision)
            store.checkpoint(SourcePositionCheckpoint(t,++sequence,value.positionMs.coerceIn(0,durationMs)))
        store.retireTraversal(t)
    }
}
