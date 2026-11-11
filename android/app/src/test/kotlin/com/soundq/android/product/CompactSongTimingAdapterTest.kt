package com.soundq.android.product

import com.soundq.android.playback.*
import org.junit.Assert.*
import org.junit.Test

class CompactSongTimingAdapterTest {
    private val device=PlaybackRef.Device("00000000-0000-0000-0000-000000000001","a".repeat(64),4096,1)
    private fun row(ref:PlaybackRef?=device,track:Long=0)=QueueOccurrence("occurrence",track,"Phone title","Phone artist",false,601000,ref=ref)
    private fun projection(row:QueueOccurrence)=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,
        title=row.title,artist=row.artist,queue=listOf(row),selectedOccurrence=row.occurrenceId,positionMs=42000,durationMs=601000,
        accountEpoch=7,sessionIdentity="session",sourceQueueIncarnation="queue",selectionIncarnation=3)
    @Test fun acceptedPhoneOccurrenceUsesCanonicalSongClockWithoutServerId() {
        val row=row();val result=projectCompactSongTiming(projection(row),row)
        assertEquals("0:42 / 10:01",result.clockText);assertNotNull(result.identity)
        assertEquals(42000L,result.elapsed);assertEquals(601000L,result.total)
    }
    @Test fun deviceContentAndIncarnationParticipateInVisualIdentity() {
        val row=row();val original=projectCompactSongTiming(projection(row),row)
        for(ref in listOf(device.copy(sha256="b".repeat(64)),device.copy(bytes=8192),device.copy(incarnation=2),device.copy(id="00000000-0000-0000-0000-000000000002"))) {
            val next=row(ref);assertNotEquals(original.identity,projectCompactSongTiming(projection(next),next).identity)
        }
    }
    @Test fun serverClockAndSelectionLifetimesRemainDistinct() {
        val row=row(null,12);val p=projection(row);val t=projectCompactSongTiming(p,row)
        assertEquals("0:42 / 10:01",t.clockText)
        for(next in listOf(p.copy(accountEpoch=8),p.copy(sessionIdentity="new"),p.copy(sourceQueueIncarnation="new"),p.copy(selectionIncarnation=4)))
            assertNotEquals(t.identity,projectCompactSongTiming(next,row).identity)
    }
    @Test fun globalArrangementAndUnmatchedOrDisconnectedRowsNeverSupplySongTime() {
        val row=row();val p=projection(row)
        for(next in listOf(p.copy(source=PlaybackSource.Arrangement),p.copy(source=PlaybackSource.SavedMix),p.copy(selectedOccurrence="other"),p.copy(title="other"),p.copy(artist="other"),p.copy(connection=PlaybackProjection.Connection.Disconnected)))
            assertNull(projectCompactSongTiming(next,row).identity)
        assertNull(projectCompactSongTiming(p,row(null)).identity)
    }
}
