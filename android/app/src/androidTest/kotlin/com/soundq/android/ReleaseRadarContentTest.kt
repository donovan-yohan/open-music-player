package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** AUTHORED, NOT EXECUTED. Parent owns all SDK/runtime/native visual admission. */
class ReleaseRadarContentTest {
 @get:Rule val compose=createAndroidComposeRule<MainActivity>()
 @Test fun blankLandingEvidenceFindSourcesAndClearRetainPageWithoutPlaybackOrImport() {
  val instrumentation=InstrumentationRegistry.getInstrumentation()
  val app=instrumentation.targetContext.applicationContext as SoundQApplication
  val server=ProductTransportFixture.server;val old=server.dispatcher
  val requests=CopyOnWriteArrayList<String>()
  val wire=instrumentation.context.assets.open("release-radar-wire.json").bufferedReader().use {it.readText()}
  try {
    server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
     val path=request.url.encodedPath
     if(path.startsWith("/api/v1/me/discovery/")||path.startsWith("/api/v1/discovery/")||path in setOf("/api/v1/source-selections","/api/v1/queue/items","/api/v1/playback/urls"))requests.add(request.method+" "+path)
     val body=when {
      path=="/api/v1/me/discovery/releases"->wire
      path.endsWith("/membership")->"""{"recordingMbid":"33333333-3333-4333-8333-333333333333","inLibrary":false}"""
      path=="/api/v1/discovery/search"->{val q=request.url.queryParameter("q")!!;"""{"query":"$q","results":[{"candidateId":"radar-native-source","provider":"youtube","sourceUrl":"https://youtu.be/synthetic","title":"Synthetic source","artist":"Synthetic listened artist","downloadable":true,"playable":false}],"providers":[{"provider":"youtube","status":"ok"}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}"""}
      else->return old.dispatch(request)
     }
     return MockResponse.Builder().body(body).build()
    }}
   compose.signInThroughSettings("radar-content@example.test","fixture-only-password"){app.graph.session.state.value is AuthState.SignedIn}
   val prepared=app.graph
   val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
   val queue=model.playback.value.queue
   compose.onNode(hasText("Discover") and hasClickAction() and !isHeading()).performClick()
   compose.waitUntil(10000){prepared.discovery.radar.value.page!=null}

   val page=prepared.discovery.radar.value.page!!
   compose.onNodeWithText("New releases").assertExists()
   compose.onNodeWithText("Synthetic newest song").performScrollTo().performClick()
   compose.onNodeWithText("Song evidence").assertIsDisplayed()
   compose.onNodeWithText("Find sources").performScrollTo().performClick()
   compose.waitUntil(10000){prepared.discovery.state.value.results!=null}
   compose.onNodeWithText("Synthetic source").performScrollTo().performClick()
   compose.onNodeWithText("Source details").assertIsDisplayed()
   compose.onNodeWithText("Preview source").assertExists()
   compose.onNodeWithText("Import source").assertExists()
   instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
   compose.onNodeWithContentDescription("Back to previous search").performClick()
   compose.onNodeWithText("Synthetic newest song").performScrollTo().assertIsDisplayed()
   assertSame(page,prepared.discovery.radar.value.page)
   compose.onNodeWithContentDescription("Music search query").performTextInput("ordinary search")
   compose.onNodeWithContentDescription("Clear search").performClick()
   compose.onNodeWithText("Synthetic newest song").performScrollTo().assertIsDisplayed()
   assertSame(page,prepared.discovery.radar.value.page)
   assertTrue(requests.none {it.startsWith("POST ")||it.contains("playback/urls")})
   assertEquals(queue,model.playback.value.queue)
   assertFalse(model.playback.value.isPlaying)
  } finally {
   server.dispatcher=old;app.graph.session.retire()
  }
 }
}
