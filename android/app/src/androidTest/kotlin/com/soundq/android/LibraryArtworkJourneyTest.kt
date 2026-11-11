package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.WindowManager
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.LibraryQuery
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.ceil
import kotlin.math.floor

/** Ordinary ProductApp Library, actual network/BitmapFactory and mounted-root paint. */
class LibraryArtworkJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun canonicalLibraryCoverPaintsAndRemovedRowCannotRetainIt() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        val original=ProductTransportFixture.server.dispatcher
        val images=AtomicInteger()
        val bytes=Bitmap.createBitmap(1537,769,Bitmap.Config.ARGB_8888).let {bitmap ->
            try {
                bitmap.eraseColor(android.graphics.Color.MAGENTA)
                java.io.ByteArrayOutputStream().also {assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}.toByteArray()
            } finally {bitmap.recycle()}
        }
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/api/v1/library") {
                    val fields=request.url.queryParameter("fields").orEmpty().split(',')
                    assertTrue("Actual Go producer needs the canonical field selected", "cover_art_url" in fields)
                    val replacement=request.url.queryParameter("q")=="replacement"
                    val title=if(replacement)"No artwork replacement" else "Canonical artwork song"
                    val cover=if(replacement)"" else ",\"cover_art_url\":\"${ProductTransportFixture.origin.resolve("/library-cover.png")}\""
                    return MockResponse.Builder().body("""{"tracks":[{"id":7,"title":"$title","artist":"Synthetic ensemble","duration_ms":12000,"is_liked":false$cover}],"total":1,"limit":20,"offset":0}""").build()
                }
                if(request.url.encodedPath=="/library-cover.png") {
                    assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"])
                    images.incrementAndGet()
                    return MockResponse.Builder().addHeader("Content-Type","image/png").body(Buffer().write(bytes)).build()
                }
                return original.dispatch(request)
            }
        }
        fun matcher(title:String)=hasText(title) and hasClickAction() and hasAnyDescendant(hasContentDescription("More for $title"))
        fun paintedPixels(title:String):Int {
            val node=compose.onNode(matcher(title)).fetchSemanticsNode()
            val bounds=node.boundsInRoot
            val root=node.root as ViewRootForTest
            return compose.runOnIdle {
                assertTrue(compose.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE==0)
                val view=root.view
                assertTrue(view.width>0&&view.height>0)
                val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                try {
                    view.draw(Canvas(bitmap))
                    val left=ceil(bounds.left).toInt();val right=floor(bounds.right).toInt()
                    val top=ceil(bounds.top).toInt();val bottom=floor(bounds.bottom).toInt()
                    assertTrue(left>=0&&right<=bitmap.width&&top>=0&&bottom<=bitmap.height&&right>left&&bottom>top)
                    var count=0
                    for(y in top until bottom)for(x in left until right)if(bitmap.getPixel(x,y)==android.graphics.Color.MAGENTA)count++
                    count
                } finally {bitmap.recycle()}
            }
        }
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("library-art@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.rows.singleOrNull()?.title=="Canonical artwork song"}
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(matcher("Canonical artwork song"))
            compose.onNode(matcher("Canonical artwork song")).assertIsDisplayed().assertIsEnabled()
            compose.waitUntil(8000){images.get()>0&&paintedPixels("Canonical artwork song")>100}
            val before=graph.controller.state.value
            assertTrue(before.queue.isEmpty());assertFalse(before.isPlaying)
            val captured=graph.library.captureTrack(graph.library.state.value.rows.single())!!
            // Search lives in the fixed Library header, not inside the lazy rows.
            val search=hasContentDescription("Library search query") and hasSetTextAction()
            compose.onNode(search).assertIsDisplayed().performTextInput("replacement")
            compose.onNode(search).assertTextContains("replacement")
            compose.onNodeWithContentDescription("Search library").assertIsEnabled().performClick()
            try {
                compose.waitUntil(10000){graph.library.state.value.query.text=="replacement"&&graph.library.state.value.rows.singleOrNull()?.title=="No artwork replacement"}
            } catch(failure:Throwable) {
                val observed=graph.library.state.value
                val requests=ProductTransportFixture.requests.filter {it.contains("/library")}
                val editor=runCatching {compose.onNode(search).fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text}.getOrNull()
                failure.addSuppressed(IllegalStateException("ARTWORK_QUERY query=${observed.query.text} editor=$editor rows=${observed.rows.map {it.title}} loading=${observed.loading} error=${observed.error} requests=${requests.takeLast(6)}"))
                throw failure
            }
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(matcher("No artwork replacement"))
            compose.onNode(matcher("No artwork replacement")).assertIsDisplayed().assertIsEnabled()
            compose.runOnIdle {assertFalse(graph.library.owns(captured))}
            assertEquals(0,paintedPixels("No artwork replacement"))
            assertEquals(before.queue,graph.controller.state.value.queue)
            assertEquals(before.selectedOccurrence,graph.controller.state.value.selectedOccurrence)
            assertFalse(graph.controller.state.value.isPlaying)
            assertTrue(ProductTransportFixture.requests.none {it.contains("/playback/urls")})
            assertTrue(images.get() in 1..2)
        } finally {ProductTransportFixture.server.dispatcher=original;graph.session.retire()}
    }
}
