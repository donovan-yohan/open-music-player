package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.TrackId
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/** Ordinary playlist route, unchanged accepted detail, actual Activity pause/resume and image pixels. */
class PlaylistArtworkLifecycleJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun resumedPlaylistRenewsRevokedArtworkOwnerWithoutReloadingDetail() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        val original=ProductTransportFixture.server.dispatcher
        val images=AtomicInteger();val reads=AtomicInteger()
        val bytes=Bitmap.createBitmap(80,80,Bitmap.Config.ARGB_8888).let {bitmap->
            try {bitmap.eraseColor(android.graphics.Color.MAGENTA);java.io.ByteArrayOutputStream().also {bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}.toByteArray()}finally{bitmap.recycle()}
        }
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                fun reply(body:String)=MockResponse.Builder().body(body).build()
                return when(request.url.encodedPath) {
                    "/playlist-cover.png"->{assertNull(request.headers["Authorization"]);images.incrementAndGet();MockResponse.Builder().body(Buffer().write(bytes)).build()}
                    "/api/v1/library"->reply("""{"tracks":[{"id":1,"title":"Playlist artwork song","artist":"Synthetic ensemble","duration_ms":120000,"cover_art_url":"${ProductTransportFixture.origin.resolve("/playlist-cover.png")}","is_liked":false}],"total":1,"limit":20,"offset":0}""")
                    "/api/v1/playlists"->reply("""{"data":[{"id":41,"name":"Artwork playlist","isPublic":false,"trackCount":1,"durationMs":120000}],"total":1,"limit":20,"offset":0}""")
                    "/api/v1/playlists/41"->{reads.incrementAndGet();reply("""{"id":41,"name":"Artwork playlist","isPublic":false,"trackCount":1,"durationMs":120000,"tracks":[{"id":1,"title":"Playlist artwork song","artist":"Synthetic ensemble","durationMs":120000}]}""")}
                    else->original.dispatch(request)
                }
            }
        }
        val art=hasTestTag("media-artwork") and hasAnyAncestor(hasClickAction() and hasAnyDescendant(hasText("Playlist artwork song")) and hasAnyDescendant(hasContentDescription("More for Playlist artwork song")))
        fun painted():Boolean {
            val nodes=compose.onAllNodes(art,useUnmergedTree=true).fetchSemanticsNodes()
            if(nodes.size!=1)return false
            val node=nodes.single();val bounds=node.boundsInRoot
            return compose.runOnIdle {
                val view=(node.root as ViewRootForTest).view
                val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                try {view.draw(Canvas(bitmap));bitmap.getPixel(bounds.center.x.toInt(),bounds.center.y.toInt())==android.graphics.Color.MAGENTA}finally{bitmap.recycle()}
            }
        }
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("playlist-art@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onNodeWithContentDescription("Password").performImeAction()
            compose.waitUntil(10000){graph.library.state.value.rows.size==1}
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000){graph.playlists.state.value.rows.size==1}
            compose.onNode(hasText("Artwork playlist") and hasClickAction()).performClick()
            compose.waitUntil(10000){graph.playlistDetail.state.value.detail!=null}
            compose.waitUntil(8000){painted()}
            val accepted=graph.playlistDetail.state.value.detail!!
            assertNull(accepted.tracks.single().artwork)
            assertNotNull(graph.track(TrackId(1))!!.artwork)
            val old=graph.playlistDetail.capturePlayback()!!
            val before=images.get();val readCount=reads.get()
            compose.activityRule.scenario.moveToState(Lifecycle.State.STARTED)
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            compose.waitUntil(8000){painted()}
            assertEquals("A freshly admitted resumed lease reuses cached pixels without another request",before,images.get())
            assertSame(accepted,graph.playlistDetail.state.value.detail)
            assertFalse(graph.playlistDetail.ownsPlayback(old))
            assertEquals(readCount,reads.get())
            assertTrue(graph.controller.state.value.queue.isEmpty());assertFalse(graph.controller.state.value.isPlaying)
        }finally{ProductTransportFixture.server.dispatcher=original;graph.session.retire()}
    }
}
