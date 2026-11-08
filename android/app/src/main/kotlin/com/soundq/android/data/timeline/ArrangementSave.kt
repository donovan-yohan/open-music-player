package com.soundq.android.data.timeline

import com.soundq.android.data.*
import com.soundq.android.data.mix.SavedMix
import com.soundq.android.playback.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** One write, then only explicit GET recovery. Route removal never resets uncertain create. */
data class ArrangementSaveState(val busy:Boolean=false,val blocked:Boolean=false,val saved:SavedMix?=null,val message:String?=null)
class ArrangementSave(private val api:SoundQApi,private val timeline:TimelineRepository) {
    private var owner:AccountScope?=null
    private class Flight(val prior:ArrangementSaveState) {var entered=false;var used=false;var work:(()->Unit)?=null}
    private var flight:Flight?=null
    private val mutable=MutableStateFlow(ArrangementSaveState())
    val state:StateFlow<ArrangementSaveState> = mutable
    @Synchronized fun enter(scope:AccountScope) {
        if(!api.session.current(scope))return
        if(owner?.let(api.session::current)!=true){owner=scope;flight=null;mutable.value=ArrangementSaveState()}
    }
    /** Link completion before returning, including cancellation before the body ever enters. */
    fun schedule(scope:CoroutineScope,work:(()->Unit)?,dispatcher:CoroutineDispatcher=Dispatchers.IO):Job? {
        if(work==null)return null
        val token=synchronized(this){flight?.takeIf {it.work===work}} ?: return null
        return scope.launch(dispatcher){work()}.also {job->job.invokeOnCompletion {synchronized(this){
            if(flight===token&&!token.entered){token.used=true;flight=null;mutable.value=token.prior}
        }}}
    }
    private fun begin(token:Flight):Boolean = synchronized(this) {
        if(token.used||flight!==token)false else {token.used=true;token.entered=true;true}
    }
    private fun finish(token:Flight) = synchronized(this) {
        // Cleanup is reservation-owned, not conditional on stale result eligibility.
        if(flight===token){flight=null;mutable.value=mutable.value.copy(busy=false)}
    }
    @Synchronized fun save(scope:AccountScope,document:TimelineDocument,name:String,valid:()->Boolean):(() -> Unit)? {
        enter(scope)
        val state=mutable.value
        if(owner?.epoch!=scope.epoch || state.busy || state.blocked || !valid())return null
        if(document.tempoRamps.isNotEmpty()||document.playbackTempos.isNotEmpty()||document.autoBpmCrossfade){mutable.value=state.copy(message="Server mix v1 cannot store tempo ramp intent. Your local draft is unchanged. Save locally or explicitly choose Volume before exporting.");return null}
        if(!timeline.accepts(scope,document))return null
        if(document.phaseLink!=null){mutable.value=state.copy(message="Unlock the draft relation explicitly before saving to server v1. Current positions and fades will be kept.");return null}
        val plan=runCatching {document.arrangementPlan(name)}.getOrNull() ?: return null
        val token=Flight(state);flight=token
        mutable.value=state.copy(busy=true,blocked=true,message=null)
        val work=work@{
            if(!begin(token))return@work
            fun current()=synchronized(this){flight===token&&owner?.epoch==scope.epoch&&api.session.current(scope)}
            try {
                val saved=api.saveMix(scope,state.saved,name,plan.clips){current()&&valid()&&timeline.accepts(scope,document)}
                check(document.matchesArrangement(saved))
                synchronized(this){if(current())mutable.value=ArrangementSaveState(saved=saved,message="Saved arrangement confirmed by GET.")}
            } catch(_:Exception) {
                synchronized(this){if(current())mutable.value=mutable.value.copy(message="Save was not confirmed. Do not repeat create. Open Mixes to find the result, then verify its exact ID here using GET.")}
            } finally {finish(token)}
        }
        token.work=work;return work
    }
    @Synchronized fun readback(scope:AccountScope,id:String,document:TimelineDocument,valid:()->Boolean):(() -> Unit)? {
        enter(scope)
        if(mutable.value.busy || owner?.epoch!=scope.epoch || !valid())return null
        if(runCatching {java.util.UUID.fromString(id).toString()==id}.getOrDefault(false)!=true)return null
        val token=Flight(mutable.value);flight=token;mutable.value=mutable.value.copy(busy=true)
        val work=work@{
            if(!begin(token))return@work
            fun current()=synchronized(this){flight===token&&owner?.epoch==scope.epoch&&api.session.current(scope)&&valid()&&timeline.accepts(scope,document)}
            try {
                val plan=api.mixPlan(scope,id,::current)
                check(document.matchesArrangement(plan))
                synchronized(this){if(current())mutable.value=ArrangementSaveState(saved=plan,message="Exact occurrence, placement and trim readback confirmed.")}
            } catch(_:Exception) {
                synchronized(this){if(current())mutable.value=mutable.value.copy(message="GET did not confirm this exact draft. No write was repeated.")}
            } finally {finish(token)}
        }
        token.work=work;return work
    }
    @Synchronized fun retire(){owner=null;flight=null;mutable.value=ArrangementSaveState()}
}
