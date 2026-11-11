package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.WindowManager
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import kotlin.math.ceil
import kotlin.math.floor

/** Ordinary fixture UI and real TLS/decode/native output; no production credentials or screenshots. */
class SharedMediaJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun row(title:String,inDialog:Boolean=false):SemanticsMatcher {
        val identity=hasText(title) and hasClickAction() and hasAnyDescendant(hasContentDescription("More for $title"))
        return if(inDialog)identity and hasAnyAncestor(isDialog())else identity
    }
    private fun art(title:String,inDialog:Boolean=false):SemanticsMatcher {
        val identity=hasTestTag("media-artwork") and hasAnyAncestor(hasClickAction() and hasAnyDescendant(hasText(title)) and hasAnyDescendant(hasContentDescription("More for $title")))
        return if(inDialog)identity and hasAnyAncestor(isDialog())else identity
    }
    private fun image(color:Int):ByteArray=Bitmap.createBitmap(80,80,Bitmap.Config.ARGB_8888).let {bitmap->
        try {bitmap.eraseColor(color);java.io.ByteArrayOutputStream().also {bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}.toByteArray()}finally{bitmap.recycle()}
    }
    private fun pixels(matcher:SemanticsMatcher,color:Int,file:String?=null):Int {
        if(compose.onAllNodes(matcher,useUnmergedTree=true).fetchSemanticsNodes().isEmpty())return 0
        val node=compose.onNode(matcher,useUnmergedTree=true).fetchSemanticsNode()
        val bounds=node.boundsInRoot
        val root=node.root as ViewRootForTest
        return compose.runOnIdle {
            assertTrue(compose.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE==0)
            val bitmap=Bitmap.createBitmap(root.view.width,root.view.height,Bitmap.Config.ARGB_8888)
            try {
                root.view.draw(Canvas(bitmap))
                file?.let {File(compose.activity.filesDir,it).outputStream().use {out->bitmap.compress(Bitmap.CompressFormat.PNG,100,out)}}
                val left=ceil(bounds.left).toInt();val right=floor(bounds.right).toInt();val top=ceil(bounds.top).toInt();val bottom=floor(bounds.bottom).toInt()
                assertTrue(left>=0&&right<=bitmap.width&&top>=0&&bottom<=bitmap.height)
                var count=0
                for(y in top until bottom)for(x in left until right)if(bitmap.getPixel(x,y)==color)count++
                count
            }finally{bitmap.recycle()}
        }
    }
    @Test fun ordinaryHomeQueuePlayerAndArrangementShareRowsAndPaintTheirOwnCovers() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as PrecisionBpmLiveFixtureApplication
        val graph=app.graph
        val original=ProductTransportFixture.server.dispatcher
        val magenta=image(android.graphics.Color.MAGENTA)
        val cyan=image(android.graphics.Color.CYAN)
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(path=="/cover-1.png"||path=="/cover-2.png") {
                    assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"])
                    return MockResponse.Builder().addHeader("Content-Type","image/png").body(Buffer().write(if(path=="/cover-1.png")magenta else cyan)).build()
                }
                if(path=="/api/v1/library") {
                    val rows=JSONArray()
                    if(request.url.queryParameter("offset")=="0")for(id in 1..2)rows.put(JSONObject().put("id",id).put("title","Tempo $id").put("artist","Synthetic ensemble")
                        .put("duration_ms",120000).put("is_liked",false).put("analysis_status","analyzed")
                        .put("analysis_summary",JSONObject().put("bpm",JSONObject().put("value",if(id==1)120 else 100)))
                        .put("cover_art_url",ProductTransportFixture.origin.resolve("/cover-$id.png").toString()))
                    return MockResponse.Builder().body(JSONObject().put("tracks",rows).put("total",2).put("limit",20).put("offset",request.url.queryParameter("offset")?.toIntOrNull() ?: 0).toString()).build()
                }
                if(path=="/api/v1/me/plays/recent"||path=="/api/v1/me/plays/top") {
                    val rows=JSONArray()
                    if(path.endsWith("recent"))for(id in 1..2)rows.put(JSONObject().put("id",id).put("title","Tempo $id").put("artist","Synthetic ensemble").put("durationMs",120000).put("inLibrary",true).put("coverArtUrl",ProductTransportFixture.origin.resolve("/cover-$id.png").toString()))
                    return MockResponse.Builder().body(JSONObject().put("tracks",rows).toString()).build()
                }
                return original.dispatch(request)
            }
        }
        var model:ProductViewModel?=null
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("shared-media@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onNodeWithContentDescription("Password").performImeAction()
            model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val active=model
            compose.waitUntil(15000){active.library.value.rows.size==2}
            compose.waitUntil(10000){pixels(art("Tempo 1"),android.graphics.Color.MAGENTA)>100}
            val libraryBounds=compose.onNode(row("Tempo 1")).fetchSemanticsNode().boundsInRoot
            compose.onNodeWithText("Home").performClick()
            compose.waitUntil(10000){active.home.recent.value.rows.size==2}
            compose.waitUntil(10000){pixels(art("Tempo 1"),android.graphics.Color.MAGENTA)>100}
            val homeBounds=compose.onNode(row("Tempo 1")).fetchSemanticsNode().boundsInRoot
            assertEquals(libraryBounds.height,homeBounds.height,.5f);assertEquals(libraryBounds.width,homeBounds.width,.5f);assertEquals(libraryBounds.left,homeBounds.left,.5f)
            pixels(art("Tempo 1"),android.graphics.Color.MAGENTA,"shared-media-home.png")
            compose.onNode(row("Tempo 1")).performClick()
            compose.waitUntil(15000){active.playback.value.isPlaying}
            compose.waitUntil(10000){pixels(hasTestTag("compact-artwork"),android.graphics.Color.MAGENTA)>100}
            compose.onNodeWithContentDescription("Tempo 1, Synthetic ensemble").performClick()
            compose.onNodeWithTag("player-window").assertIsDisplayed()
            compose.waitUntil(10000){pixels(hasTestTag("player-artwork"),android.graphics.Color.MAGENTA)>100}
            pixels(hasTestTag("player-artwork"),android.graphics.Color.MAGENTA,"shared-media-player.png")
            compose.onNode(hasContentDescription("Open listening queue") and hasAnyAncestor(isDialog())).performClick()
            compose.onNode(row("Tempo 1",true)).assertIsDisplayed()
            compose.waitUntil(10000){pixels(art("Tempo 1",true),android.graphics.Color.MAGENTA)>100&&pixels(art("Tempo 2",true),android.graphics.Color.CYAN)>100}
            compose.onNode(hasContentDescription("Pause") and hasAnyAncestor(isDialog())).performClick()
            compose.onNodeWithText("Waveforms").performClick()
            compose.waitUntil(10000){active.timeline.value.document.clips.size==2}
            compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog())).performClick()
            compose.waitUntil(15000){active.playback.value.arrangement!=null&&active.playback.value.isPlaying}
            compose.onNodeWithText("List").performClick()
            compose.onNodeWithContentDescription("Arrangement tracks, 2 songs").assertIsDisplayed()
            compose.onNode(row("Tempo 1",true)).assertIsDisplayed();compose.onNode(row("Tempo 2",true)).assertIsDisplayed()
            compose.waitUntil(10000){pixels(art("Tempo 1",true),android.graphics.Color.MAGENTA)>100&&pixels(art("Tempo 2",true),android.graphics.Color.CYAN)>100}
            compose.waitUntil(10000){pixels(hasTestTag("compact-artwork") and hasAnyAncestor(isDialog()),android.graphics.Color.MAGENTA)>100}
            pixels(art("Tempo 1",true),android.graphics.Color.MAGENTA,"shared-media-arrangement.png")
            val accepted=active.playback.value.arrangement!!
            val second=accepted.document.clips[1]
            compose.onNode(row("Tempo 2",true)).performClick()
            compose.waitUntil(15000){!active.playback.value.isPlaying&&kotlin.math.abs(active.playback.value.positionMs-second.globalStartMs)<=1}
            assertEquals(accepted.identity,active.playback.value.arrangement!!.identity)
            compose.onNodeWithContentDescription("Close Queue").performClick()
            compose.onNodeWithContentDescription("Tempo 2, Synthetic ensemble").performClick()
            compose.waitUntil(10000){pixels(hasTestTag("player-artwork"),android.graphics.Color.CYAN)>100}
            assertEquals(accepted.document,active.timeline.value.document)
        }finally{compose.runOnIdle {model?.controller?.pause()};ProductTransportFixture.server.dispatcher=original}
    }
}
