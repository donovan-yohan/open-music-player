package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
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
import java.util.concurrent.atomic.AtomicInteger

/** Product consumer acceptance. Parent runs this after Home/queue slot integration with ProductFixtureRunner. */
class ArtworkSurfacesJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun colored(node:SemanticsNodeInteraction):Int {
        val semantics=node.fetchSemanticsNode()
        val root=semantics.root as ViewRootForTest
        val bounds=semantics.boundsInRoot
        return compose.runOnIdle {
            val view=root.view
            val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
            try {
                view.draw(Canvas(bitmap))
                var count=0
                for(y in kotlin.math.ceil(bounds.top).toInt() until kotlin.math.floor(bounds.bottom).toInt())
                    for(x in kotlin.math.ceil(bounds.left).toInt() until kotlin.math.floor(bounds.right).toInt())
                        if(bitmap.getPixel(x,y)==android.graphics.Color.MAGENTA)count++
                count
            } finally {bitmap.recycle()}
        }
    }
    @Test fun acceptedHomeBeforePlayThenQueueCompactFullAndAccountRetirementPaintActualArt() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        val original=ProductTransportFixture.server.dispatcher
        val images=AtomicInteger()
        val cover=Bitmap.createBitmap(640,640,Bitmap.Config.ARGB_8888).let {image->
            try {image.eraseColor(android.graphics.Color.MAGENTA);java.io.ByteArrayOutputStream().also {check(image.compress(Bitmap.CompressFormat.PNG,100,it))}.toByteArray()}
            finally {image.recycle()}
        }
        val title="Home artwork before play"
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                fun reply(body:String)=MockResponse.Builder().body(body).build()
                return when(request.url.encodedPath) {
                    "/api/v1/library" -> reply("""{"tracks":[],"total":0,"limit":20,"offset":0}""")
                    "/api/v1/me/plays/recent" -> reply("""{"tracks":[{"id":7,"title":"$title","artist":"Artwork fixture","durationMs":12000,"coverArtUrl":"${ProductTransportFixture.origin.resolve("/shared-art.png")}","inLibrary":true}]}""")
                    "/api/v1/me/plays/top" -> reply("""{"tracks":[]}""")
                    "/shared-art.png" -> {
                        assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"]);images.incrementAndGet()
                        MockResponse.Builder().body(Buffer().write(cover)).build()
                    }
                    else -> original.dispatch(request)
                }
            }
        }
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("artwork-fixture@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){!graph.library.state.value.loading&&graph.session.capture()!=null}
            compose.onNodeWithText("Home").performClick()
            compose.waitUntil(10000){graph.home.recent.value.rows.singleOrNull()?.track?.title==title}
            assertNull("Home must not require catalog insertion before play",graph.track(com.soundq.android.data.TrackId(7)))
            val homeRow=hasText(title) and hasClickAction() and hasAnyDescendant(hasContentDescription("More for $title"))
            val homeArt=hasTestTag("media-artwork") and hasAnyAncestor(hasClickAction() and hasAnyDescendant(hasText(title)) and hasAnyDescendant(hasContentDescription("More for $title")))
            compose.waitUntil(8000){compose.onAllNodes(homeArt,useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()&&colored(compose.onNode(homeArt,useUnmergedTree=true))>100&&images.get()>0}
            compose.onNode(homeRow).performClick()
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(15000){model.playback.value.isPlaying}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(5000){!model.playback.value.isPlaying}
            compose.waitUntil(8000){colored(compose.onNodeWithTag("compact-artwork",useUnmergedTree=true))>100}
            compose.onNode(hasContentDescription("$title, Artwork fixture") and hasClickAction()).performClick()
            compose.waitUntil(8000){colored(compose.onNodeWithTag("player-artwork",useUnmergedTree=true))>100}
            compose.onNode(hasContentDescription("Open listening queue") and hasAnyAncestor(isDialog())).performClick()
            compose.onNodeWithText("Queue").assertIsDisplayed()
            val queueArt=hasTestTag("media-artwork") and hasAnyAncestor(isDialog())
            compose.waitUntil(8000){compose.onAllNodes(queueArt,useUnmergedTree=true).fetchSemanticsNodes().size==1&&
                colored(compose.onNode(queueArt,useUnmergedTree=true))>100}
            compose.runOnIdle {graph.session.retire()}
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            assertEquals(0,colored(compose.onNodeWithContentDescription("Email")))
        } finally {ProductTransportFixture.server.dispatcher=original;graph.session.retire()}
    }
}
