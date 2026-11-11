package com.soundq.android.playback

import androidx.media3.common.*
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

/** Real Media3 Timeline traversal. Only Player access is a JVM proxy, not a second queue. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlayerClockAuthorityTest {
    private class FiniteTimeline(val ids:List<String>,val durations:List<Long>,val order:List<Int>):Timeline() {
        override fun getWindowCount()=ids.size
        override fun getPeriodCount()=ids.size
        override fun getWindow(i:Int,w:Window,projection:Long):Window {
            w.mediaItem=MediaItem.Builder().setMediaId(ids[i]).build()
            w.durationUs=if(durations[i]==C.TIME_UNSET)C.TIME_UNSET else durations[i]*1000
            return w
        }
        override fun getPeriod(i:Int,p:Period,setIds:Boolean):Period=error("Not needed")
        override fun getIndexOfPeriod(uid:Any)=ids.indexOf(uid)
        override fun getUidOfPeriod(i:Int):Any=ids[i]
        override fun getFirstWindowIndex(shuffle:Boolean)=if(shuffle)order.firstOrNull() ?: C.INDEX_UNSET else if(ids.isEmpty())C.INDEX_UNSET else 0
        override fun getNextWindowIndex(i:Int,repeat:Int,shuffle:Boolean)=if(shuffle)order.getOrNull(order.indexOf(i)+1) ?: C.INDEX_UNSET else (i+1).takeIf {it<ids.size} ?: C.INDEX_UNSET
    }
    private fun player(t:FiniteTimeline,shuffle:Boolean=false,count:Int=t.ids.size):Player=Proxy.newProxyInstance(Player::class.java.classLoader,arrayOf(Player::class.java)){_,m,args->
        when(m.name) {
            "getCurrentTimeline"->t
            "getMediaItemCount"->count
            "getShuffleModeEnabled"->shuffle
            "getMediaItemAt"->MediaItem.Builder().setMediaId(t.ids[args!![0] as Int]).build()
            else->error("Unexpected Player call ${m.name}")
        }
    } as Player
    @Test fun fullAcceptedTimelineUsesShuffleTraversalAndPreservesUnknowns() {
        val t=FiniteTimeline(listOf("a1","b","a2"),listOf(10000,C.TIME_UNSET,12000),listOf(2,0,1))
        assertEquals(listOf(ClockSpan("a2",12000),ClockSpan("a1",10000),ClockSpan("b",null)),player(t,true).acceptedClockSpans())
        assertEquals(listOf("a1","b","a2"),player(t).acceptedClockSpans()!!.map {it.occurrence})
        assertNull(player(t,count=2).acceptedClockSpans())
    }
    @Test fun duplicateOccurrenceOrIncompleteTraversalIsNotWholeQueueAuthority() {
        assertNull(player(FiniteTimeline(listOf("a","a"),listOf(1,2),listOf(0,1))).acceptedClockSpans())
        assertNull(player(FiniteTimeline(listOf("a","b"),listOf(1,2),listOf(1)),true).acceptedClockSpans())
        assertNull(player(FiniteTimeline(emptyList(),emptyList(),emptyList())).acceptedClockSpans())
    }
    @Test fun fullLogical1001ClockAndInverseNeverUseFirstMetadataPageAsWholeContext() {
        val ids=(0 until 1001).map {"logical-$it"}
        val timeline=FiniteTimeline(ids,List(ids.size){1000L},ids.indices.toList())
        val spans=requireNotNull(player(timeline).acceptedClockSpans())
        assertEquals(ids.size,spans.size)
        val owner=ClockOwner("service",4,"queue",1,ids.last())
        val projection=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,
            selectedOccurrence=ids.last(),positionMs=125,durationMs=1000,accountEpoch=4,
            arrangementService="service",sourceQueueIncarnation="queue",clockAuthority=PlaybackClockAuthority(owner,spans))
        val clock=projectPlayerClock(projection,PlayerClockMode.Queue)
        val position=(ids.size-1)*1000L+125
        assertEquals(ids.size*1000L,clock.totalMs);assertEquals(position,clock.elapsedMs)
        assertEquals(ClockDestination(ids.last(),125),clock.destination(position))
        assertNull(player(timeline,count=QueuePolicy.MAX_CONTEXT_TRACKS).acceptedClockSpans())
        val truncated=FiniteTimeline(ids,List(ids.size){1000L},ids.indices.take(QueuePolicy.MAX_CONTEXT_TRACKS))
        assertNull(player(truncated,true).acceptedClockSpans())
    }
}
