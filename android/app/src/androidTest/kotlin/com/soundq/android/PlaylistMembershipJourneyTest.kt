package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.MutationOutcome
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

/** Compiled ordinary MainActivity/login journey. Execution belongs to the later native owner. */
class PlaylistMembershipJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    @Test fun libraryPickerHeldAddDuplicateReadRecoveryAndDetailLeaveQueueUntouched() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        val fallback=ProductTransportFixture.server.dispatcher
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        val posts=AtomicInteger();val details=AtomicInteger()
        fun summary()="""{"id":41,"name":"Membership target","isPublic":false,"trackCount":${if(posts.get()>0)1 else 0},"durationMs":${if(posts.get()>0)12000 else 0}}"""
        ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath
            if(path=="/api/v1/playlists/41/tracks") {
                assertEquals("POST",request.method);assertEquals("{\"trackIds\":[1]}",request.body!!.utf8())
                val n=posts.incrementAndGet()
                if(n==1){entered.countDown();check(release.await(10,TimeUnit.SECONDS))}
                return MockResponse.Builder().body("""{"added":[${if(n==1)"1" else ""}],"skipped":[${if(n==1)"" else "1"}],"playlist":${summary()}}""").build()
            }
            if(path=="/api/v1/playlists") return MockResponse.Builder().body("""{"data":[${summary()}],"total":1,"limit":20,"offset":0}""").build()
            if(path=="/api/v1/playlists/41") {
                if(details.incrementAndGet()==1)return MockResponse.Builder().code(503).build()
                return MockResponse.Builder().body(summary().dropLast(1)+""", "tracks":[{"id":1,"title":"Fixture 1","artist":"Synthetic ensemble","durationMs":12000}]}""").build()
            }
            return fallback.dispatch(request)
        }}
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("membership@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.size==3}
            val model=androidx.lifecycle.ViewModelProvider(compose.activity)[com.soundq.android.product.ProductViewModel::class.java]
            val before=model.playback.value
            val library=app.graph.library.state.value
            fun openPicker() {
                compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().performClick()
                compose.onNodeWithText("Add to playlist").performScrollTo().performClick()
                compose.waitUntil(5000){app.graph.playlistMembership.state.value.rows.size==1}
                compose.onNode(hasText("Membership target") and hasClickAction()).performScrollTo().performClick()
                compose.onNodeWithText("Add track to “Membership target”").performScrollTo().performClick()
            }
            openPicker()
            assertTrue(entered.await(5,TimeUnit.SECONDS));assertEquals(1,posts.get())
            assertEquals(MutationOutcome.Pending,app.graph.playlistMembership.state.value.outcome)
            assertNull(app.graph.playlistMembership.state.value.ack)
            compose.onNodeWithText("Adding to playlist").assertExists()
            release.countDown()
            compose.waitUntil(10000){app.graph.playlistMembership.state.value.outcome==MutationOutcome.ReadbackFailed}
            compose.onNodeWithText("Added to “Membership target”").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Check playlist").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.playlistMembership.state.value.detail!=null}
            assertEquals(1,posts.get())
            compose.onNodeWithText("Choose playlist again").performScrollTo().performClick()
            compose.onNode(hasText("Membership target") and hasClickAction()).performScrollTo().performClick()
            compose.onNodeWithText("Add track to “Membership target”").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.playlistMembership.state.value.ack?.skipped?.size==1 && !app.graph.playlistMembership.state.value.loading}
            compose.onNodeWithText("Already in this playlist").performScrollTo().assertIsDisplayed()
            compose.onNodeWithContentDescription("Close Add to playlist").performScrollTo().performClick()
            assertEquals(2,posts.get());assertSame(library,app.graph.library.state.value)
            assertEquals(before.queue,model.playback.value.queue)
            assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertEquals(before.isPlaying,model.playback.value.isPlaying)
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(5000){app.graph.playlists.state.value.rows.size==1}
            compose.onNode(hasText("Membership target") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(5000){app.graph.playlistDetail.state.value.detail!=null}
            assertEquals(listOf(1L),app.graph.playlistDetail.state.value.detail!!.tracks.map {it.id.value})
            assertEquals(before.queue,model.playback.value.queue)
        } finally {
            release.countDown();ProductTransportFixture.server.dispatcher=fallback
            app.graph.playlistMembership.retire();app.graph.playlistDetail.retire();app.graph.session.retire()
        }
    }
}
