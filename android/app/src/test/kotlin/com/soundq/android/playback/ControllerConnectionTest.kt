package com.soundq.android.playback

import com.google.common.util.concurrent.SettableFuture
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executor

class ControllerConnectionTest {
    private class Controller(var connected:Boolean=true)
    @Test fun queuedCompletionCannotResurrectDisconnectedController() {
        val queue=java.util.ArrayDeque<Runnable>();val future=SettableFuture.create<Controller>();val c=Controller()
        var state=PlaybackProjection.Connection.Connecting;var attaches=0;var releases=0
        val connection=ControllerConnection(future,Executor {queue.add(it)},{it.connected},{attaches++},{},{releases++},{state=it})
        queue.add {future.set(c)}
        queue.add {c.connected=false;connection.disconnected(c)}
        while(queue.isNotEmpty())queue.remove().run()
        assertEquals(PlaybackProjection.Connection.Disconnected,state)
        assertEquals(0,attaches);assertFalse(connection.accepts(c))
        connection.close();connection.close();assertEquals(1,releases)
    }
    @Test fun pendingAndCompletedCloseNeverAttachLateAndReleaseOnce() {
        for(completed in listOf(false,true)) {
            val queue=java.util.ArrayDeque<Runnable>();val future=SettableFuture.create<Controller>();var releases=0;var attaches=0
            val connection=ControllerConnection(future,Executor{queue.add(it)},{it.connected},{attaches++},{},{releases++;future.cancel(false)},{})
            if(completed)future.set(Controller())
            connection.close();connection.close();while(queue.isNotEmpty())queue.remove().run()
            assertEquals(0,attaches);assertEquals(1,releases)
        }
    }
}
