package com.soundq.android.product

import com.soundq.android.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.coroutines.CoroutineContext

class DeviceOnlyOnlineSchedulingTest {
    private class HeldDispatcher:CoroutineDispatcher() {
        val queue=ConcurrentLinkedQueue<Runnable>()
        override fun dispatch(context:CoroutineContext,block:Runnable){queue.add(block)}
        fun drain(){while(true)(queue.poll() ?: return).run()}
    }
    @Test fun cancelledBeforeEntryClearsItsBusyMarkerAndReservationWithoutReplayingIntoSuccessor() {
        val dispatcher=HeldDispatcher();val parent=SupervisorJob();val work=CoroutineScope(parent+dispatcher)
        val endpoint=ApiEndpoint.parse("https://unused.invalid/api/v1");var reads=0;var clears=0
        val session=AccountSession(endpoint,object:SessionStore {
            override fun load(endpoint:ApiEndpoint)=SecretTokens("synthetic","synthetic-r","A").also {reads++}
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){error("cancelled work must not save")}
            override fun clear(){clears++}
        })
        val api=SoundQApi(session);val busy=MutableStateFlow<AccountSession.OnlineRestoreTicket?>(null)
        try {
            assertTrue(session.useDeviceDownloads());val local=session.capture()!!
            val first=scheduleOnlineRestore(session,api,local,work,busy,dispatcher)!!
            assertNotNull(busy.value);assertNull(scheduleOnlineRestore(session,api,local,work,busy,dispatcher))
            first.cancel();dispatcher.drain();assertTrue(first.isCompleted);assertNull(busy.value)
            assertEquals(AuthState.DeviceOnly("A"),session.state.value);assertTrue(session.current(local));assertEquals(1,reads)
            val next=scheduleOnlineRestore(session,api,local,work,busy,dispatcher)
            assertNotNull("fresh schedule refused after cancelled reservation",next)
            assertNotNull(busy.value);first.cancel();assertNotNull(busy.value)
            next!!.cancel();dispatcher.drain();assertNull(busy.value);assertEquals(1,reads);assertEquals(0,clears)
            parent.cancel()
            val alreadyCancelled=scheduleOnlineRestore(session,api,local,work,busy,dispatcher)!!
            dispatcher.drain();assertTrue(alreadyCancelled.isCompleted);assertNull(busy.value)
            assertNotNull(session.claimOnlineRestore(local))
        } finally {parent.cancel();dispatcher.drain()}
    }
}
