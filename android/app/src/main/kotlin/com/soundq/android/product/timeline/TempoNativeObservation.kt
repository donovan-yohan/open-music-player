package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.*
import com.soundq.android.playback.PlaybackProjection
import kotlin.math.abs

/** Read-only projection of the existing service/native receipt. Saving intent is never acceptance. */
internal fun tempoNativeObservation(capture:TempoEditCapture,document:TimelineDocument,playback:PlaybackProjection):TempoEditorNativeObservation? {
    if(capture.documentRevision!=document.revision)return null
    val ramp=document.tempoRamps.singleOrNull {
        TempoEditorOverlap(document.clips.single {c->c.occurrence==it.outgoing.occurrence},
            document.clips.single {c->c.occurrence==it.incoming.occurrence}).id==capture.overlapId
    } ?: return null
    validateNativeTempoPlan(document)?.let {return TempoEditorNativeObservation(capture,TempoTransitionStatus.Unsupported,it,null,null)}
    val accepted=playback.arrangement
    if(accepted?.document!=document)return TempoEditorNativeObservation(capture,TempoTransitionStatus.Ready,"Use Play to audition this saved transition.",null,null)
    val command=accepted.identity.install
    if(playback.error!=null)return TempoEditorNativeObservation(capture,TempoTransitionStatus.Failed,playback.error,null,null)
    val members=setOf(ramp.outgoing.occurrence,ramp.incoming.occurrence)
    val active=document.clips.filter {it.occurrence in members&&playback.positionMs>=it.globalStartMs&&playback.positionMs<it.globalEndMs}
    if(active.isEmpty())return TempoEditorNativeObservation(capture,TempoTransitionStatus.Ready,"Transition is outside the current playback position.",null,null)
    val decks=active.mapNotNull {playback.performanceDecks[it.occurrence]}
    val ready=!playback.preparing&&decks.size==active.size&&decks.all {
        it.target.identity==accepted.identity&&it.ready&&it.keylock&&it.processingEpoch>0&&it.effectiveBpm?.let {bpm->bpm.isFinite()&&bpm>0}==true
    }&&decks.map {it.processingEpoch}.distinct().size==1
    if(!ready)return TempoEditorNativeObservation(capture,TempoTransitionStatus.Pending,"Preparing key-lock audio.",command,null)
    val bpm=decks.first().effectiveBpm!!
    if(decks.any {abs(it.effectiveBpm!!-bpm)>0.0001})return TempoEditorNativeObservation(capture,TempoTransitionStatus.Failed,"Native participants reported different shared tempos.",null,null)
    return TempoEditorNativeObservation(capture,TempoTransitionStatus.Accepted,null,null,command,bpm)
}
