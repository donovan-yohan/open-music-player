package com.soundq.android

import androidx.activity.compose.setContent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.soundq.android.product.playlists.PlaylistCreateBinding
import com.soundq.android.product.playlists.PlaylistReloadBinding
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.soundq.android.product.ProductViewModel
import kotlinx.coroutines.*
import com.soundq.android.product.ProductApp
import androidx.compose.material3.Text
import com.soundq.android.data.playlists.PlaylistState
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Separate playlist fixture; frozen core journey and fixture implementation remain untouched. */
class PrivatePlaylistJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun nativePrivateCreateWaitsForAcknowledgementThenShowsAuthoritativeList() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        val original = ProductTransportFixture.server.dispatcher
        val fixture = PrivatePlaylistJourneyFixture(original)
        ProductTransportFixture.server.dispatcher = fixture
        try {
            compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Email").performTextInput("playlist@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000) { app.graph.session.capture() != null && compose.onAllNodesWithText("Playlists").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000) { app.graph.playlists.state.value.total == 0 }
            compose.onNodeWithContentDescription("Create playlist").performClick()
            compose.onNodeWithText("Playlist name").performTextInput("海辺 — Étude")
            compose.onNodeWithText("Playlist description").performTextInput("Night listening")
            compose.onNode(hasText("Create playlist") and hasClickAction()).performScrollTo().performClick()
            assertTrue(fixture.entered.await(5, TimeUnit.SECONDS))
            compose.onAllNodesWithText("Creating playlist").filterToOne(hasClickAction()).assertIsNotEnabled()
            assertNull(app.graph.playlists.state.value.created)
            assertTrue(app.graph.playlists.state.value.rows.isEmpty())
            fixture.release.countDown()
            compose.waitUntil(10000) { app.graph.playlists.state.value.mutation?.outcome == MutationOutcome.Confirmed }
            compose.onNodeWithText("Playlist created").performScrollTo().assertIsDisplayed()
            val accepted = app.graph.playlists.state.value
            assertEquals(41L, accepted.created!!.id.value)
            assertEquals(accepted.created, accepted.rows.single())
            assertEquals(listOf("GET", "POST", "GET"), fixture.methods.toList())
            assertEquals("""{"name":"海辺 — Étude","description":"Night listening","coverUrl":"","isPublic":false}""", fixture.body)
        } finally {
            fixture.release.countDown()
            ProductTransportFixture.server.dispatcher = original
            app.graph.playlists.retire()
            app.graph.session.retire()
        }
    }
    @Test fun nativeUncertainCreateRequiresReadThenExplicitDifferentIntentAndRejectsRetainedSubmit() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        val original = ProductTransportFixture.server.dispatcher
        val fixture = RecoveryPlaylistJourneyFixture(original)
        ProductTransportFixture.server.dispatcher = fixture
        try {
            signInAndOpen(app)
            compose.onNodeWithContentDescription("Create playlist").performClick()
            compose.onNodeWithText("Playlist name").performTextInput("Uncertain original")
            val oldSubmit = compose.onNode(hasText("Create playlist") and hasClickAction()).performScrollTo().fetchSemanticsNode().config[PlaylistCreateBinding]
            compose.onNode(hasText("Create playlist") and hasClickAction()).performClick()
            compose.waitUntil(10000) { app.graph.playlists.state.value.mutation?.outcome == MutationOutcome.Uncertain }
            compose.onNode(hasText("Create playlist") and hasClickAction()).assertIsNotEnabled()
            settleAction(oldSubmit)
            assertEquals(1, fixture.posts.size)
            assertNull(app.graph.playlists.state.value.created)
            // A lazy footer need not be composed while uncertainty feedback/IME is expanded.
            // Scroll the real LazyColumn to its binding rather than asking an absent node to scroll.
            revealPlaylist(SemanticsMatcher.keyIsDefined(PlaylistReloadBinding)).assertIsDisplayed().performClick()
            compose.waitUntil(10000) { fixture.methods.size==3 && !app.graph.playlists.state.value.loading && app.graph.playlists.state.value.error != null }
            revealPlaylist(hasText("Create playlist") and hasClickAction()).assertIsNotEnabled()
            revealPlaylist(SemanticsMatcher.keyIsDefined(PlaylistReloadBinding)).assertIsDisplayed().performClick()
            compose.waitUntil(10000) { app.graph.playlists.state.value.reconciled }
            revealPlaylist(hasText("Playlist name")).performTextReplacement("Deliberately new")
            revealPlaylist(hasText("Create playlist") and hasClickAction()).assertIsNotEnabled()
            revealPlaylist(hasText("Start a different playlist") and hasClickAction()).assertIsEnabled().performClick()
            revealPlaylist(hasText("Create playlist") and hasClickAction()).assertIsEnabled()
            settleAction(oldSubmit)
            assertEquals(1, fixture.posts.size)
            assertNull(app.graph.playlists.state.value.created)
            assertEquals(MutationOutcome.Uncertain, app.graph.playlists.state.value.mutation?.outcome)
            compose.onNode(hasText("Create playlist") and hasClickAction()).performClick()
            compose.waitUntil(10000) { app.graph.playlists.state.value.mutation?.outcome == MutationOutcome.Confirmed }
            compose.onNodeWithText("Playlist created").performScrollTo().assertIsDisplayed()
            assertEquals("Deliberately new", app.graph.playlists.state.value.created!!.name)
            assertEquals(listOf("Uncertain original", "Deliberately new"), fixture.posts.toList())
            assertEquals(listOf("GET", "POST", "GET", "GET", "POST", "GET"), fixture.methods.toList())
        } finally {
            ProductTransportFixture.server.dispatcher = original
            app.graph.playlists.retire(); app.graph.session.retire()
        }
    }

    @Test fun nativeCreateCancelRetainsMountedDraftWithoutDispatch() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        val original = ProductTransportFixture.server.dispatcher
        val fixture = RecoveryPlaylistJourneyFixture(original)
        ProductTransportFixture.server.dispatcher = fixture
        try {
            signInAndOpen(app)
            compose.onAllNodesWithText("Playlist name").assertCountEquals(0)
            compose.onNodeWithContentDescription("Create playlist").performClick()
            compose.onNodeWithText("Playlist name").performTextInput("Unsent evening")
            compose.onNodeWithText("Playlist description").performTextInput("Keep on cancel")
            compose.onNodeWithText("Cancel").performScrollTo().performClick()
            compose.onAllNodesWithText("Playlist name").assertCountEquals(0)
            assertTrue(fixture.posts.isEmpty())
            compose.onNodeWithContentDescription("Create playlist").performClick()
            compose.onNode(hasText("Playlist name") and hasSetTextAction()).assertTextContains("Unsent evening")
            compose.onNode(hasText("Playlist description") and hasSetTextAction()).assertTextContains("Keep on cancel")
            assertTrue(fixture.posts.isEmpty())
        } finally {
            ProductTransportFixture.server.dispatcher = original
            app.graph.playlists.retire(); app.graph.session.retire()
        }
    }

    @Test fun nativeShellDisposalAndReopenPermanentlyRetireCapturedReload() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        val original = ProductTransportFixture.server.dispatcher
        val fixture = RecoveryPlaylistJourneyFixture(original)
        ProductTransportFixture.server.dispatcher = fixture
        try {
            signInAndOpen(app)
            val reload = compose.onNode(SemanticsMatcher.keyIsDefined(PlaylistReloadBinding)).performScrollTo().fetchSemanticsNode().config[PlaylistReloadBinding]
            val count = fixture.methods.size
            compose.activity.runOnUiThread { compose.activity.setContent { Text("Shell removed") } }
            compose.waitForIdle()
            assertEquals(PlaylistState(), app.graph.playlists.state.value)
            settleAction(reload)
            assertEquals(count, fixture.methods.size)
            compose.activity.runOnUiThread { compose.activity.setContent { ProductApp() } }
            compose.waitUntil(10000) { compose.onAllNodesWithText("Playlists").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000) { fixture.methods.size == count + 1 && !app.graph.playlists.state.value.loading }
            settleAction(reload)
            assertEquals(count + 1, fixture.methods.size)
            compose.onNode(SemanticsMatcher.keyIsDefined(PlaylistReloadBinding)).performScrollTo().performClick()
            compose.waitUntil(10000) { fixture.methods.size == count + 2 && !app.graph.playlists.state.value.loading }
        } finally {
            ProductTransportFixture.server.dispatcher = original
            app.graph.playlists.retire(); app.graph.session.retire()
        }
    }

    private fun revealPlaylist(matcher:SemanticsMatcher):SemanticsNodeInteraction {
        val inSheet = matcher and hasAnyAncestor(isDialog())
        if (compose.onAllNodes(inSheet).fetchSemanticsNodes().isNotEmpty()) return compose.onNode(inSheet).performScrollTo()
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(matcher)
        return compose.onNode(matcher)
    }

    private fun settleAction(action:()->Unit) {
        val admitted=compose.runOnIdle {
            val model=ViewModelProvider(compose.activity)[ProductViewModel::class.java]
            admittedActionJobs(model.viewModelScope.coroutineContext[Job]!!,action)
        }
        runBlocking {withTimeout(5000) {admitted.forEach {it.join()}}}
        compose.waitForIdle()
    }

    private fun signInAndOpen(app: SoundQApplication) {
        compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("Email").performTextInput("playlist@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000) { app.graph.session.capture() != null && compose.onAllNodesWithText("Playlists").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Playlists").performClick()
        compose.waitUntil(10000) { app.graph.playlists.state.value.total == 0 && !app.graph.playlists.state.value.loading }
    }
}

