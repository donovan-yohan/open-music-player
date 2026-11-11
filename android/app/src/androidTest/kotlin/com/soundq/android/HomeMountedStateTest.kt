package com.soundq.android

import androidx.activity.compose.setContent
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.SecretTokens
import com.soundq.android.data.home.*
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.home.HomeDestinationScreen
import com.soundq.designsystem.SoundQTheme
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Small actual destination boundary; ordinary launch/service journey remains a separate gate. */
class HomeMountedStateTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    @Test fun initiallyUnownedDestinationObservesAcceptedReadsAndRetiresOldRoutes() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val fallback=ProductTransportFixture.server.dispatcher
        val entered=CountDownLatch(2)
        val release=CountDownLatch(1)
        var recentReads=0
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(path !in setOf("/api/v1/me/plays/recent","/api/v1/me/plays/top","/api/v1/me/plays/history"))return fallback.dispatch(request)
                if(path!="/api/v1/me/plays/history") {
                    entered.countDown()
                    check(release.await(5,TimeUnit.SECONDS)) {"held Home read not released"}
                }
                val body=when(path) {
                    "/api/v1/me/plays/recent" -> {
                        recentReads++
                        if(recentReads==2)return MockResponse.Builder().code(503).body("{}").build()
                        if(recentReads==3) """{"tracks":[]}"""
                        else """{"tracks":[{"id":1,"title":"Accepted mounted recent","inLibrary":true}]}"""
                    }
                    "/api/v1/me/plays/top" -> """{"tracks":[]}"""
                    else -> """{"plays":[{"id":81,"track":{"id":1,"title":"Accepted mounted history","inLibrary":true},"playedAt":"2026-10-28T00:00:00Z","skipped":false}],"limit":50,"offset":0}"""
                }
                return MockResponse.Builder().body(body).build()
            }
        }
        var lifetime:HomeRouteLifetime?=null
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("mounted-home@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val owner=HomeRouteLifetime();lifetime=owner
            val first=owner.enter(HomeDestination.Home)
            assertFalse(model.home.owns(first,HomeSection.Recent))
            val route=mutableStateOf<HomeRoute?>(first)
            compose.activity.runOnUiThread {
                compose.activity.setContent { SoundQTheme {
                    val mounted=route.value
                    if(mounted==null)Text("Destination removed")
                    else HomeDestinationScreen(model,mounted,{}, {})
                } }
            }
            compose.waitForIdle()
            assertTrue("both production load actions dispatched",entered.await(5,TimeUnit.SECONDS))
            compose.onNodeWithText("Loading Recently played").assertExists()
            release.countDown()
            compose.waitUntil(5000){model.home.owns(first,HomeSection.Recent)&&model.home.recent.value.rows.size==1&&!model.home.top.value.loading}
            compose.waitForIdle()
            // This is the defect-driving assertion: accepted model data must invalidate mounted content.
            compose.onNodeWithText("Accepted mounted recent").assertIsDisplayed()
            compose.onNodeWithText("Refresh recent").performScrollTo().performClick()
            compose.waitUntil(5000){model.home.recent.value.error!=null}
            compose.onNodeWithText("Accepted mounted recent").assertExists()
            compose.onNodeWithText("Retry Recently played").performScrollTo().performClick()
            compose.waitUntil(5000){!model.home.recent.value.loading&&model.home.recent.value.error==null&&model.home.recent.value.rows.isEmpty()}
            compose.onNodeWithText("No recent plays yet").performScrollTo().assertIsDisplayed()
            val history=compose.runOnIdle {owner.enter(HomeDestination.History).also {route.value=it}}
            compose.waitUntil(5000){model.home.owns(history,HomeSection.History)&&model.home.history.value.rows.size==1}
            compose.onNodeWithText("Accepted mounted history").performScrollTo().assertIsDisplayed()
            assertFalse(model.home.owns(first,HomeSection.Recent))
            compose.runOnIdle {owner.close();route.value=null}
            compose.onNodeWithText("Destination removed").assertIsDisplayed()
            assertFalse(history.current())
            val reopenedOwner=HomeRouteLifetime();lifetime=reopenedOwner
            val reopened=compose.runOnIdle {reopenedOwner.enter(HomeDestination.Home).also {route.value=it}}
            compose.waitUntil(5000){model.home.owns(reopened,HomeSection.Recent)&&!model.home.recent.value.loading&&model.home.recent.value.rows.size==1}
            compose.onNodeWithText("Accepted mounted recent").performScrollTo().assertIsDisplayed()
            // Same account label, new account scope: old route ownership cannot grant rows/actions.
            val oldScope=app.graph.session.capture()!!
            compose.runOnIdle {
                app.graph.session.accept(app.graph.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-r","fixture-account"))
            }
            assertFalse(app.graph.session.current(oldScope))
            assertFalse(model.home.owns(reopened,HomeSection.Recent))
            val replacement=compose.runOnIdle {reopenedOwner.enter(HomeDestination.Home).also {route.value=it}}
            compose.waitUntil(5000){model.home.owns(replacement,HomeSection.Recent)&&!model.home.recent.value.loading&&model.home.recent.value.rows.size==1}
            compose.onNodeWithText("Accepted mounted recent").performScrollTo().assertIsDisplayed()
            assertFalse(first.current());assertFalse(history.current());assertFalse(reopened.current())
        } finally {
            release.countDown();lifetime?.close()
            ProductTransportFixture.server.dispatcher=fallback
            app.graph.session.retire()
        }
    }
}
