package com.soundq.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.product.artwork.TrackArtwork
import com.soundq.designsystem.SoundQTheme
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/** Same row/track/scope remains mounted while accepted source authority changes. */
class ArtworkOwnerReplacementTest {
    @get:Rule val compose=createComposeRule()
    @Test fun acceptedOwnerReplacementReacquiresSameTrackWithoutRevivingPriorOwner() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        val original=ProductTransportFixture.server.dispatcher
        val requests=AtomicInteger()
        val bytes=Bitmap.createBitmap(80,80,Bitmap.Config.ARGB_8888).let {image->
            try {image.eraseColor(android.graphics.Color.MAGENTA);java.io.ByteArrayOutputStream().also {image.compress(Bitmap.CompressFormat.PNG,100,it)}.toByteArray()}finally{image.recycle()}
        }
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath!="/owner-art.png")return original.dispatch(request)
                assertNull(request.headers["Authorization"]);requests.incrementAndGet()
                return MockResponse.Builder().body(Buffer().write(bytes)).build()
            }
        }
        graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","owner-test"))
        val scope=graph.session.capture()!!
        val track=Track(TrackId(7),"Retained occurrence",artwork=ProductTransportFixture.origin.resolve("/owner-art.png").toString())
        val owner=mutableStateOf(1)
        fun painted():Boolean {
            val image=compose.onNodeWithTag("owner-art").captureToImage().toPixelMap()
            return image[image.width/2,image.height/2]==androidx.compose.ui.graphics.Color.Magenta
        }
        try {
            compose.setContent {SoundQTheme {
                val captured=owner.value
                Box(Modifier.testTag("owner-art")) {TrackArtwork(graph,scope,track,{owner.value==captured},sourceOwner=captured)}
            }}
            compose.waitUntil(8000){painted()&&requests.get()==1}
            compose.runOnIdle {owner.value=2}
            compose.waitUntil(8000){painted()&&requests.get()==2}
            compose.runOnIdle {owner.value=1}
            compose.waitUntil(8000){painted()&&requests.get()==3}
            compose.runOnIdle {graph.session.retire()}
            compose.waitUntil(8000){!painted()}
        }finally{ProductTransportFixture.server.dispatcher=original;graph.session.retire()}
    }
}
