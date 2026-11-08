package com.soundq.android.performance

import android.os.*
import android.view.*
import org.json.*
import java.io.File

/** Explicit debug/test opt-in only. Stops after 60s; numeric samples contain no media/account data. */
class WindowInteractionRecorder(private val window:Window):AutoCloseable {
    private val handler=Handler(Looper.getMainLooper())
    private var trace:BoundedInteractionTrace?=null
    private var startedNs=0L
    private var elapsedNs=0L
    private val stop=Runnable {stop()}
    private val listener=Window.OnFrameMetricsAvailableListener {_,metrics,dropped ->
        if(elapsedNs==0L)trace?.frame(FrameSample(metrics.getMetric(FrameMetrics.TOTAL_DURATION),metrics.getMetric(FrameMetrics.INPUT_HANDLING_DURATION),
            metrics.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION),metrics.getMetric(FrameMetrics.DRAW_DURATION),
            if(Build.VERSION.SDK_INT>=31)metrics.getMetric(FrameMetrics.DEADLINE) else -1,dropped))
    }
    fun start() {
        if(trace!=null)return
        trace=BoundedInteractionTrace();startedNs=SystemClock.elapsedRealtimeNanos();elapsedNs=0
        window.addOnFrameMetricsAvailableListener(listener,handler);handler.postDelayed(stop,60_000)
    }
    fun input(eventTimeMs:Long,dispatchStartedNs:Long,dispatchEndedNs:Long) {
        if(elapsedNs!=0L)return
        trace?.input(InputSample((dispatchEndedNs-dispatchStartedNs).coerceAtLeast(0),
            (SystemClock.uptimeMillis()-eventTimeMs).coerceAtLeast(0)*1_000_000))
    }
    fun stop() {
        if(trace==null || elapsedNs!=0L)return
        elapsedNs=SystemClock.elapsedRealtimeNanos()-startedNs
        window.removeOnFrameMetricsAvailableListener(listener);handler.removeCallbacks(stop)
    }
    /** Called after stop on main. File output is explicit and private, never a per-frame write. */
    fun write(file:File) {
        check(Looper.myLooper()==Looper.getMainLooper());stop()
        val observed=trace ?: error("Recorder was not started")
        val result=JSONObject().put("schema",1).put("durationNs",elapsedNs).put("capacity",observed.capacity)
            .put("discardedFrames",observed.discardedFrames).put("discardedInputs",observed.discardedInputs)
            .put("frameColumns",JSONArray(listOf("totalNs","inputHandlingNs","layoutMeasureNs","drawNs","deadlineNs","droppedCallbacks")))
            .put("inputColumns",JSONArray(listOf("dispatchNs","eventAgeNs")))
            .put("frames",JSONArray(observed.frames.map {JSONArray(listOf(it.totalNs,it.inputNs,it.layoutNs,it.drawNs,it.deadlineNs,it.droppedCallbacks))}))
            .put("inputs",JSONArray(observed.inputs.map {JSONArray(listOf(it.dispatchNs,it.eventAgeNs))}))
        file.writeText(result.toString())
    }
    override fun close(){stop();trace=null}
}
