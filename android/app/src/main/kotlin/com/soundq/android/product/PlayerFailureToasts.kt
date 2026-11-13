package com.soundq.android.product

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.data.AuthState
import com.soundq.android.playback.PlaybackProjection
import com.soundq.android.playback.PlaybackRef
import com.soundq.android.playback.PlaybackSource
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collect

/** One consumer above every destination and Player/Queue panel; no per-panel delivery state. */
@Composable internal fun PlayerFailureToasts(model:ProductViewModel) {
    val context=LocalContext.current.applicationContext
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    val feedback=remember(model,lifecycle,context){PlayerFailureFeedback(context)}
    fun sync() {
        // Read the live owner at delivery, never a composition-captured cursor snapshot.
        val p=model.playback.value
        val (auth,epoch)=model.graph.session.observation()
        val accepted=auth is AuthState.SignedIn||auth is AuthState.DeviceOnly||auth is AuthState.SignedOut
        val selected=p.queue.singleOrNull {it.occurrenceId==p.selectedOccurrence}
        val local=p.selectedDeviceOwner
        val sourceCurrent=if(selected?.ref is PlaybackRef.Device) {
            p.source==PlaybackSource.Queue&&p.localOnly&&local!=null&&local.occurrence==p.selectedOccurrence&&
                local.ref==selected.ref&&local.version==epoch&&model.graph.phoneAudio.current(local.version)&&
                local.retainedBy(model.graph.phoneAudio.state.value.snapshot)
        } else p.accountEpoch==epoch
        val current=p.connection==PlaybackProjection.Connection.Connected&&sourceCurrent&&accepted
        val owner=p.selectedOccurrence?.let {occurrence->
            listOf(p.accountEpoch,p.sessionIdentity,p.sourceQueueIncarnation,p.selectionIncarnation,
                p.source,occurrence,p.arrangementService,p.localOnly,p.arrangement?.identity,p.selectedDeviceOwner,
                p.queue.singleOrNull {it.occurrenceId==occurrence}?.ref)
        }
        feedback.observe(owner,p.failureRevision,p.error,current&&lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
    }
    DisposableEffect(feedback,lifecycle) {
        val observer=LifecycleEventObserver {_,_->sync()}
        lifecycle.addObserver(observer);sync()
        onDispose {lifecycle.removeObserver(observer);feedback.close()}
    }
    LaunchedEffect(model,lifecycle,feedback) {
        combine(model.playback,model.graph.session.scopeRevision,model.graph.session.state,model.graph.phoneAudio.state) {_,_,_,_->Unit}
            .collect {sync()}
    }
}
