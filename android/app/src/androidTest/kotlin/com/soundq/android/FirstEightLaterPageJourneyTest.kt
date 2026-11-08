package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsActions

import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.imports.ImportPlaylistPhase
import com.soundq.android.product.ProductViewModel
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Actual ordinary production UI. Only scoped HTTP/account/provider responses are synthetic. */
class FirstEightLaterPageJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val app get()=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
    private fun click(text:String)=compose.onNode(hasText(text) and hasClickAction()).performScrollTo().performClick()
    private fun signIn():ProductViewModel {
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("later-page@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        click("Sign in")
        compose.waitUntil(10000){app.graph.library.state.value.rows.size==3}
        val model=compose.runOnIdle{ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.onNode(hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))).performClick()
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.waitUntil(10000){!model.playback.value.isPlaying&&!model.playback.value.preparing}
        return model
    }
    private fun page(offset:Int):String {
        val ids=if(offset==0)1..20 else 21..21
        val rows=ids.joinToString(","){"""{"id":$it,"name":"Playlist $it","isPublic":false,"trackCount":0,"durationMs":0}"""}
        return """{"data":[$rows],"total":21,"limit":20,"offset":$offset}"""
    }
    private fun detail(member:Boolean=false):String {
        val tracks=if(member)"""{"id":71,"title":"Captured source row","artist":"Synthetic artist","durationMs":12000}""" else ""
        return """{"id":21,"name":"Playlist 21","isPublic":false,"trackCount":${if(member)1 else 0},"durationMs":${if(member)12000 else 0},"tracks":[$tracks]}"""
    }
    @Test fun ordinaryPlaylistBrowsePublishesBothPagesThenOpensExactLaterIdWithoutAutoplay() {
        val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val offsets=CopyOnWriteArrayList<Int>()
        val observationFailure=AtomicReference<Throwable?>()
        var observer:Thread?=null
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath
            if(path=="/api/v1/playlists") {
                val offset=request.url.queryParameter("offset")!!.toInt();offsets.add(offset)
                check(offset==0||offset==20)
                if(offset==20){entered.countDown();check(release.await(10,TimeUnit.SECONDS))}
                return MockResponse.Builder().body(page(offset)).build()
            }
            if(path=="/api/v1/playlists/21")return MockResponse.Builder().body(detail()).build()
            return fallback.dispatch(request)
        }}
        try {
            val model=signIn();val before=model.playback.value
            // Resolve the still-attached ordinary action before arming the IO
            // deadline; semantics lookup can itself wait for UI idleness.
            val openPlaylists=checkNotNull(compose.onAllNodesWithText("Playlists").filterToOne(hasClickAction()).fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            // Compose's click may wait for the held route's IO to settle. Arm a
            // passive observer first; it reads immutable state and releases only
            // after the unchanged no-partial-publication assertions execute.
            observer=Thread({
                try {
                    assertTrue("Second page not requested after attached ordinary UI action",entered.await(5,TimeUnit.SECONDS))
                    assertTrue(app.graph.playlists.state.value.loading)
                    assertTrue(app.graph.playlists.state.value.rows.isEmpty())
                } catch(error:Throwable) {observationFailure.set(error)}
                finally {release.countDown()}
            },"first8-held-playlist-observer").also {it.start()}
            InstrumentationRegistry.getInstrumentation().runOnMainSync {assertTrue(openPlaylists())}
            // Drive the Compose test frame/LaunchedEffect that admits the IO;
            // a raw thread join alone does not advance the test main clock.
            compose.waitForIdle()
            observer.join(10000)
            assertFalse(observer.isAlive)
            observationFailure.get()?.let {throw it}
            compose.waitUntil(10000){!app.graph.playlists.state.value.loading&&app.graph.playlists.state.value.rows.size==21}
            assertEquals(listOf(0,20),offsets.toList())
            val target=hasText("Playlist 21") and hasClickAction()
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(target)
            compose.onNode(target).assertIsDisplayed()
            captureListeningStage("first8-playlist-later-page-21")
            compose.onNode(target).performClick()
            compose.waitUntil(10000){app.graph.playlistDetail.state.value.detail?.playlist?.id?.value==21L}
            assertEquals(21L,app.graph.playlistDetail.state.value.detail!!.playlist.id.value)
            assertEquals(before.queue,model.playback.value.queue)
            assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            captureListeningStage("first8-playlist-21-opened")
            compose.onNodeWithContentDescription("Back to playlists").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.playlistDetail.state.value.id==null}
            assertEquals(21,app.graph.playlists.state.value.rows.size)
            assertEquals(before.queue,model.playback.value.queue)
            assertFalse(model.playback.value.isPlaying)
        } finally {release.countDown();observer?.join(10000);check(observer?.isAlive!=true);server.dispatcher=fallback;app.graph.session.retire()}
    }
    @Test fun capturedSourceTarget21CancelStaleExplicitImportCheckMembershipAndOpenNeverAutoplay() {
        val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val decisions=AtomicInteger();val publications=AtomicInteger();val libraryPresent=AtomicBoolean();val membershipPresent=AtomicBoolean()
        val offsets=CopyOnWriteArrayList<Int>();val paths=CopyOnWriteArrayList<String>()
        val selection="123e4567-e89b-12d3-a456-426614174010"
        val decision="123e4567-e89b-12d3-a456-426614174020"
        val job="123e4567-e89b-12d3-a456-426614174071"
        val candidate="""{"candidateId":"captured-21","provider":"youtube","sourceUrl":"https://youtu.be/fixture21","title":"Captured source 21","artist":"Synthetic artist","downloadable":true,"playable":false}"""
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath;paths.add(request.method+" "+path)
            fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
            if(path=="/api/v1/discovery/search")return reply("""{"query":"Captured source","results":[$candidate],"providers":[{"provider":"youtube","status":"ok"}],"selectionRequired":true,"selectionSessionId":"$selection","selectionExpiresAt":"2030-01-01T00:00:00Z"}""")
            if(path=="/api/v1/playlists") {
                val offset=request.url.queryParameter("offset")!!.toInt();offsets.add(offset);check(offset==0||offset==20)
                return reply(page(offset))
            }
            if(path=="/api/v1/source-selections"&&request.method=="POST") {
                decisions.incrementAndGet();val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                check(body.getValue("sessionId").jsonPrimitive.content==selection&&body.getValue("candidateId").jsonPrimitive.content=="captured-21")
                return reply("""{"id":"$decision","sessionId":"$selection","selectedCandidateId":"captured-21","action":"selected","selectedCandidate":$candidate}""",201)
            }
            if(path=="/api/v1/queue/items"&&request.method=="POST") {
                publications.incrementAndGet();val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                check(body.getValue("sourceDecisionId").jsonPrimitive.content==decision&&body.getValue("playlistId").jsonPrimitive.long==21L&&body.getValue("position").jsonPrimitive.content=="last")
                return reply("""{"queue":{"items":[]},"downloadJobId":"$job","idempotent":false}""",202)
            }
            if(path=="/api/v1/downloads/$job")return reply("""{"job_id":"$job","status":"complete","progress":100,"track_id":71,"source_type":"youtube","created_at":"2026-10-29T00:00:00Z"}""")
            if(path=="/api/v1/library"&&request.url.queryParameter("limit")=="100") {
                // Canonical membership reads use the Go100-row projection,
                // including required metadata flags; not the20-row fallback.
                val rows=if(libraryPresent.get())"""{"id":71,"title":"Captured source row","artist":"Synthetic artist","duration_ms":12000,"is_liked":false,"mb_verified":false,"has_metadata_override":false}""" else ""
                return reply("""{"tracks":[$rows],"total":${if(libraryPresent.get())1 else 0},"limit":100,"offset":0}""")
            }
            if(path=="/api/v1/playlists/21")return reply(detail(membershipPresent.get()))
            return fallback.dispatch(request)
        }}
        try {
            val model=signIn();val before=model.playback.value
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Search sources").performTextInput("Captured source")
            compose.onNodeWithContentDescription("Search",useUnmergedTree=true).performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Captured source 21").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Captured source 21").performScrollTo().performClick()
            click("Import source")
            val retainedPlan=app.graph.imports.state.value.sourcePlan!!
            // Retain the actual canonical command's captured route/plan. A
            // detached Compose clickable wrapper throws before reaching product
            // admission and therefore is not evidence for this stale guard.
            val retained={model.confirmSourceImport(retainedPlan.view,retainedPlan)}
            compose.onNodeWithContentDescription("Close Import source").performScrollTo().performClick()
            compose.waitUntil(5000){app.graph.imports.state.value.sourcePlan==null}
            compose.runOnIdle{retained()}
            assertEquals(0,decisions.get());assertEquals(0,publications.get())
            click("Import source");click("Choose playlist")
            compose.waitUntil(10000){app.graph.imports.state.value.playlistChoices.size==20&&!app.graph.imports.state.value.loading}
            click("More playlists")
            compose.waitUntil(10000){app.graph.imports.state.value.playlistChoices.size==21&&!app.graph.imports.state.value.loading}
            click("Playlist 21")
            assertEquals(listOf(0,20),offsets.toList())
            assertEquals(21L,app.graph.imports.state.value.chosenPlaylist!!.id.value)
            assertEquals(0,decisions.get());assertEquals(0,publications.get())
            captureListeningStage("first8-source-target-21-confirmation")
            click("Import to selected playlist")
            compose.waitUntil(10000){app.graph.imports.state.value.acknowledgement!=null&&!app.graph.imports.state.value.pending}
            compose.onNodeWithContentDescription("Close Source details").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Imports",useUnmergedTree=true).performClick()
            fun checkImport(expected:ImportPlaylistPhase) {
                compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Check import"))
                click("Check import")
                compose.waitUntil(10000){!app.graph.imports.state.value.loading&&app.graph.imports.state.value.playlistConfirmation?.phase==expected}
            }
            checkImport(ImportPlaylistPhase.AwaitingLibrary)
            compose.onNodeWithText("Open playlist").assertDoesNotExist()
            libraryPresent.set(true)
            checkImport(ImportPlaylistPhase.AwaitingMembership)
            compose.onNodeWithText("Open playlist").assertDoesNotExist()
            membershipPresent.set(true)
            checkImport(ImportPlaylistPhase.Confirmed)
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Open playlist"))
            captureListeningStage("first8-source-target-21-membership-confirmed")
            click("Open playlist")
            compose.waitUntil(10000){app.graph.playlistDetail.state.value.detail?.playlist?.id?.value==21L}
            assertEquals(listOf(71L),app.graph.playlistDetail.state.value.detail!!.tracks.map {it.id.value})
            assertEquals(1,decisions.get());assertEquals(1,publications.get())
            assertTrue(paths.count {it=="GET /api/v1/library"}>=4)
            assertTrue(paths.count {it=="GET /api/v1/playlists/21"}>=2)
            assertFalse(paths.any {it=="POST /api/v1/playlists/21/tracks"})
            assertEquals(before.queue,model.playback.value.queue)
            assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            captureListeningStage("first8-source-target-21-opened")
        } finally {server.dispatcher=fallback;app.graph.session.retire()}
    }
}
