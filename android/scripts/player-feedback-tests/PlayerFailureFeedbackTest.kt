package com.soundq.android.product

import android.app.Application
import com.soundq.android.playback.PlaybackFailureEvents
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowToast

/** Uses the production native Toast owner, not a fake notification sink. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34],application=Application::class)
class PlayerFailureFeedbackTest {
    private fun owner(selection:Long=1,account:Long=7)=listOf(account,"service","queue",selection,"Queue","occurrence","server-content")
    @Test fun oneToastPerFailureSurvivesFastPollsAndSameTextRetry() {
        ShadowToast.reset()
        val feedback=PlayerFailureFeedback(RuntimeEnvironment.getApplication())
        val events=PlaybackFailureEvents()
        feedback.observe(owner(),0,null,true)
        repeat(40) {feedback.observe(owner(),0,null,true)} // preparation/cursor polling has no message
        assertEquals(0,ShadowToast.shownToastCount())
        events.audio(1,"Audio output unavailable")
        feedback.observe(owner(),events.revision,"Audio could not be played. Retry playback.",true)
        val first=ShadowToast.getLatestToast()
        assertEquals("Audio could not be played. Retry playback.",ShadowToast.getTextOfLatestToast())
        repeat(500) {
            events.audio(1,"Audio output unavailable") // equivalent exceptions from the output observer
            feedback.observe(owner(),events.revision,"Audio could not be played. Retry playback.",true)
        }
        assertEquals(1,ShadowToast.shownToastCount())
        assertEquals(1L,events.revision)
        // A new canonical error event after retry must work even if polling missed the clear.
        events.audio(null,null) // canonical Retry clear, not an optimistic ready flag
        events.audio(1,"Audio output unavailable")
        feedback.observe(owner(),events.revision,"Audio could not be played. Retry playback.",true)
        assertEquals(2,ShadowToast.shownToastCount())
        assertTrue(org.robolectric.Shadows.shadowOf(first).isCancelled)
        feedback.close()
        assertTrue(org.robolectric.Shadows.shadowOf(ShadowToast.getLatestToast()).isCancelled)
    }
    @Test fun changedFailureAndContextRefusalAreDistinctButHealthyPollsDoNotAdvance() {
        val events=PlaybackFailureEvents()
        repeat(50) {events.audio(null,null)}
        assertEquals(0L,events.revision)
        events.audio(1,"route");events.audio(1,"route")
        assertEquals(1L,events.revision)
        events.audio(2,"decoder")
        assertEquals(2L,events.revision)
        events.contextRefused()
        assertEquals(3L,events.revision)
    }
    @Test fun stoppedStaleAndReopenedOwnersCannotReplayOldFailure() {
        ShadowToast.reset()
        val feedback=PlayerFailureFeedback(RuntimeEnvironment.getApplication())
        feedback.observe(owner(),0,null,true)
        feedback.observe(owner(),1,"failed",false) // background or revoked account
        feedback.observe(owner(),1,"failed",true)
        assertEquals(0,ShadowToast.shownToastCount())
        feedback.observe(owner(2),1,"failed",true) // retained error is not a new failure
        assertEquals(0,ShadowToast.shownToastCount())
        feedback.observe(owner(2),2,"failed again",true)
        assertEquals(1,ShadowToast.shownToastCount())
        val shown=ShadowToast.getLatestToast()
        feedback.observe(owner(3,8),2,"failed again",false)
        assertTrue(org.robolectric.Shadows.shadowOf(shown).isCancelled)
        feedback.observe(owner(3,8),3,"old account",false)
        feedback.observe(owner(3,8),3,"old account",true)
        assertEquals(1,ShadowToast.shownToastCount())
        feedback.close()
        feedback.observe(owner(3,8),4,"detached",true)
        assertEquals(1,ShadowToast.shownToastCount())
        val reopened=PlayerFailureFeedback(RuntimeEnvironment.getApplication())
        reopened.observe(owner(3,8),4,"detached",true)
        assertEquals(1,ShadowToast.shownToastCount())
        reopened.observe(owner(3,8),5,"fresh",true)
        assertEquals("fresh",ShadowToast.getTextOfLatestToast())
        assertEquals(2,ShadowToast.shownToastCount())
        reopened.close()
    }
    @Test fun absentSelectionAndOutOfOrderRevisionsNeverCreateToast() {
        ShadowToast.reset()
        val feedback=PlayerFailureFeedback(RuntimeEnvironment.getApplication())
        feedback.observe(owner(),10,null,true)
        feedback.observe(null,11,"no selected playback",true)
        feedback.observe(owner(),9,"late failure",true)
        assertEquals(0,ShadowToast.shownToastCount())
        feedback.observe(owner(),12,"current",true)
        assertEquals(1,ShadowToast.shownToastCount())
        feedback.close()
    }
}
