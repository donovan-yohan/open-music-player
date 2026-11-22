package com.soundq.android.product.discovery

import android.content.Context
import android.widget.Toast
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.data.catalog.RecordingMbid
import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.ImportSource
import com.soundq.android.data.imports.ImportView
import com.soundq.android.product.ProductViewModel
import kotlinx.coroutines.*

@Composable internal fun rememberDiscoveryRowActions(model:ProductViewModel,view:DiscoveryView?,root:RadarArtworkRoute,shown:Boolean):DiscoveryRowActions {
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    val context=LocalContext.current.applicationContext
    val work=rememberCoroutineScope()
    val actions=remember(model,view,root,shown,lifecycle) {DiscoveryRowActions(model,context,work,root)}
    DisposableEffect(actions) {
        fun sync()=actions.setActive(shown&&view!=null&&lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        val observer=LifecycleEventObserver {_,_->sync()}
        lifecycle.addObserver(observer);sync()
        onDispose {actions.setActive(false);lifecycle.removeObserver(observer)}
    }
    return actions
}

/** Main-owned row intents. Retiring a pending read never stops accepted playback or an entered import. */
internal class DiscoveryRowActions(private val model:ProductViewModel,private val applicationContext:Context,
    private val work:CoroutineScope,private val root:RadarArtworkRoute) {
    private class Pending(val row:Any) {var job:Job?=null}
    private var preview by mutableStateOf<Pending?>(null)
    private var resolvingAdd by mutableStateOf<Pending?>(null)
    var surface by mutableStateOf<RadarArtworkRoute?>(null)
        private set

    fun setActive(active:Boolean) {
        if(active) {if(surface==null)surface=RadarArtworkRoute(root=root)}
        else retire()
    }
    fun renew() {if(surface!=null){retire();surface=RadarArtworkRoute(root=root)}}
    private fun retire() {
        surface?.retire();surface=null
        preview?.job?.cancel();preview=null
        resolvingAdd?.job?.cancel();resolvingAdd=null
    }
    fun pending(row:Any)=preview?.row===row
    val adding get()=resolvingAdd!=null
    private fun feedback(message:String) {Toast.makeText(applicationContext,message,Toast.LENGTH_SHORT).show()}

    fun preview(view:DiscoveryView,row:Any,title:String,artist:String,current:()->Boolean,source:(()->Boolean)->ImportSource?) {
        if(!current()||!model.graph.session.remoteCurrent(view.scope)||pending(row))return
        val command=model.controller.captureContextRead(preview=true)
        if(!command()){feedback("Could not play preview");return}
        preview?.job?.cancel()
        val request=Pending(row).also {preview=it}
        // Start on Main immediately so even a cancelled parent runs matching cleanup.
        request.job=work.launch(start=CoroutineStart.UNDISPATCHED) {
            val active=coroutineContext.job
            fun valid()=active.isActive&&current()
            val watcher=launch {
                // Playback commands and repository changes may happen while no bytes arrive.
                while(valid()&&command())delay(50)
                active.cancel()
            }
            try {
                val exact=withContext(Dispatchers.IO) {
                    fun lookupCurrent()=valid()&&command()
                    if (lookupCurrent()) source(::lookupCurrent) else null
                }
                if(preview!==request||!valid()||!command())return@launch
                if (exact==null) feedback("Preview unavailable")
                else if (!model.controller.startDiscoveryPreview(view.scope,exact,title,artist,wireValid=::valid) {valid()&&command()} && valid() && command())
                    feedback("Could not play preview")
            }catch(e:CancellationException){throw e}
            catch(e:Exception){if(preview===request&&valid()&&command())feedback(
                if ((e as? com.soundq.android.data.SafeFailure)?.reason == com.soundq.android.data.SafeFailure.Reason.AudioUnavailable)
                    "Preview unavailable" else "Could not play preview")}
            finally {
                watcher.cancel()
                if(preview===request)preview=null
            }
        }
    }

    fun addSource(view:DiscoveryView,intake:ImportView,results:SourceResults,row:SourceCandidate,current:()->Boolean) {
        if(!current())return
        val choice=model.graph.discovery.sourceRowChoice(view,results,row,current) ?: return
        if(model.graph.imports.sourceSessionConsumed(choice))feedback("Search again to add another song")
        else if(!model.graph.imports.prepareDiscoverySource(intake,choice))feedback("Could not add song. Check Imports.")
    }

    fun addRecording(view:DiscoveryView,intake:ImportView,song:RadarSong,current:()->Boolean) =
        addRecording(view,intake,song,song.recording,current)

    fun addRecording(view:DiscoveryView,intake:ImportView,row:Any,recording:RecordingMbid,current:()->Boolean) {
        if(!current()||adding||model.imports.value.pending)return
        val request=Pending(row).also {resolvingAdd=it}
        request.job=work.launch(start=CoroutineStart.UNDISPATCHED) {
            val active=coroutineContext.job
            fun valid()=active.isActive&&current()
            try {
                val source=withContext(Dispatchers.IO) {if(valid())model.graph.api.recordingSource(view.scope,recording,::valid) else null}
                if(!valid()||resolvingAdd!==request)return@launch
                if(source==null)feedback("Source unavailable for import")
                // The independent route guard survives this read's successful completion.
                else if(!model.addDiscoveryLink(intake,source,current))feedback("Could not add song. Check Imports.")
            }catch(e:CancellationException){throw e}
            catch(_:Exception){if(valid())feedback("Could not add song")}
            finally {if(resolvingAdd===request)resolvingAdd=null}
        }
    }
}
