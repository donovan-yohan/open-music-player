package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.playback.PlaybackSource
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Actual ProductApp→playlist→Blend→sole Exo/JNI journey with trusted loopback Opus sources. */
class PlaylistBlendJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun generatesReadsBackPlaysTappedOccurrenceSeeksAndSelectsPlainWithoutStopping() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as SoundQApplication
        val opus=instrumentation.context.assets.open("arrangement.opus").use {it.readBytes()}
        val original=ProductTransportFixture.server.dispatcher
        val requests=CopyOnWriteArrayList<String>()
        val id="00000000-0000-4000-8000-000000000041"
        val saved="""{"id":"$id","schemaVersion":1,"name":"Night route Blend","version":1,"clips":[{"clipId":"clip-1","queueItemId":"playlist-41-pos-1","trackId":2,"sourceStartMs":0,"sourceEndMs":12000,"timelineStartMs":0,"timelineEndMs":12000,"gainDb":0,"fadeOutMs":2000,"pitchMode":"preserve","tempoPolicy":"volumeOnly"},{"clipId":"clip-2","queueItemId":"playlist-41-pos-2","trackId":1,"sourceStartMs":0,"sourceEndMs":12000,"timelineStartMs":10000,"timelineEndMs":22000,"gainDb":0,"fadeInMs":2000,"pitchMode":"preserve","tempoPolicy":"volumeOnly"}],"summary":{"clipCount":2,"trackIds":[2,1],"durationMs":22000},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"""
        ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
            val path=r.url.encodedPath
            if(path=="/api/v1/playback/urls")return MockResponse.Builder().body("""{"urls":[{"trackId":1,"url":"${ProductTransportFixture.origin.resolve("/blend-1.opus")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/opus","sizeBytes":${opus.size}},{"trackId":2,"url":"${ProductTransportFixture.origin.resolve("/blend-2.opus")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/opus","sizeBytes":${opus.size}}]}""").build()
            if(path in listOf("/blend-1.opus","/blend-2.opus")) {
                check(r.headers["Authorization"]==null)
                return MockResponse.Builder().setHeader("Content-Type","audio/opus").body(Buffer().write(opus)).build()
            }
            val body=when(path) {
                "/api/v1/playlists"->"""{"data":[{"id":41,"name":"Night route","isPublic":false,"trackCount":2,"durationMs":24000}],"total":1,"limit":20,"offset":0}"""
                "/api/v1/playlists/41"->"""{"id":41,"name":"Night route","isPublic":false,"trackCount":2,"durationMs":24000,"tracks":[{"id":2,"title":"Fixture 2","artist":"Synthetic ensemble","durationMs":12000},{"id":1,"title":"Fixture 1","artist":"Synthetic ensemble","durationMs":12000}]}"""
                "/api/v1/playlists/41/auto-mix"->{requests+=r.method+" "+path;check(r.method=="POST");"""{"playlistId":41,"mixPlan":$saved,"transitions":[{"index":0,"outgoingTrackId":2,"incomingTrackId":1,"preset":"Fade","bars":0,"overlapMs":2000,"confidence":{"keyMatch":false,"tempoMatched":false,"tempoShift":false,"simpleFade":true}}]}"""}
                "/api/v1/mix-plans/$id"->{requests+=r.method+" "+path;saved}
                else->return original.dispatch(r)
            }
            return MockResponse.Builder().body(body).build()
        }}
        try {
            app.graph.session.retire()
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("blend@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.size>=2}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val scope=app.graph.session.capture()!!
            app.graph.downloads.load(scope)
            for(track in app.graph.library.state.value.rows.filter {it.id.value in listOf(1L,2L)}) {
                val ticket=app.graph.downloads.claim(scope,track){true}!!;app.graph.downloads.transfer(ticket)
            }
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000){app.graph.playlists.state.value.rows.size==1}
            compose.onNode(hasText("Night route") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.playlistBlend.capture()!=null}
            val before=model.playback.value
            compose.onNodeWithContentDescription("Mixed listening").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.playlistBlend.state.value.status==com.soundq.android.data.playlists.BlendStatus.Ready}
            assertEquals(before.source,model.playback.value.source);assertEquals(before.queue,model.playback.value.queue)
            assertEquals(listOf("POST /api/v1/playlists/41/auto-mix","GET /api/v1/mix-plans/$id"),requests.toList())
            compose.onNode(hasText("Fixture 1") and hasText("0:10") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(15000){model.playback.value.source==PlaybackSource.SavedMix && model.playback.value.isPlaying && model.playback.value.positionMs>=10000}
            val initialMixed=model.playback.value
            compose.waitUntil(10000){model.playback.value.source==initialMixed.source && model.playback.value.selectedOccurrence==initialMixed.selectedOccurrence && model.playback.value.isPlaying && model.playback.value.positionMs>initialMixed.positionMs}
            compose.runOnIdle {model.controller.pause();model.controller.seek(11000)}
            compose.waitUntil(10000){!model.playback.value.isPlaying && model.playback.value.positionMs in 10950..11050}
            val accepted=model.playback.value
            compose.onNodeWithContentDescription("Plain listening").performScrollTo().performClick()
            compose.waitUntil(5000){!app.graph.playlistBlend.state.value.enabled}
            assertEquals(accepted.source,model.playback.value.source);assertEquals(accepted.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertEquals(1,requests.count {it.startsWith("POST")})
        } finally {ProductTransportFixture.server.dispatcher=original;app.graph.playlistBlend.leave();app.graph.playlistDetail.retire();app.graph.session.retire()}
    }
}
