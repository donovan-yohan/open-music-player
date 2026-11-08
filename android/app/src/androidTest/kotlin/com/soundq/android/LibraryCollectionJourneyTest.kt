package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Ordinary ProductApp consuming path. Compile here; sole device owner executes this fixture. */
class LibraryCollectionJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun capture(name:String){compose.waitForIdle();captureListeningStage(name)}
    @Test fun exactArtistAlbumEntryAndWholeLikedPlayShuffleUseCanonicalContext() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val artist=" A%_+ & / 東京 ";val album="100%_+ [Live]"
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            if(request.url.encodedPath!="/api/v1/library")return fallback.dispatch(request)
            val offset=request.url.queryParameter("offset")!!.toInt()
            val liked=request.url.queryParameter("liked")=="true"
            val ids=(1..45).filter {!liked||it%2==1}
            val body=buildJsonObject {
                put("total",ids.size);put("limit",20);put("offset",offset)
                putJsonArray("tracks") {for(id in ids.drop(offset).take(20))addJsonObject {
                    put("id",id);put("title","Collection $id");put("artist",if(id==1||id>=41)artist else "Other")
                    put("album",album);put("is_liked",id%2==1);put("duration_ms",12000)
                }}
            }
            return MockResponse.Builder().body(body.toString()).build()
        }}
        try {
            compose.onNodeWithContentDescription("Email").performTextInput("collections@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.let {state->!state.loading&&state.error==null&&state.rows.size>=20}}
            compose.runOnIdle {assertEquals(artist,graph.library.state.value.rows.first {it.id.value==1L}.artist)}
            compose.onAllNodesWithText("Library").filterToOne(hasClickAction()).performClick()
            capture("library-accepted-source-rows")
            compose.onNodeWithContentDescription("More for Collection 1").assertIsEnabled().performClick()
            capture("library-captured-track-menu")
            compose.onNodeWithText("Open artist in Library").performScrollTo().performClick()
            compose.waitUntil(10000){graph.library.state.value.total==6&&!graph.library.state.value.loading}
            compose.runOnIdle {assertEquals(listOf(1L,41L,42L,43L,44L,45L),graph.library.state.value.rows.map {it.id.value});assertFalse(graph.controller.state.value.isPlaying)}
            capture("library-exact-artist-full-corpus")
            compose.onNodeWithContentDescription("More for Collection 1").assertIsEnabled().performClick()
            compose.onNodeWithText("Open album in Library").performScrollTo().performClick()
            compose.waitUntil(10000){graph.library.state.value.query.collection?.album==album&&!graph.library.state.value.loading}
            capture("library-exact-album")
            compose.onNodeWithContentDescription("Clear collection").performClick()
            compose.waitUntil(10000){graph.library.state.value.query.collection==null&&!graph.library.state.value.loading}
            compose.onNode(hasText("Liked") and SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role,androidx.compose.ui.semantics.Role.Tab)).performClick()
            compose.waitUntil(10000){graph.library.state.value.query.liked&&!graph.library.state.value.loading}
            compose.onNodeWithContentDescription("Play collection").performClick()
            compose.waitUntil(15000){graph.controller.state.value.queue.size==23}
            compose.runOnIdle {
                val p=graph.controller.state.value
                assertEquals((1L..45L step 2).toList(),p.queue.map {it.trackId})
                assertEquals(1L,p.queue.single {it.occurrenceId==p.selectedOccurrence}.trackId)
                graph.controller.pause()
            }
            capture("library-liked-full-context-paused")
            compose.onNodeWithContentDescription("Shuffle collection").performClick()
            compose.waitUntil(15000){!graph.library.state.value.collectionLoading}
            compose.runOnIdle {
                assertNull(graph.library.state.value.collectionError)
                assertEquals((1L..45L step 2).toSet(),graph.controller.state.value.queue.map {it.trackId}.toSet())
                assertEquals(23,graph.controller.state.value.queue.size)
                graph.controller.pause()
            }
            capture("library-liked-shuffle-paused")
        }finally {server.dispatcher=fallback;graph.session.retire()}
    }
}
