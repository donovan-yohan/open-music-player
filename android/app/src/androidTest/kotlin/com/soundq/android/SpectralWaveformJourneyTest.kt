package com.soundq.android

import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.product.timeline.TimelineLane
import soundq.design.generated.SoundQAppearance
import com.soundq.designsystem.SoundQTheme
import kotlinx.serialization.json.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Mounted real lane + actual producer fixture, bounded component raster only.
 * Rasterize the mounted View directly for bounded component pixel assertions.
 */
class SpectralWaveformJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun producerSignedSpectrumRetainsHueUnderLightDarkSelectionAndZoom() {
        val context=InstrumentationRegistry.getInstrumentation().context
        val target=InstrumentationRegistry.getInstrumentation().targetContext
        val observations=JSONArray()
        var primary:Throwable?=null
        try {
        val body=Json.parseToJsonElement(context.assets.open("waveform/synthetic_analysis.json").bufferedReader().use {it.readText()}).jsonObject
        val wave=AnalysisWaveformJson.parse(JsonObject(body+mapOf("track_id" to JsonPrimitive(7),"status" to JsonPrimitive("analyzed"))),TrackId(7),197500)
        assertEquals("analyzed",wave.status)
        val source=body.getValue("artifacts").jsonObject.getValue("waveforms").jsonObject
        for(tier in wave.tiers) {
            val producer=source.getValue(tier.name).jsonObject
            assertArrayEquals(producer.getValue("minima").jsonArray.map {it.jsonPrimitive.float}.toFloatArray(),tier.minima,0f)
            assertArrayEquals(producer.getValue("maxima").jsonArray.map {it.jsonPrimitive.float}.toFloatArray(),tier.maxima,0f)
            assertEquals("fixture:librosa-mel-bands-v2",tier.spectral!!.metadata.provenance)
        }
        observations.put(JSONObject().put("stage","actual-producer-signed-bands-admitted").put("status",wave.status).put("sourceKey",wave.sourceKey))
        val clip=TimelineClip("spectral",7,"Producer fixture",197500,0,197500,0,QueueSegment.Context)
        val cache=WaveformCache()
        val appearance=mutableStateOf(SoundQAppearance.Dark)
        val selected=mutableStateOf(false)
        val viewport=mutableStateOf(TimelineViewport(197500,400f,400000.0/197500))
        compose.setContent {
            SoundQTheme(reducedMotion=true,appearance=appearance.value) {
                Column(Modifier.width(400.dp)) {
                    TimelineLane(clip,1,selected.value,false,wave,viewport,remember {mutableLongStateOf(-1000)},SnapMode.Free,false,
                        {selected.value=true},{EditDecision(true)}, {},cache::window,{}, {}, {})
                }
            }
        }
        val lane=compose.onNodeWithContentDescription("Waveform spectral")
        fun raster(label:String):List<Triple<Float,Float,Float>> {
            val node=lane.fetchSemanticsNode()
            val root=node.root as ViewRootForTest
            val bounds=node.boundsInRoot
            val image=compose.runOnIdle {
                assertTrue(compose.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE==0)
                val view=root.view
                android.graphics.Bitmap.createBitmap(view.width,view.height,android.graphics.Bitmap.Config.ARGB_8888).also {bitmap ->
                    view.draw(android.graphics.Canvas(bitmap))
                    java.io.File(target.filesDir,"spectrum-$label.png").outputStream().use {assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))}
                }.asImageBitmap()
            }
            val pixels=image.toPixelMap()
            val v=viewport.value
            val sourceStart=clip.sourceAt(maxOf(clip.globalStartMs,v.offsetMs)).coerceIn(clip.sourceInMs,clip.sourceOutMs)
            val sourceEnd=clip.sourceAt(minOf(clip.globalEndMs,v.offsetMs+v.visibleMs)).coerceIn(clip.sourceInMs,clip.sourceOutMs)
            val window=cache.window(wave,sourceStart,sourceEnd,kotlin.math.ceil(bounds.width.toDouble()).toInt().coerceIn(1,8192))
            val samples=JSONArray()
            observations.put(JSONObject().put("stage",label).put("secure",false).put("bounds",bounds.toString())
                .put("imageWidth",image.width).put("imageHeight",image.height).put("samples",samples))
            val bands=window.spectral!!
            return window.minima.indices.map {i ->
                val coverage=window.coverage!!
                val span=coverage.endBin-coverage.firstBin
                val a=coverage.firstBin+i*span/window.minima.size
                val b=coverage.firstBin+kotlin.math.ceil((i+1).toDouble()*span/window.minima.size).toInt()
                val begin=maxOf(sourceStart,kotlin.math.floor(a.toDouble()*clip.sourceDurationMs/coverage.sourceBinCount).toLong())
                val end=minOf(sourceEnd,kotlin.math.ceil(b.toDouble()*clip.sourceDurationMs/coverage.sourceBinCount).toLong())
                val x=(bounds.left+(v.x(clip.globalAt(begin))+v.x(clip.globalAt(end)))/2).toInt().coerceIn(0,image.width-1)
                val middle=(window.minima[i]+window.maxima[i])/2
                val y=(bounds.top+bounds.height/2-middle*bounds.height*0.42f).toInt().coerceIn(0,image.height-1)
                val actual=pixels[x,y]
                val maximum=maxOf(bands.low[i],bands.mid[i],bands.high[i])
                samples.put(JSONObject().put("bin",i).put("x",x).put("y",y).put("actual",JSONArray(listOf(actual.red,actual.green,actual.blue)))
                    .put("bands",JSONArray(listOf(bands.low[i],bands.mid[i],bands.high[i]))))
                if(maximum>0f) {
                    assertEquals(bands.low[i]/maximum*0.94f,actual.red,0.025f)
                    assertEquals(bands.mid[i]/maximum*0.94f,actual.green,0.025f)
                    assertEquals(bands.high[i]/maximum*0.94f,actual.blue,0.025f)
                }
                Triple(actual.red,actual.green,actual.blue)
            }
        }
        compose.waitForIdle()
        // onSizeChanged publishes physical px, which can differ from the initial 400dp.
        // Fit the complete source using that measured native width before sampling bins.
        compose.runOnIdle {val v=viewport.value;viewport.value=v.copy(pixelsPerSecond=v.widthPx*1000.0/clip.sourceDurationMs)}
        compose.waitForIdle()
        val dark=raster("dark")
        compose.runOnIdle {appearance.value=SoundQAppearance.Light;selected.value=true}
        compose.waitForIdle()
        assertEquals(dark,raster("light-selected"))
        compose.runOnIdle {selected.value=false;viewport.value=viewport.value.zoom(2f,viewport.value.widthPx/2)}
        compose.waitForIdle()
        lane.assertIsDisplayed()
        raster("light-zoom")
        compose.onNodeWithText("Spectrum · Low red / Mid green / High blue · not stems").assertIsDisplayed()
        compose.runOnIdle {assertTrue(cache.bytes<=cache.maxBytes)}
        observations.put(JSONObject().put("stage","zoom-and-cache-bound").put("bytes",cache.bytes).put("maxBytes",cache.maxBytes))
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            try {java.io.File(target.filesDir,"spectrum-diagnostic.json").writeText(JSONObject().put("phases",observations).put("failure",primary?.toString()).toString())}
            catch(error:Throwable) {if(primary!=null)primary.addSuppressed(error)else throw error}
        }
    }
}
