package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import org.junit.Assert.*
import org.junit.Test

class TempoNativeObservationTest {
    private fun document():TimelineDocument {
        val a=TempoSourceIdentity("a",1,"source-a",30000,"grid-a","local_manual",120.0,0.0,1)
        val b=a.copy(occurrence="b",track=2,sourceKey="source-b",gridRevision="grid-b",sourceBpm=144.0)
        val intent=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,a,b,120.0,TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,0.0,10000.0,0,22,TempoGainLaw.EqualPower)
        return projectTempoDocument(TimelineDocument(4,listOf(
            TimelineClip("a",1,"A",30000,0,11000,0,QueueSegment.Context,fadeOutMs=10000),
            TimelineClip("b",2,"B",30000,0,20000,0,QueueSegment.Context,fadeInMs=10000)
        ),tempoRamps=listOf(intent)))
    }
    private val identity=ArrangementIdentity("service",1,"queue",4,"install")
    private fun capture(d:TimelineDocument)=TempoEditCapture("editor-visit",d.revision,TempoEditorOverlap(d.clips[0],d.clips[1]).id)
    private fun deck(id:String)=PerformanceDeck(PerformanceTarget(identity,id),1000.0,1.0,1000.0,true,false,false,0,false,null,0,LiveSyncState.Off,0.0,0,0,0,true,7,132.0)
    private fun playback(d:TimelineDocument)=PlaybackProjection(PlaybackProjection.Connection.Connected,positionMs=1000,
        arrangement=AcceptedArrangement(identity,d,emptyList()),performanceDecks=mapOf("a" to deck("a"),"b" to deck("b")))

    @Test fun savedIntentIsReadyButNeverNativeAcceptedWithoutInstalledDocument() {
        val d=document()
        val result=tempoNativeObservation(capture(d),d,PlaybackProjection())!!
        assertEquals(TempoTransitionStatus.Ready,result.status)
        assertNull(result.acceptedCommandId)
    }
    @Test fun nativeAcceptanceRequiresBothMatchingReadyKeylockedParticipants() {
        val d=document();val p=playback(d)
        val result=tempoNativeObservation(capture(d),d,p)!!
        assertEquals(TempoTransitionStatus.Accepted,result.status)
        assertEquals(identity.install,result.acceptedCommandId)
        assertEquals(132.0,result.observedEffectiveBpm!!,0.0)
        for(changed in listOf(deck("b").copy(ready=false),deck("b").copy(keylock=false),deck("b").copy(processingEpoch=0),
            deck("b").copy(processingEpoch=8),deck("b").copy(effectiveBpm=null),deck("b").copy(target=PerformanceTarget(identity.copy(install="other"),"b")))) {
            assertEquals(TempoTransitionStatus.Pending,tempoNativeObservation(capture(d),d,p.copy(performanceDecks=p.performanceDecks+("b" to changed)))!!.status)
        }
        assertEquals(TempoTransitionStatus.Pending,tempoNativeObservation(capture(d),d,p.copy(preparing=true))!!.status)
    }
    @Test fun differentSharedPulseIsFailureNotAcceptedAndStaleCaptureCannotPublish() {
        val d=document();val p=playback(d)
        assertEquals(TempoTransitionStatus.Failed,tempoNativeObservation(capture(d),d,p.copy(performanceDecks=p.performanceDecks+("b" to deck("b").copy(effectiveBpm=133.0))))!!.status)
        assertNull(tempoNativeObservation(capture(d).copy(documentRevision=3),d,p))
        assertNull(tempoNativeObservation(capture(d).copy(overlapId="foreign"),d,p))
    }
    @Test fun heldIncomingTailNeedsOnlyItsCurrentNativeParticipant() {
        val d=document();val p=playback(d).copy(positionMs=11000,performanceDecks=mapOf("b" to deck("b").copy(effectiveBpm=144.0)))
        assertEquals(TempoTransitionStatus.Accepted,tempoNativeObservation(capture(d),d,p)!!.status)
        assertEquals(TempoTransitionStatus.Ready,tempoNativeObservation(capture(d),d,p.copy(positionMs=30000))!!.status)
    }
}
