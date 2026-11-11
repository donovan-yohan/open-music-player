package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Test

class PlayerClockTest {
    private val a=QueueOccurrence("a1",1,"A","Artist",false,10000)
    private val b=QueueOccurrence("b",2,"B","Artist",false,20000)
    private val again=a.copy(occurrenceId="a2")
    private val owner=ClockOwner("service",4,"queue",8,"b")
    private val authority=PlaybackClockAuthority(owner,listOf(ClockSpan("a1",10000),ClockSpan("b",20000),ClockSpan("a2",10000)))
    private fun projection()=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,title="B",artist="Artist",queue=listOf(a,b,again),selectedOccurrence="b",positionMs=5000,durationMs=20000,accountEpoch=4,arrangementService="service",sourceQueueIncarnation="queue",clockAuthority=authority)

    @Test fun selectedClockOwnsElapsedTotalProgressAndExactDuplicateSeek() {
        val p=projection()
        val song=projectPlayerClock(p,PlayerClockMode.Song)
        assertEquals(5000L,song.elapsedMs);assertEquals(20000L,song.totalMs)
        assertEquals(0.25f,song.fraction!!,0f)
        val queue=projectPlayerClock(p,PlayerClockMode.Queue)
        assertEquals(15000L,queue.elapsedMs);assertEquals(40000L,queue.totalMs)
        assertEquals(0.375f,queue.fraction!!,0f)
        assertEquals(ClockDestination("a2",2500),queue.destination(32500))
        assertEquals(ClockDestination("b",0),queue.destination(10000))
        assertEquals(ClockDestination("a2",10000),queue.destination(40000))
        assertEquals(5000L,p.positionMs) // Projection/mode choice never transports.
    }
    @Test fun unknownTotalsNeverBorrowMetadataOrFirstPageSum() {
        val p=projection().copy(clockAuthority=authority.copy(spans=listOf(ClockSpan("a1",10000),ClockSpan("b",null),ClockSpan("a2",10000))))
        val clock=projectPlayerClock(p,PlayerClockMode.Queue)
        assertEquals(15000L,clock.elapsedMs);assertNull(clock.totalMs);assertNull(clock.fraction);assertNull(clock.destination(15000))
        assertNull(projectPlayerClock(p.copy(selectedOccurrence="a2",clockAuthority=p.clockAuthority!!.copy(owner=owner.copy(selected="a2"))),PlayerClockMode.Queue).elapsedMs)
        assertNull(projectPlayerClock(p.copy(clockAuthority=null),PlayerClockMode.Queue).totalMs)
        assertNull(projectPlayerClock(p.copy(durationMs=0),PlayerClockMode.Song).totalMs)
    }
    @Test fun invalidSpansBoundsAndOverflowNeverProduceASeekableClock() {
        val p=projection()
        for(spans in listOf(emptyList(),listOf(ClockSpan("b",20000),ClockSpan("b",20000)),listOf(ClockSpan("a1",Long.MAX_VALUE),ClockSpan("b",20)))) {
            val c=projectPlayerClock(p.copy(clockAuthority=authority.copy(spans=spans)),PlayerClockMode.Queue)
            assertNull(c.totalMs);assertNull(c.fraction);assertNull(c.destination(0))
        }
        val c=projectPlayerClock(p,PlayerClockMode.Queue)
        assertNull(c.destination(-1));assertNull(c.destination(40001));assertEquals(ClockDestination("a1",0),c.destination(0))
        assertEquals(30000L,projectPlayerClock(p.copy(positionMs=90000),PlayerClockMode.Queue).elapsedMs)
        assertEquals(0L,projectPlayerClock(p.copy(positionMs=-10),PlayerClockMode.Song).elapsedMs)
    }
    @Test fun traversalComesOnlyFromServiceNotLoadedRowsOrRepositoryOrder() {
        val p=projection().copy(queue=listOf(b),clockAuthority=authority.copy(spans=listOf(ClockSpan("a2",10000),ClockSpan("b",20000),ClockSpan("a1",10000))))
        val c=projectPlayerClock(p,PlayerClockMode.Queue)
        assertEquals(40000L,c.totalMs);assertEquals(ClockDestination("a1",2500),c.destination(32500))
        assertNull(projectPlayerClock(p.copy(clockAuthority=authority.copy(spans=null)),PlayerClockMode.Queue).elapsedMs)
        for(source in listOf(PlaybackSource.Arrangement,PlaybackSource.SavedMix)) {
            assertNull(projectPlayerClock(p.copy(source=source),PlayerClockMode.Queue).totalMs)
            assertNull(projectPlayerClock(p.copy(source=source),PlayerClockMode.Song).destination(5000))
        }
    }
    @Test fun foreignAccountServiceSelectionAndQueueRetireClock() {
        val p=projection()
        listOf(p.copy(accountEpoch=5),p.copy(arrangementService="other"),p.copy(sourceQueueIncarnation="other"),p.copy(selectedOccurrence="a1"),p.copy(connection=PlaybackProjection.Connection.Disconnected)).forEach {
            assertNull(projectPlayerClock(it,PlayerClockMode.Queue).destination(15000))
        }
    }
}
