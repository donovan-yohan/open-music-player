package com.soundq.android.data

import com.soundq.android.data.playlists.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

internal const val blendPlanId="00000000-0000-4000-8000-000000000041"
internal fun blendPlan(policy:String="volumeOnly"):String = """{"id":"$blendPlanId","schemaVersion":1,"name":"Night route Blend","version":1,"clips":[{"clipId":"clip-1","queueItemId":"playlist-41-pos-1","trackId":9,"sourceStartMs":0,"sourceEndMs":123000,"timelineStartMs":0,"timelineEndMs":123000,"gainDb":0,"fadeOutMs":8000,"pitchMode":"preserve","tempoPolicy":"$policy"},{"clipId":"clip-2","queueItemId":"playlist-41-pos-2","trackId":7,"sourceStartMs":0,"sourceEndMs":120000,"timelineStartMs":115000,"timelineEndMs":235000,"gainDb":0,"fadeInMs":8000,"pitchMode":"preserve","tempoPolicy":"$policy"}],"summary":{"clipCount":2,"trackIds":[9,7],"durationMs":235000},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"""
internal fun blendAck(plan:String=blendPlan()):String = """{"playlistId":41,"mixPlan":$plan,"transitions":[{"index":0,"outgoingTrackId":9,"incomingTrackId":7,"preset":"Fade","bars":0,"overlapMs":8000,"confidence":{"keyMatch":false,"tempoMatched":false,"tempoShift":false,"simpleFade":true}}]}"""
class PlaylistBlendTest {
    @Test fun cancelledRecoveryReleasesItsOwnLoadingWithoutRevivingAcrossResume() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(playlistDetail());detail.open(PlaylistId(41));val blend=PlaylistBlendRepository(api,detail)
            f.reply(blendAck());f.reply("{}",503);blend.generate(blend.capture()!!)!!()
            assertEquals(BlendStatus.ReadbackFailed,blend.state.value.status)
            val work=blend.recover(blend.capture()!!)!!
            blend.visible(false);blend.visible(true);work()
            assertFalse(blend.state.value.loading)
            f.reply(blendPlan());blend.recover(blend.capture()!!)!!()
            assertEquals(BlendStatus.Ready,blend.state.value.status)
            blend.leave();detail.retire();f.reply(playlistDetail());detail.open(PlaylistId(41))
            f.reply(blendPlan());blend.recover(blend.capture()!!)!!()
            assertTrue("Explicit readback on a fresh route may adopt the same saved source mapping",blend.choose(blend.capture()!!,true))
            assertTrue(blend.launch(detail.capturePlayback()!!,TrackId(7)) is PlaylistLaunch.Mixed)
        }
    }
    @Test fun explicitRegenerationAfterMembershipChangeCreatesOnlyOnNewIntent() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(playlistDetail());detail.open(PlaylistId(41));val blend=PlaylistBlendRepository(api,detail)
            f.reply(blendAck());f.reply(blendPlan());blend.generate(blend.capture()!!)!!()
            val before=detail.managementDetail()!!
            val reordered=before.copy(tracks=before.tracks.reversed())
            detail.publishManagement(before,reordered)
            val launch=blend.launch(detail.capturePlayback()!!,TrackId(7)) as PlaylistLaunch.Plain
            assertEquals(0,launch.index);assertEquals(listOf(7L,9L),launch.tracks.map {it.id.value})
            assertEquals(BlendStatus.Invalidated,blend.state.value.status)
            assertNotNull("Known accepted creation is not an uncertain retry; a new explicit intent may generate",blend.generate(blend.capture()!!))
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun retainedPlainPlaybackCaptureCannotReviveAfterStopResume() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(playlistDetail());detail.open(PlaylistId(41));val blend=PlaylistBlendRepository(api,detail)
            val old=detail.capturePlayback()!!
            blend.visible(false);blend.visible(true)
            assertSame(PlaylistLaunch.Refused,blend.launch(old,TrackId(7)))
            assertTrue(blend.launch(detail.capturePlayback()!!,TrackId(7)) is PlaylistLaunch.Plain)
        }
    }
    @Test fun staleReadbackFailureCannotClearNewerRecoveredReadyState() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(playlistDetail());detail.open(PlaylistId(41));val blend=PlaylistBlendRepository(api,detail)
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
            val gets=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(r:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                if(r.method=="POST")return mockwebserver3.MockResponse.Builder().body(blendAck()).build()
                if(gets.incrementAndGet()==1){entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().code(503).body("{}").build()}
                return mockwebserver3.MockResponse.Builder().body(blendPlan()).build()
            }}
            val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            try {
                val work=blend.generate(blend.capture()!!)!!;val old=pool.submit {work()}
                assertTrue(entered.await(3,TimeUnit.SECONDS));blend.visible(false);blend.visible(true)
                blend.recover(blend.capture()!!)!!();assertEquals(BlendStatus.Ready,blend.state.value.status)
                val accepted=blend.state.value;release.countDown();old.get(5,TimeUnit.SECONDS)
                assertSame(accepted,blend.state.value)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    private fun setup(f:HttpsFixture):Triple<SoundQApi,PlaylistDetailRepository,PlaylistBlendRepository> {
        val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
        f.reply(playlistDetail());detail.open(PlaylistId(41));return Triple(api,detail,PlaylistBlendRepository(api,detail))
    }
    @Test fun unknownCreateIsNeverRepostedAfterRouteReopenOrRepeatedWork() {
        HttpsFixture().use {f->
            val (_,detail,blend)=setup(f)
            f.reply("{}",503);val work=blend.generate(blend.capture()!!)!!;work()
            assertEquals(BlendStatus.UnknownCreate,blend.state.value.status)
            assertNull(blend.generate(blend.capture()!!))
            blend.leave();detail.retire();f.reply(playlistDetail());detail.open(PlaylistId(41))
            assertNull(blend.generate(blend.capture()!!));assertNull(blend.recover(blend.capture()!!))
            assertTrue(blend.launch(detail.capturePlayback()!!,TrackId(7)) is PlaylistLaunch.Plain)
            assertEquals(BlendStatus.UnknownCreate,blend.state.value.status)
            assertTrue(blend.choose(blend.capture()!!,false));assertTrue(blend.launch(detail.capturePlayback()!!,TrackId(7)) is PlaylistLaunch.Plain)
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun unenteredStopResumeReleasesReservationButOldWorkCannotAffectNewIntent() {
        HttpsFixture().use {f->
            val (_,_,blend)=setup(f)
            val old=blend.generate(blend.capture()!!)!!
            blend.visible(false);blend.visible(true)
            val replacement=blend.generate(blend.capture()!!)
            assertNotNull("No wire dispatch means no unknown create and no stuck reservation",replacement)
            val pending=blend.state.value;old();assertSame(pending,blend.state.value)
            f.reply(blendAck());f.reply(blendPlan());replacement!!()
            assertEquals(BlendStatus.Ready,blend.state.value.status)
            val duplicate=blend.generate(blend.capture()!!)!!
            f.reply(blendAck());f.reply(blendPlan());duplicate()
            val accepted=blend.state.value;duplicate();assertSame("Re-executing a consumed work closure must be inert",accepted,blend.state.value)
            assertEquals(5,f.server.requestCount)
        }
    }
    @Test fun mismatchedReadbackRetainsKnownIdAndOnlyExplicitGetCanRecover() {
        for(changed in listOf(blendPlan().replace("\"version\":1","\"version\":2"),blendPlan().replace("2026-01-01T00:00:00Z","2026-01-02T00:00:00Z")))HttpsFixture().use {f->
            val (_,detail,blend)=setup(f)
            f.reply(blendAck());f.reply(changed);blend.generate(blend.capture()!!)!!()
            assertEquals(BlendStatus.ReadbackFailed,blend.state.value.status)
            assertSame(PlaylistLaunch.Refused,blend.launch(detail.capturePlayback()!!,TrackId(7)))
            assertNull(blend.generate(blend.capture()!!))
            f.reply(blendPlan());blend.recover(blend.capture()!!)!!()
            assertEquals(BlendStatus.Ready,blend.state.value.status)
            val requests=(0 until f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","POST","GET","GET"),requests.map {it.method})
        }
    }
    @Test fun malformedSourceOrderDurationTransitionAndGeometryNeverEnablePlayback() {
        val cases=listOf(blendAck().replace("\"playlistId\":41","\"playlistId\":42"),
            blendAck().replace("\"trackId\":9","\"trackId\":7"),
            blendAck().replace("\"sourceEndMs\":123000","\"sourceEndMs\":123001"),
            blendAck().replace("\"overlapMs\":8000","\"overlapMs\":7000"),
            blendAck().replace("\"queueItemId\":\"playlist-41-pos-2\"","\"queueItemId\":\"playlist-41-pos-1\""),
            blendAck().replace("\"timelineEndMs\":235000","\"timelineEndMs\":234999"))
        for(body in cases)HttpsFixture().use {f->
            val (_,detail,blend)=setup(f);f.reply(body);blend.generate(blend.capture()!!)!!()
            assertEquals(BlendStatus.UnknownCreate,blend.state.value.status)
            assertSame(PlaylistLaunch.Refused,blend.launch(detail.capturePlayback()!!,TrackId(7)))
            assertNull(blend.generate(blend.capture()!!));assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun unsupportedRateNeverStartsOrFlattensAndPlainToggleIsLocalOnly() {
        HttpsFixture().use {f->
            val (_,detail,blend)=setup(f);val raw=blendPlan("constantTempoLock")
            f.reply(blendAck(raw));f.reply(raw);blend.generate(blend.capture()!!)!!()
            assertEquals(BlendStatus.Unsupported,blend.state.value.status)
            assertTrue(blend.state.value.enabled)
            assertSame(PlaylistLaunch.Refused,blend.launch(detail.capturePlayback()!!,TrackId(7)))
            assertTrue(blend.choose(blend.capture()!!,false));val plain=blend.launch(detail.capturePlayback()!!,TrackId(7)) as PlaylistLaunch.Plain
            assertEquals(1,plain.index);assertEquals(listOf(9L,7L),plain.tracks.map {it.id.value});assertEquals(3,f.server.requestCount)
            val shuffled=blend.launch(detail.capturePlayback()!!,TrackId(9),true) as PlaylistLaunch.Plain
            assertEquals(listOf(7L,9L),shuffled.tracks.map {it.id.value}.sorted());assertEquals(0,shuffled.index)
        }
    }
    @Test fun retainedStartCannotSurviveAccountAbaOrReadbackGeometryChange() {
        HttpsFixture().use {f->
            val (api,detail,blend)=setup(f);f.reply(blendAck());f.reply(blendPlan());blend.generate(blend.capture()!!)!!()
            val launch=blend.launch(detail.capturePlayback()!!,TrackId(7)) as PlaylistLaunch.Mixed
            val token=blend.reserveStart(launch)!!
            val changed=PlaylistBlendJson.document(Json.parseToJsonElement(blendPlan().replace("\"gainDb\":0","\"gainDb\":-6")).jsonObject)
            assertFalse(blend.installStart(token,api.session.capture()!!,changed){_,_->fail("different raw geometry")})
            val fresh=blend.reserveStart(launch)!!
            api.session.retire();api.session.accept(api.session.beginIntent(),SecretTokens("new","new-r","fixture"))
            assertFalse(blend.startCurrent(fresh,api.session.capture()!!))
            assertFalse(blend.installStart(fresh,api.session.capture()!!,PlaylistBlendJson.document(Json.parseToJsonElement(blendPlan()).jsonObject)){_,_->fail("ABA")})
        }
    }
    @Test fun explicitIndexPreservesTappedRepeatedSourceOccurrenceWithoutRenumbering() {
        HttpsFixture().use {f->
            val (_,detail,blend)=setup(f)
            val first=detail.managementDetail()!!
            detail.publishManagement(first,first.copy(tracks=listOf(first.tracks[0],first.tracks[0])))
            val raw=blendPlan().replace("\"trackId\":7","\"trackId\":9").replace("\"sourceEndMs\":120000","\"sourceEndMs\":123000").replace("235000","238000").replace("\"trackIds\":[9,7]","\"trackIds\":[9]")
            val ack=blendAck(raw).replace("\"incomingTrackId\":7","\"incomingTrackId\":9")
            f.reply(ack);f.reply(raw);blend.generate(blend.capture()!!)!!()
            val capture=detail.capturePlayback()!!
            assertSame(PlaylistLaunch.Refused,blend.launch(capture,TrackId(9)))
            val tapped=blend.launchAt(capture,1) as PlaylistLaunch.Mixed
            assertEquals(1,tapped.index);assertEquals("playlist-41-pos-2",tapped.occurrence)
            assertEquals(listOf("playlist-41-pos-1","playlist-41-pos-2"),tapped.plan.clips.map {it.occurrence})
            assertSame(PlaylistLaunch.Refused,blend.launchAt(capture,2))
        }
    }
    @Test fun unknownCreationSurvivesLocalLockWithoutGrantingOldCallbackFreshAuthority() {
        HttpsFixture().use {f->
            val (api,detail,blend)=setup(f);f.reply("{}",503);blend.generate(blend.capture()!!)!!()
            assertTrue(api.session.lockLocal());blend.retireAccount()
            assertTrue(api.session.completeLocalUnlock(api.session.localUnlockTicket()!!))
            f.reply(playlistDetail());detail.open(PlaylistId(41))
            assertNull("Local unlock must not erase an entered unknown POST",blend.generate(blend.capture()!!))
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun heldPostRouteExitKeepsKnownIdentityForExplicitGetOnlyRecovery() {
        HttpsFixture().use {f->
            val (_,detail,blend)=setup(f)
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(r:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                val body=when {
                    r.method=="POST"->{entered.countDown();check(release.await(5,TimeUnit.SECONDS));blendAck()}
                    r.url.encodedPath.startsWith("/api/v1/mix-plans/")->blendPlan()
                    else->playlistDetail()
                }
                return mockwebserver3.MockResponse.Builder().body(body).build()
            }}
            val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            try {
                val oldCapture=blend.capture()!!;val work=blend.generate(oldCapture)!!
                val old=pool.submit {work()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                blend.leave();detail.retire();detail.open(PlaylistId(41));release.countDown();old.get(5,TimeUnit.SECONDS)
                assertEquals(BlendStatus.ReadbackFailed,blend.state.value.status)
                assertNull(blend.generate(blend.capture()!!));assertFalse(blend.choose(oldCapture,true))
                assertEquals(3,f.server.requestCount)
                blend.recover(blend.capture()!!)!!();assertTrue(blend.choose(blend.capture()!!,true))
                assertTrue(blend.launchAt(detail.capturePlayback()!!,1) is PlaylistLaunch.Mixed)
                assertEquals(4,f.server.requestCount)
                val requests=(0 until f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
                assertEquals(1,requests.count {it.method=="POST"});assertEquals("GET",requests.last().method)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun publicEmptyUnknownDurationAndRefusedServerDoNotStartListening() {
        HttpsFixture().use {f->
            val (_,detail,blend)=setup(f)
            val before=detail.managementDetail()!!
            detail.publishManagement(before,before.copy(playlist=before.playlist.copy(draft=before.playlist.draft.copy(isPublic=true))))
            assertNull(blend.capture())
            val public=detail.managementDetail()!!;detail.publishManagement(public,before.copy(tracks=emptyList()))
            assertNull(blend.generate(blend.capture()!!))
            val empty=detail.managementDetail()!!;detail.publishManagement(empty,before.copy(tracks=before.tracks.map {it.copy(durationMs=0)}))
            assertNull(blend.generate(blend.capture()!!))
            detail.publishManagement(detail.managementDetail()!!,before)
            f.reply("{\"private-server-text\":\"do-not-display\"}",404);blend.generate(blend.capture()!!)!!()
            assertEquals(BlendStatus.Refused,blend.state.value.status)
            assertFalse(blend.state.value.toString().contains("do-not-display"));assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun explicitGenerationReadsExactSavedDocumentBeforeMixedTappedLaunch() {
        HttpsFixture().use { f ->
            val api=SoundQApi(playlistSession(f),f.client)
            val detail=PlaylistDetailRepository(api)
            f.reply(playlistDetail());detail.open(PlaylistId(41))
            val blend=PlaylistBlendRepository(api,detail)
            val capture=blend.capture()!!
            f.reply(blendAck());f.reply(blendPlan())
            blend.generate(capture)!!()
            assertEquals(BlendStatus.Ready,blend.state.value.status)
            val launch=blend.launch(detail.capturePlayback()!!,TrackId(7)) as PlaylistLaunch.Mixed
            assertEquals("playlist-41-pos-2",launch.occurrence)
            assertEquals(1,launch.index)
            assertEquals(blendPlanId,launch.plan.id)
            assertEquals(0,blend.pendingStarts())
            val token=blend.reserveStart(launch)!!
            var start=-1L
            f.reply(blendPlan())
            val document=api.mixPlanDocument(api.session.capture()!!,blendPlanId){true}
            assertTrue(blend.installStart(token,api.session.capture()!!,document){_,position->start=position})
            assertEquals(115000L,start)
            assertFalse(blend.installStart(token,api.session.capture()!!,document){_,_->fail("one use")})
            val requests=(0 until f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","POST","GET","GET"),requests.map {it.method})
            assertEquals("/api/v1/playlists/41/auto-mix",requests[1].url.encodedPath)
            assertEquals("Bearer playlist-test-a",requests[1].headers["Authorization"])
            assertEquals("{}",requests[1].body!!.utf8())
        }
    }
}
