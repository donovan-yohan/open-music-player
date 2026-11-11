package com.soundq.designsystem

import org.junit.Assert.*
import org.junit.Test

class RowRevealStateTest {
    private fun end(state:RowRevealState,dx:Float,velocity:Float=0f,cancel:Boolean=false) {
        state.begin(state.offset);state.follow(dx,112f);state.end(112f,0.5f,velocity,0.3f,cancel)
    }
    @Test fun canonicalReleaseShortThresholdFullReverseAndCancel() {
        for((dx,velocity,open) in listOf(Triple(-40f,0f,false),Triple(-56f,0f,true),Triple(-112f,0f,true),Triple(-90f,0.3f,true),Triple(-90f,0.3001f,false),Triple(-90f,0.5f,false))) {
            val s=RowRevealState(RowRevealOwner());end(s,dx,velocity)
            assertEquals(open,s.targetOpen);assertFalse(s.actionable)
            assertTrue(s.complete(s.revision,112f));assertEquals(open,s.actionable)
        }
        val s=RowRevealState(RowRevealOwner());end(s,-100f,cancel=true);s.complete(s.revision,112f);assertEquals(RowRevealPhase.Closed,s.phase)
        s.request(true);s.complete(s.revision,112f);end(s,92f,cancel=true);s.complete(s.revision,112f);assertTrue(s.actionable)
    }
    @Test fun directFollowClampsAndOnlyActualCurrentCompletionEnablesActions() {
        val s=RowRevealState(RowRevealOwner());s.begin(0f);s.follow(-500f,112f);assertEquals(-112f,s.offset)
        s.follow(20f,112f);assertEquals(0f,s.offset)
        s.follow(-90f,112f);s.end(112f,0.5f,0f,0.3f);val old=s.revision
        assertFalse(s.admit(old));s.close();assertFalse(s.complete(old,112f));assertFalse(s.actionable)
        s.request(true);val current=s.revision;assertTrue(s.complete(current,112f));assertTrue(s.admit(current));assertFalse(s.admit(current))
    }
    @Test fun oneOpenRowNewFrontCloseAndSeparateTapPlays() {
        val o=RowRevealOwner();val a=RowRevealState(o);val b=RowRevealState(o)
        a.request(true);a.complete(a.revision,112f)
        b.begin(0f);assertFalse(a.actionable);b.follow(-112f,112f);b.end(112f,0.5f,0f,0.3f);b.complete(b.revision,112f)
        assertFalse(b.frontTap());b.complete(b.revision,112f);assertTrue(b.frontTap())
    }
    @Test fun disposalAndCloseOpenAbaPermanentlyRefuseRetainedAction() {
        val s=RowRevealState(RowRevealOwner());s.request(true);s.complete(s.revision,112f);val old=s.revision
        s.close();s.request(true);s.complete(s.revision,112f);assertFalse(s.admit(old))
        s.dispose();assertFalse(s.complete(s.revision,112f));assertFalse(s.begin(0f));assertFalse(s.frontTap()&&s.actionable)
    }
}
