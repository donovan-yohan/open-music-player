package com.soundq.android

import android.app.Instrumentation
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.timeline.TimelineDocument
import com.soundq.android.playback.AcceptedArrangement
import com.soundq.android.playback.ArrangementIdentity
import com.soundq.android.playback.withProjectedDocument
import com.soundq.android.product.ProductViewModel
import kotlinx.serialization.json.Json
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/** Test-only observation of the installed, unchanged service player. No graph/JNI mutation.
 * Play is always the caller's real Queue action; only Pause is issued here, through
 * the existing production controller, INSIDE the first source isPlaying callback.
 * Neither Compose idling nor the 500ms projection tick defines the start cursor. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class WaveformResumeObservation private constructor(
    private val model:ProductViewModel,
    private val document:TimelineDocument,
    private val requestedMs:Long,
    private val retainedIdentity:ArrangementIdentity?,
    private val label:String,
    private val controller:MediaController,
    private val session:MediaSession,
    private val native:Player,
) : AutoCloseable {
    internal data class Result(val identity:ArrangementIdentity,val pausedMs:Long)
    private data class Point(
        val event:String,val nanos:Long,val install:String?,val accepted:AcceptedArrangement?,
        val position:Long,val publicPosition:Long,val controllerPosition:Long,val projectionPosition:Long,
        val ready:Boolean,val intent:Boolean,val playing:Boolean,val outputPlaying:Boolean,
        val loaded:Boolean,val desiredSeek:Long?,val schedule:Long,val masks:Int,val pendingInfo:Boolean,
    ) {
        fun json()=JSONObject().put("event",event).put("elapsedRealtimeNanos",nanos)
            .put("install",install).put("identity",accepted?.identity.toString())
            .put("appliedNativePositionMs",position).put("sourcePlayerPositionMs",publicPosition)
            .put("controllerPositionMs",controllerPosition).put("projectionPositionMs",projectionPosition)
            .put("ready",ready).put("playWhenReady",intent).put("sourceIsPlaying",playing)
            .put("nativeAcknowledgedPlaying",outputPlaying).put("selectedLoaded",loaded)
            .put("desiredSeekMs",desiredSeek ?: JSONObject.NULL).put("nativeScheduleRevision",schedule)
            .put("controllerMasks",masks).put("controllerPendingInfo",pendingInfo)
    }
    private val done=CountDownLatch(1)
    private val failure=AtomicReference<Throwable>()
    private val timeline=ArrayList<Point>()
    private var dropped=0
    private var ready:Point?=null
    private var firstPlaying:Point?=null
    private var paused:Point?=null
    private var firstReset:Point?=null
    private var actionNanos=0L
    private var playReturnedNanos=0L
    private var validationNanos=0L
    private var readyDiagnostics:String?=null
    private var playingDiagnostics:String?=null
    private var pauseNanos=0L
    private var closed=false
    private val listener=object:Player.Listener {
        override fun onPositionDiscontinuity(oldPosition:Player.PositionInfo,newPosition:Player.PositionInfo,reason:Int) { observe("position:$reason") }
        override fun onPlaybackStateChanged(playbackState:Int) { observe("state:$playbackState") }
        override fun onPlayWhenReadyChanged(playWhenReady:Boolean,reason:Int) { observe("intent:$playWhenReady:$reason") }
        override fun onIsPlayingChanged(isPlaying:Boolean) {
            observe("source-playing:$isPlaying",pauseOnOutput=isPlaying)
        }
        override fun onEvents(player:Player,events:Player.Events) { observe("source-events") }
    }
    // No recurring main-looper work while Espresso actuates Queue Play. The
    // listener is already armed and retains READY/first-output (and pauses)
    // even if those callbacks arrive before performClick returns. Afterwards
    // the instrumentation thread requests finite read-only samples for native
    // cursor/controller ACKs that need not emit a Media3 event.
    private fun point(event:String):Point {
        check(Looper.myLooper()==Looper.getMainLooper())
        check(session.player.applicationLooper==Looper.getMainLooper())
        val accepted=session.sessionExtras.getString("acceptedArrangement")?.let {
            Json.decodeFromString<AcceptedArrangement>(it).withProjectedDocument()
        }
        val impl=field(controller,"impl")!!
        val arrangement=field(native,"arrangement")
        return Point(event,SystemClock.elapsedRealtimeNanos(),native.currentMediaItem?.mediaId,accepted,
            field(native,"position") as Long,native.currentPosition,controller.currentPosition,model.playback.value.positionMs,
            field(native,"playback")==Player.STATE_READY,native.playWhenReady,native.isPlaying,
            field(native,"acknowledgedPlaying") as Boolean,field(native,"selectedLoaded") as Boolean,
            field(native,"desiredSeek") as Long?,arrangement?.let {field(it,"revision") as Long} ?: 0L,
            (field(impl,"pendingMaskingSequencedFutureNumbers") as Collection<*>).size,field(impl,"pendingPlayerInfo")!=null)
    }
    private fun remember(p:Point) {
        // Keep the beginning AND the latest tail. Never lose first ACK/output
        // evidence on a timeout, and never grow an unbounded instrumentation Bundle.
        if(timeline.size==256){timeline.removeAt(64);dropped++}
        timeline.add(p)
    }
    private fun matches(p:Point)=p.accepted?.let {
        it.document==document && it.identity.install==p.install &&
            (retainedIdentity==null || it.identity==retainedIdentity)
    }==true
    private fun diagnostics()=native.javaClass.getDeclaredMethod("nativeDiagnostics").invoke(native) as String
    private fun observe(event:String,pauseOnOutput:Boolean=false) {
        if(closed)return
        try {
            val p=point(event)
            // Samples are retained only when native position/ACK/readiness or
            // controller acknowledgement changes; all actual callbacks remain.
            val last=timeline.lastOrNull()
            if(event!="sample" || last==null || p.copy(event=last.event,nanos=last.nanos)!=last)remember(p)
            if(actionNanos==0L)return
            if(matches(p) && p.ready && p.loaded && p.desiredSeek==null && ready==null) {
                ready=p;readyDiagnostics=diagnostics()
            }
            if(ready!=null && p.install==ready!!.install && p.ready && p.position<requestedMs-1 && firstReset==null)firstReset=p
            // This is the source/native listener, NOT optimistic controller Play.
            // Pause promptly even on wrong identity/cursor, then fail with evidence.
            if(pauseOnOutput && firstPlaying==null) {
                firstPlaying=p;playingDiagnostics=diagnostics()
                pauseNanos=SystemClock.elapsedRealtimeNanos()
                model.controller.pause()
                remember(point("production-pause-dispatched"))
            }
            val start=firstPlaying
            if(start!=null && !p.intent && !p.playing && !p.outputPlaying && p.masks==0 && !p.pendingInfo &&
                controller.isConnected && !controller.playWhenReady && !controller.isPlaying &&
                controller.currentMediaItem?.mediaId==p.install &&
                model.playback.value.arrangement?.identity==p.accepted?.identity && !model.playback.value.isPlaying &&
                abs(controller.currentPosition-p.position)<=1) {
                paused=p;done.countDown()
            }
        } catch(t:Throwable) {
            failure.compareAndSet(null,t)
            // Cleanup through the same production transport, not the raw player.
            runCatching {model.controller.pause()}.exceptionOrNull()?.let(t::addSuppressed)
            done.countDown()
        }
    }
    private fun validate():Result {
        validationNanos=SystemClock.elapsedRealtimeNanos()
        remember(point("validation-readback"))
        failure.get()?.let {throw it}
        val target=checkNotNull(ready){"No installed native READY/cursor ACK"}
        val output=checkNotNull(firstPlaying){"No source output-playing callback"}
        val end=checkNotNull(paused){"No native paused ACK/controller drain"}
        check(matches(target)&&matches(output)&&matches(end)){"Arrangement selection/document changed"}
        check(target.accepted!!.identity==output.accepted!!.identity && output.accepted.identity==end.accepted!!.identity)
        check(target.schedule>0 && target.schedule==output.schedule && output.schedule==end.schedule){"Native schedule changed"}
        check(!target.outputPlaying && abs(target.position-requestedMs)<=1 && abs(target.publicPosition-target.position)<=1) {
            "Installed paused target ACK differs: requested=$requestedMs observed=${target.position} source=${target.publicPosition}"
        }
        check(output.outputPlaying && output.playing && output.loaded && output.desiredSeek==null) {"Playing was intent, not native output ACK"}
        check(output.nanos>=target.nanos && pauseNanos>=output.nanos && end.nanos>=pauseNanos)
        // No elapsed-time subtraction from the lower bound: zero-reset must fail
        // even if a delayed observer could otherwise let playback catch up.
        val elapsedToOutput=(output.nanos-target.nanos)/1_000_000L
        check(output.position>=requestedMs-1 && output.position<=requestedMs+elapsedToOutput+100) {
            "First output cursor jump: requested=$requestedMs first=${output.position} elapsedSinceTargetAckMs=$elapsedToOutput"
        }
        val elapsedToPause=(end.nanos-output.nanos)/1_000_000L
        check(end.position>=output.position-1 && end.position<=output.position+elapsedToPause+100) {"Pause cursor not explained by measured elapsed time"}
        check(firstReset==null) {"Native cursor reset after exact target ACK: ${firstReset?.json()}"}
        check(model.timeline.value.document==document){"Accepted placement changed"}
        return Result(end.accepted.identity,end.position)
    }
    private fun evidence() {
        val summary=JSONObject().put("label",label).put("requestedStartMs",requestedMs).put("actionBoundaryNanos",actionNanos)
            .put("pauseDispatchNanos",pauseNanos).put("queuePlayReturnedNanos",playReturnedNanos).put("validationNanos",validationNanos)
            .put("retainedEvents",timeline.size).put("droppedMiddleEvents",dropped)
            .put("firstInstalledReady",ready?.json()).put("firstOutputPlaying",firstPlaying?.json()).put("nativePaused",paused?.json())
            .put("firstCursorReset",firstReset?.json())
            .put("readyToOutputMs",ready?.let {r->firstPlaying?.let {(it.nanos-r.nanos)/1_000_000.0}})
            .put("outputToPauseDispatchMs",firstPlaying?.let {(pauseNanos-it.nanos)/1_000_000.0})
            .put("latestOwnerPollAtReady",readyDiagnostics).put("latestOwnerPollAtOutput",playingDiagnostics)
        val text=buildString {
            append("\nWAVEFORM_RESUME_SUMMARY ").append(summary).append('\n')
            timeline.forEach {append("WAVEFORM_RESUME_EVENT ").append(it.json()).append('\n')}
        }
        InstrumentationRegistry.getInstrumentation().sendStatus(2,Bundle().apply {putString(Instrumentation.REPORT_KEY_STREAMRESULT,text)})
        android.util.Log.i("SoundQWaveformResume",summary.toString())
    }
    override fun close() {main {closed=true;native.removeListener(listener)}}

    companion object {
        private fun field(owner:Any,name:String):Any? {
            var type:Class<*>?=owner.javaClass
            while(type!=null) {
                val current=type
                val found=current.declaredFields.singleOrNull {it.name==name}
                if(found!=null)return found.apply {isAccessible=true}.get(owner)
                type=current.superclass
            }
            error("Unsupported pinned observation field ${owner.javaClass.name}.$name")
        }
        private fun <T> main(block:()->T):T {
            if(Looper.myLooper()==Looper.getMainLooper())return block()
            val value=AtomicReference<T>();val failure=AtomicReference<Throwable>()
            InstrumentationRegistry.getInstrumentation().runOnMainSync {try{value.set(block())}catch(t:Throwable){failure.set(t)}}
            failure.get()?.let {throw it};return value.get()
        }
        private fun session():MediaSession {
            @Suppress("UNCHECKED_CAST")
            val sessions=MediaSession::class.java.getDeclaredField("SESSION_ID_TO_SESSION_MAP").apply {isAccessible=true}.get(null) as Map<String,MediaSession>
            return sessions.values.single()
        }
        internal fun run(model:ProductViewModel,document:TimelineDocument,pausedInputMs:Long,requestedMs:Long,
                         label:String,timeoutMs:Long,retainedIdentity:ArrangementIdentity?=null,play:()->Unit):Result {
            check(Looper.myLooper()!=Looper.getMainLooper()) {"Observation waits must run on the instrumentation thread"}
            val observation=main {
                val c=field(model.controller,"controller") as MediaController
                val s=session()
                var p=s.player
                val seen=java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Player,Boolean>())
                while(p is ForwardingPlayer) {check(seen.size<16&&seen.add(p));p=p.wrappedPlayer}
                check(p.javaClass.name=="com.soundq.android.playback.nativeengine.NativeCallbackPlayer") {"Requires actual native callback output, got ${p.javaClass.name}"}
                check(p.applicationLooper==Looper.getMainLooper())
                WaveformResumeObservation(model,document,requestedMs,retainedIdentity,label,c,s,p)
            }
            var primary:Throwable?=null
            try {
                // Existing 10s paused-seek boundary, strengthened to actual native
                // and controller ACKs BEFORE the ordinary Queue Play action.
                val deadline=SystemClock.elapsedRealtimeNanos()+TimeUnit.SECONDS.toNanos(10)
                while(true) {
                    val settled=main {
                        val p=observation.point("paused-input")
                        observation.remember(p)
                        p.ready && p.loaded && !p.intent && !p.playing && !p.outputPlaying && p.desiredSeek==null &&
                            p.masks==0 && !p.pendingInfo && observation.controller.isConnected &&
                            !observation.controller.playWhenReady && !observation.controller.isPlaying &&
                            observation.controller.currentMediaItem?.mediaId==p.install &&
                            abs(p.position-pausedInputMs)<=1 && abs(p.publicPosition-pausedInputMs)<=1 && abs(p.controllerPosition-pausedInputMs)<=1
                    }
                    if(settled)break
                    check(SystemClock.elapsedRealtimeNanos()<deadline){"Paused source/controller/native cursor ACK missing: expected=$pausedInputMs"}
                    Thread.sleep(10)
                }
                main {
                    observation.native.addListener(observation.listener)
                    observation.actionNanos=SystemClock.elapsedRealtimeNanos()
                    observation.observe("armed-before-queue-play")
                }
                play()
                observation.playReturnedNanos=SystemClock.elapsedRealtimeNanos()
                val outputDeadline=SystemClock.elapsedRealtimeNanos()+TimeUnit.MILLISECONDS.toNanos(timeoutMs)
                while(observation.done.count!=0L) {
                    main {observation.observe("sample")}
                    if(observation.done.count==0L)break
                    val remaining=outputDeadline-SystemClock.elapsedRealtimeNanos()
                    check(remaining>0L){"Output callback/native pause ACK deadline (${timeoutMs}ms)"}
                    observation.done.await(minOf(remaining,TimeUnit.MILLISECONDS.toNanos(10)),TimeUnit.NANOSECONDS)
                }
                return main {observation.validate()}
            } catch(t:Throwable) {primary=t;throw t}
            finally {
                try {main {observation.evidence()}}
                catch(t:Throwable){if(primary!=null)primary.addSuppressed(t) else {primary=t;throw t}}
                finally {
                    try {observation.close()}
                    catch(t:Throwable){if(primary!=null)primary.addSuppressed(t) else throw t}
                }
            }
        }
    }
}
