package com.soundq.android.product.timeline

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test

// Only the platform drawing boundary is replaced. Extracted lane blocks remain production.
internal class ProbePath {
    val lines=mutableListOf<Pair<Offset,Offset>>()
    private var from=Offset.Zero
    fun moveTo(x:Float,y:Float){from=Offset(x,y)}
    fun lineTo(x:Float,y:Float){lines+=from to Offset(x,y)}
}
internal data class ProbeMark(val color:Color,val from:Offset,val to:Offset)
internal class DrawScope {
    val size=Size(100f,100f)
    val marks=mutableListOf<ProbeMark>()
    class Stroke(val width:Float)
    fun drawPath(path:ProbePath,color:Color,style:androidx.compose.ui.graphics.drawscope.Stroke){path.lines.forEach {(a,b)->marks+=ProbeMark(color,a,b)}}
    fun drawRect(color:Color,topLeft:Offset,size:Size){marks+=ProbeMark(color,topLeft,topLeft+Offset(size.width,size.height))}
    fun translate(x:Float,y:Float){}
    fun scale(x:Float,y:Float,pivot:Offset){}
    fun withTransform(transform:DrawScope.()->Unit,block:DrawScope.()->Unit){transform();block()}
}

class SpectralLanePaintTest {
    private val clip=TimelineClip("source",7,"Source",1000,0,1000,0,QueueSegment.Context)
    private val viewport=TimelineViewport(1000,100f,100.0)
    private fun wave()=TrackWaveform(TrackId(7),"source-derived-test",1000,listOf(PeakTier("detail",floatArrayOf(-0.8f,-0.2f,-0.5f),floatArrayOf(0.6f,0.3f,0.7f),SpectralBands(floatArrayOf(1f,0f,0f),floatArrayOf(0f,1f,0f),floatArrayOf(0f,0f,1f),SpectralMetadata("bands3-v1")))))
    private fun paint(brand:Color):List<ProbeMark> {
        val sink=DrawScope();val cache=WaveformCache()
        probeLanePaint(clip,viewport,wave(),cache::window,ProbeColors(brand),sink)
        return sink.marks
    }
    @Test fun realLanePaintsIndependentSourceBandHuesInsteadOfBrand(){
        val marks=paint(Color(1f,0.5f,0f))
        assertTrue("low source bin must paint red",marks.any {it.color.red>0.9f&&it.color.green<0.01f&&it.color.blue<0.01f})
        assertTrue("mid source bin must paint green",marks.any {it.color.green>0.9f&&it.color.red<0.01f&&it.color.blue<0.01f})
        assertTrue("high source bin must paint blue",marks.any {it.color.blue>0.9f&&it.color.green<0.01f&&it.color.red<0.01f})
    }
    @Test fun actualLaneHueDoesNotFollowLightDarkOrSelectionBrand(){
        assertEquals(paint(Color(1f,0.5f,0f)).map {it.color},paint(Color(0f,0.8f,1f)).map {it.color})
    }
}
