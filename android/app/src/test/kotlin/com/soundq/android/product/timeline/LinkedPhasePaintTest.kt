package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.*
import soundq.design.generated.SoundQSpectralTokens as S
import org.junit.Assert.*
import org.junit.Test

class LinkedPhasePaintTest {
    @Test fun actualLanePaintUsesGraduatedW10WeightsIndependentDownbeatAndDashSolidGuide() {
        val a=TimelineClip("a",7,"Master",60000,0,60000,0,QueueSegment.Context)
        val b=a.copy(occurrence="b",globalStartMs=9375)
        val grid=PhaseGrid("test","1",500,125,125)
        val link=PhaseLink("a","b",grid,grid.copy(anchorMs=250,groupOriginMs=250),1,19,7,7,60000,60000)
        val ticks=listOf(PhaseTick(125,125,1),PhaseTick(2125,2125,4),PhaseTick(8125,8125,16),PhaseTick(16125,16125,32),PhaseTick(125,125,1,true))
        val v=TimelineViewport(60000,400f,20.0)
        for(preview in listOf(true,false)) {
            val sink=PhaseDrawScope();probePhaseLanePaint(ticks,link,9625,v,preview,sink)
            assertEquals(listOf(7f,12f,19f,25f,32f),sink.marks.take(5).map {it.to.y})
            assertEquals(listOf(1f,1.25f,1.75f,2.25f,2f),sink.marks.take(5).map {it.width})
            assertEquals(S.W10_COLOR_DOWNBEAT,sink.marks[4].color)
            val guide=sink.marks.last();assertEquals(192.5f,guide.from.x,0f)
            assertEquals(preview,guide.dashed);assertEquals(if(preview)S.W10_COLOR_LOCK_PREVIEW else S.W10_COLOR_LOCK_ACCEPTED,guide.color)
        }
        val unlocked=PhaseDrawScope();probePhaseLanePaint(ticks,null,null,v,false,unlocked)
        assertEquals(7,unlocked.marks.size) // five ticks plus two independent downbeat glyph strokes
    }
}