private class RecoveryPlaylistJourneyFixture(private val fallback: Dispatcher) : Dispatcher() {
    val methods = java.util.concurrent.CopyOnWriteArrayList<String>()
    val posts = java.util.concurrent.CopyOnWriteArrayList<String>()
    private var reads = 0
    private var created = false
    private val summary = """{"id":42,"name":"Deliberately new","isPublic":false,"trackCount":0,"durationMs":0}"""
    override fun dispatch(request: RecordedRequest): MockResponse {
        if (request.url.encodedPath != "/api/v1/playlists") return fallback.dispatch(request)
        methods.add(request.method)
        if (request.method == "POST") {
            posts.add(kotlinx.serialization.json.Json.parseToJsonElement(request.body!!.utf8()).let {
                (it as kotlinx.serialization.json.JsonObject).getValue("name").let { name -> (name as kotlinx.serialization.json.JsonPrimitive).content }
            })
            if (posts.size == 1) return MockResponse.Builder().code(503).body("{}").build()
            created = true
            return MockResponse.Builder().code(201).body(summary).build()
        }
        reads++
        if (reads == 2 && posts.isNotEmpty()) return MockResponse.Builder().code(503).body("{}").build()
        return MockResponse.Builder().body("""{"data":[${if(created) summary else ""}],"total":${if(created) 1 else 0},"limit":20,"offset":0}""").build()
    }
}

private class PrivatePlaylistJourneyFixture(private val fallback: Dispatcher) : Dispatcher() {
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val methods = java.util.concurrent.CopyOnWriteArrayList<String>()
    @Volatile var body: String? = null
    @Volatile private var created = false
    private val summary = """{"id":41,"name":"海辺 — Étude","description":"Night listening","isPublic":false,"trackCount":0,"durationMs":0}"""
    override fun dispatch(request: RecordedRequest): MockResponse {
        if (request.url.encodedPath != "/api/v1/playlists") return fallback.dispatch(request)
        if (request.headers["Authorization"] != "Bearer synthetic-fixture-access") return MockResponse.Builder().code(401).build()
        methods.add(request.method)
        if (request.method == "POST") {
            body = request.body!!.utf8()
            entered.countDown()
            if (!release.await(10, TimeUnit.SECONDS)) return MockResponse.Builder().code(503).build()
            created = true
            return MockResponse.Builder().code(201).body(summary).build()
        }
        return MockResponse.Builder().body("""{"data":[${if (created) summary else ""}],"total":${if (created) 1 else 0},"limit":20,"offset":0}""").build()
    }
}
