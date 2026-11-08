package com.soundq.android.clockconsumer

import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.Snapshot
import com.soundq.android.playback.*
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.*
import org.junit.Test

/** Actual Compose slot/state/effect lifetime, exact production consuming body and clock model.
 * Recording UI primitives only: does not establish Android mounting, Material or gestures. */
@OptIn(ExperimentalComposeApi::class,InternalComposeApi::class)
class PlayerClockConsumerTest {
    private class NoNodes:AbstractApplier<Unit>(Unit) {
        override fun insertTopDown(index:Int,instance:Unit){}
        override fun insertBottomUp(index:Int,instance:Unit){}
        override fun remove(index:Int,count:Int){}
        override fun move(from:Int,to:Int,count:Int){}
        override fun onClear(){}
    }
    private class Harness:AutoCloseable {
        val authority=PlaybackClockAuthority(ClockOwner("service",1,"queue",2,"b"),listOf(ClockSpan("a1",10000),ClockSpan("b",20000),ClockSpan("a2",10000)))
        val state=mutableStateOf(PlaybackProjection(connection=PlaybackProjection.Connection.Connected,selectedOccurrence="b",selectionIncarnation=10,positionMs=5000,durationMs=20000,accountEpoch=1,arrangementService="service",sourceQueueIncarnation="queue",clockAuthority=authority))
        val mounted=mutableStateOf(true)
        val r=Recording()
        val recomposer=Recomposer(Dispatchers.Unconfined)
        val composition=ControlledComposition(NoNodes(),recomposer)
        var completion:((Boolean)->Unit)?=null
        var valid:(()->Boolean)?=null
        var commands=0
        var destination:ClockDestination?=null
        init {
            composition.setContent {CompositionLocalProvider(LocalRecording provides r) {
                if(mounted.value)FullPlayerClock(state.value) {p,m,pos,v,done->
                    assertTrue(v());commands++;destination=projectPlayerClock(p,m).destination(pos);valid=v;completion=done
                }
            }}
        }
        fun render() {
            r.texts.clear();r.choices.clear()
            Snapshot.sendApplyNotifications()
            composition.invalidateAll()
            composition.recompose();composition.applyChanges();composition.applyLateChanges()
        }
        fun start() {
            r.choices[1]();render()
            r.change(.8125f);render();r.finish();render()
            assertEquals(ClockDestination("a2",2500),destination)
            assertEquals(1,commands);assertTrue(valid!!())
            assertTrue("initial Seeking",r.texts.contains("Seeking"));assertFalse(r.enabled)
        }
        fun expected() {
            state.value=state.value.copy(selectedOccurrence="a2",selectionIncarnation=12,durationMs=10000,positionMs=2500,
                clockAuthority=authority.copy(owner=authority.owner.copy(selected="a2",revision=3)))
            render()
        }
        override fun close(){composition.dispose();recomposer.cancel()}
    }
    @Test fun expectedDestinationKeepsPendingUntilFalseReceipt()=Harness().use {h->
        h.start();h.expected()
        assertTrue("own destination must retain Seeking before receipt",h.r.texts.contains("Seeking"))
        assertFalse("unconfirmed seek must disable slider",h.r.enabled);assertTrue(h.valid!!())
        h.completion!!(false);h.render()
        assertTrue(h.r.texts.contains("Seek not confirmed. Try again."));assertFalse(h.r.texts.contains("Seeking"));assertTrue(h.r.enabled)
    }
    @Test fun expectedDestinationTrueReceiptSettles()=Harness().use {h->
        h.start();h.expected();assertTrue(h.r.texts.contains("Seeking"));assertFalse(h.r.enabled)
        h.completion!!(true);h.render()
        assertFalse(h.r.texts.contains("Seeking"));assertFalse(h.r.texts.contains("Seek not confirmed. Try again."));assertTrue(h.r.enabled)
    }
    @Test fun realUnobservedNativeDeadlineShowsFailureAtDestination()=Harness().use {h->
        h.start();h.expected()
        // Wait the unchanged production 8-second receipt deadline, not a synthetic false.
        val (ok,dispatches)=kotlinx.coroutines.runBlocking {com.soundq.android.clockprobe.unobservedClockDeadline()}
        assertEquals(1,dispatches);assertFalse(ok)
        assertTrue("deadline must not drop pending before settlement",h.r.texts.contains("Seeking"));assertFalse(h.r.enabled)
        h.completion!!(ok);h.render();assertTrue(h.r.texts.contains("Seek not confirmed. Try again."));assertTrue(h.r.enabled)
    }
    @Test fun conflatedUnrelatedTransitionsCannotBorrowDestination()=Harness().use {h->
        h.start();h.state.value=h.state.value.copy(selectedOccurrence="a2",selectionIncarnation=14);h.render()
        assertFalse(h.valid!!());h.completion!!(false);h.render();assertFalse(h.r.texts.contains("Seek not confirmed. Try again."))
    }
    @Test fun staleDraftFinishCannotDispatchAfterSelectionAba()=Harness().use {h->
        h.r.choices[1]();h.render();h.r.change(.8125f);h.render();val finish=h.r.finish
        h.state.value=h.state.value.copy(selectionIncarnation=12);h.render();finish();h.render();assertEquals(0,h.commands)
    }
    @Test fun sameSelectionRevisionKeepsPending()=Harness().use {h->
        h.start();h.state.value=h.state.value.copy(clockAuthority=h.authority.copy(owner=h.authority.owner.copy(revision=3)));h.render()
        assertTrue(h.r.texts.contains("Seeking"));h.completion!!(false);h.render();assertTrue(h.r.texts.contains("Seek not confirmed. Try again."))
    }
    @Test fun unrelatedSelectionPermanentlyRetiresRequest()=Harness().use {h->
        h.start();h.state.value=h.state.value.copy(selectedOccurrence="a1",selectionIncarnation=11);h.render()
        assertFalse(h.valid!!());h.expected();assertFalse(h.valid!!());h.completion!!(false);h.render()
        assertFalse(h.r.texts.contains("Seeking"));assertFalse(h.r.texts.contains("Seek not confirmed. Try again."))
    }
    @Test fun sameIdAbaCannotBecomeExpectedTransition()=Harness().use {h->
        h.start();h.state.value=h.state.value.copy(selectionIncarnation=12);h.render()
        assertFalse(h.valid!!());h.expected();assertFalse(h.valid!!())
    }
    @Test fun destinationAbaRetiresAfterExpectedTransition()=Harness().use {h->
        h.start();h.expected();h.state.value=h.state.value.copy(selectionIncarnation=13);h.render()
        assertFalse(h.valid!!());h.completion!!(false);h.render();assertFalse(h.r.texts.contains("Seek not confirmed. Try again."))
    }
    @Test fun accountReplacementRetires()=retire {it.copy(accountEpoch=2)}
    @Test fun serviceReplacementRetires()=retire {it.copy(arrangementService="other")}
    @Test fun queueReplacementRetires()=retire {it.copy(sourceQueueIncarnation="other")}
    @Test fun sourceReplacementRetires()=retire {it.copy(source=PlaybackSource.SavedMix)}
    @Test fun disconnectRetires()=retire {it.copy(connection=PlaybackProjection.Connection.Disconnected)}
    private fun retire(change:(PlaybackProjection)->PlaybackProjection)=Harness().use {h->
        h.start();h.state.value=change(h.state.value);h.render();assertFalse(h.valid!!())
        h.state.value=h.state.value.copy(accountEpoch=1,arrangementService="service",sourceQueueIncarnation="queue",source=PlaybackSource.Queue,connection=PlaybackProjection.Connection.Connected)
        h.expected();assertFalse(h.valid!!());h.completion!!(false);h.render();assertFalse(h.r.texts.contains("Seek not confirmed. Try again."))
    }
    @Test fun modeRoundTripBeforeNextFramePermanentlyRetires()=Harness().use {h->
        h.start();val song=h.r.choices[0];val queue=h.r.choices[1]
        song();queue();h.render()
        assertFalse("two mode intents cannot revive the old receipt",h.valid!!())
        h.completion!!(false);h.render();assertFalse(h.r.texts.contains("Seeking"));assertFalse(h.r.texts.contains("Seek not confirmed. Try again."));assertEquals(1,h.commands)
    }
    @Test fun modeRoundTripRetires()=Harness().use {h->
        h.start();h.r.choices[0]();h.render();assertFalse(h.valid!!());h.r.choices[1]();h.render();assertFalse(h.valid!!())
        h.completion!!(false);h.render();assertFalse(h.r.texts.contains("Seek not confirmed. Try again."));assertEquals(1,h.commands)
    }
    @Test fun disposalAndRemountDoNotReviveCompletion()=Harness().use {h->
        h.start();h.mounted.value=false;h.render();assertFalse(h.valid!!())
        h.mounted.value=true;h.render();assertFalse(h.valid!!());h.completion!!(false);h.render();assertFalse(h.r.texts.contains("Seek not confirmed. Try again."))
    }
}
