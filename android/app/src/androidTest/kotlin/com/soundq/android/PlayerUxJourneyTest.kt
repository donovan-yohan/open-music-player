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
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/** Ordinary Activity and full dialog. Captures are fixture View rasters, not OS screenshots. */
class PlayerUxJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val title="A deliberately long music title for single-line truncation without growing the Library row"
    private val artist="Synthetic ensemble with an intentionally long artist name"
    private fun row()=hasText(title) and hasClickAction() and hasAnyDescendant(hasContentDescription("More for $title"))

    private data class Paint(val magenta:Int,val cyan:Int,val area:Int)
    private fun compact(title:String,artist:String)=compose.onNode(hasContentDescription("$title, $artist") and hasClickAction())

    // Save the WHOLE owning View for diagnosis, but count only the requested slot.
    // boundsInRoot and ViewRootForTest.view share the Compose root coordinate space.
    private fun raster(node:SemanticsNodeInteraction,name:String,compactSlot:Boolean=false):Paint {
        val semantics=node.fetchSemanticsNode()
        val root=semantics.root as ViewRootForTest
        val bounds=semantics.boundsInRoot
        val right=if(compactSlot)bounds.left+72f*compose.density.density else bounds.right
        if(compactSlot)assertEquals(72f*compose.density.density,bounds.height,1f)
        return compose.runOnIdle {
            assertTrue(compose.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE==0)
            val view=root.view
            assertTrue(view.width>0&&view.height>0)
            val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
            try {
                view.draw(Canvas(bitmap))
                val directory=File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null),"player-ux-fixture-rasters").also {check(it.mkdirs()||it.isDirectory)}
                File(directory,"$name.png").outputStream().use {check(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}
                val left=kotlin.math.ceil(bounds.left).toInt()
                val top=kotlin.math.ceil(bounds.top).toInt()
                val endX=kotlin.math.floor(right).toInt()
                val endY=kotlin.math.floor(bounds.bottom).toInt()
                assertTrue("Artwork rect must be inside its owning View",left>=0&&top>=0&&endX<=bitmap.width&&endY<=bitmap.height&&endX>left&&endY>top)
                var magenta=0;var cyan=0
                for(y in top until endY)for(x in left until endX)when(bitmap.getPixel(x,y)) {
                    android.graphics.Color.MAGENTA->magenta++
                    android.graphics.Color.CYAN->cyan++
                }
                Paint(magenta,cyan,(endX-left)*(endY-top))
            } finally {bitmap.recycle()}
        }
    }

    @Test fun artworkInlineControlsAndFullWindowPlayerUseTheOrdinaryRoute() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        val original=ProductTransportFixture.server.dispatcher
        val coverRequests=AtomicInteger()
        fun cover(color:Int)=Bitmap.createBitmap(640,640,Bitmap.Config.ARGB_8888).let {image->
            try {image.eraseColor(color);java.io.ByteArrayOutputStream().also {assertTrue(image.compress(Bitmap.CompressFormat.PNG,100,it))}.toByteArray()}
            finally {image.recycle()}
        }
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/api/v1/library") {
                    val url=ProductTransportFixture.origin.resolve("/player-cover.png")
                    return MockResponse.Builder().body("""{"tracks":[{"id":1,"title":"$title","artist":"$artist","duration_ms":12000,"is_liked":false,"cover_art_url":"$url"},{"id":2,"title":"Second song","artist":"Synthetic ensemble","duration_ms":12000,"is_liked":false,"cover_art_url":"${ProductTransportFixture.origin.resolve("/player-cover-2.png")}"},{"id":3,"title":"No artwork song","artist":"Synthetic ensemble","duration_ms":12000,"is_liked":false}],"total":3,"limit":20,"offset":0}""").build()
                }
                if(request.url.encodedPath in listOf("/player-cover.png","/player-cover-2.png")) {
                    assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"])
                    coverRequests.incrementAndGet()
                    return MockResponse.Builder().addHeader("Content-Type","image/png").body(Buffer().write(cover(if(request.url.encodedPath=="/player-cover.png")android.graphics.Color.MAGENTA else android.graphics.Color.CYAN))).build()
                }
                return original.dispatch(request)
            }
        }
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("player-ux@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.rows.size==3&&!graph.library.state.value.loading}
            compose.onNode(row()).assertIsDisplayed().performClick()
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(5000){!model.playback.value.isPlaying}
            compose.onNodeWithText("Current").assertDoesNotExist()
            compose.waitUntil(8000){
                val paint=raster(compact(title,artist),"library-compact",compactSlot=true)
                coverRequests.get()>0&&paint.magenta>paint.area*0.8&&paint.cyan==0
            }
            compact(title,artist).performClick()
            compose.onNodeWithText("Now playing").assertIsDisplayed()
            compose.waitUntil(8000){
                val paint=raster(compose.onNodeWithTag("player-artwork",useUnmergedTree=true),"full-player")
                paint.magenta>paint.area*0.8&&paint.cyan==0
            }
            val root=compose.onNodeWithText("Now playing").fetchSemanticsNode().root as ViewRootForTest
            val rootHeight=compose.runOnIdle {root.view.height}
            val toolbar=compose.onNodeWithText("Now playing").fetchSemanticsNode().boundsInRoot
            assertTrue(rootHeight>toolbar.height*5)
            val controls=listOf("Shuffle off","Previous track","Play","Next track","Repeat off")
            val nodes=controls.map {compose.onNode(hasContentDescription(it) and hasAnyAncestor(isDialog())).assertIsDisplayed().fetchSemanticsNode().boundsInRoot}
            nodes.zipWithNext().forEach {(a,b)->assertTrue(a.right<=b.left+1f);assertEquals(a.center.y,b.center.y,2f)}
            compose.onNodeWithContentDescription("Playback position").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress){it(.25f)}
            compose.waitUntil(5000){model.playback.value.positionMs in 2900L..3100L}
            val occurrence=model.playback.value.selectedOccurrence
            compose.onNodeWithContentDescription("Close Now playing").performClick()
            compose.onNode(row()).assertIsDisplayed()
            assertEquals(occurrence,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            assertTrue(model.playback.value.positionMs in 2900L..3100L)
            // Replace the selection while the full-player artwork slot stays mounted.
            compact(title,artist).performClick()
            compose.onNodeWithContentDescription("Next track").performClick()
            compose.waitUntil(10000){model.playback.value.title=="Second song"&&model.playback.value.selectedOccurrence!=occurrence}
            compose.waitUntil(8000){
                val paint=raster(compose.onNodeWithTag("player-artwork",useUnmergedTree=true),"full-player-new-selection")
                paint.cyan>paint.area*0.8&&paint.magenta==0
            }
            compose.onNodeWithContentDescription("Close Now playing").performClick()
            compose.waitUntil(8000){
                val paint=raster(compact("Second song","Synthetic ensemble"),"compact-new-selection",compactSlot=true)
                paint.cyan>paint.area*0.8&&paint.magenta==0
            }
            // A known source without an artwork URL retires the colored lease.
            // Require fallback pixels in both consuming slots, not just new metadata.
            compact("Second song","Synthetic ensemble").performClick()
            compose.onNodeWithContentDescription("Next track").performClick()
            compose.waitUntil(10000){model.playback.value.title=="No artwork song"}
            compose.waitUntil(8000){
                val paint=raster(compose.onNodeWithTag("player-artwork",useUnmergedTree=true),"full-player-retired-artwork")
                paint.magenta==0&&paint.cyan==0
            }
            compose.onNodeWithContentDescription("Close Now playing").performClick()
            compose.waitUntil(8000){
                val paint=raster(compact("No artwork song","Synthetic ensemble"),"compact-retired-artwork",compactSlot=true)
                paint.magenta==0&&paint.cyan==0
            }
        } finally {ProductTransportFixture.server.dispatcher=original;graph.session.retire()}
    }
}
