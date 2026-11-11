package com.soundq.android.data

import com.soundq.android.data.playlists.*
import com.soundq.android.data.harmonic.*
import com.soundq.android.data.preferences.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import mockwebserver3.*

class HarmonicOwnershipTest {
    private fun history()=javaClass.getResource("/harmonic/history.json")!!.readText()
    private fun dj()=DjModePreferences(Files.createTempDirectory("harmonic-owner-").toFile().resolve("dj.json")).also {it.load()}
    @Test fun oneSeededReadPerOpeningServerOrderAndQueueUsesCanonicalDurationWithoutPlaying() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(javaClass.getResource("/harmonic/playlist-seed.json")!!.readText());detail.open(PlaylistId(17))
            val owner=HarmonicRepository(api,detail,dj());val route=owner.open()!!
            val work=owner.initial(route)!!;assertNull(owner.initial(route));f.reply(history());work()
            assertEquals(listOf(11L),owner.state.value.result!!.tracks.map {it.id.value})
            val row=owner.state.value.result!!.tracks.single();val capture=owner.capture(route,0,row)!!
            val queued=mutableListOf<Track>()
            assertTrue(owner.queue(capture){queued.add(it)});assertTrue(owner.queue(capture){queued.add(it)})
            assertSame(detail.state.value.detail!!.tracks.first(),queued.first());assertEquals(2,queued.size)
            owner.close(route);assertFalse(owner.queue(capture){queued.add(it)});assertEquals(2,f.server.requestCount)
            val reopen=owner.open()!!;assertNull(owner.initial(reopen));assertNotNull(owner.state.value.result)
            assertFalse(owner.queue(capture){queued.add(it)})
        }
    }
    @Test fun unknownDurationStillAllowsMembershipButNotQueueAndEditingRetiresOldResultActions() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val owner=HarmonicRepository(api,detail,dj());val route=owner.open()!!
            owner.edit(route,HarmonicDraft("124","8A"));f.reply(history());owner.search(route)!!()
            val row=owner.state.value.result!!.tracks.last();val captured=owner.capture(route,1,row)!!
            assertNull(owner.queueTrack(captured));assertTrue(owner.current(captured))
            owner.edit(route,HarmonicDraft("125","8A"));assertFalse(owner.current(captured));assertNotNull(owner.state.value.result)
            assertTrue(owner.state.value.inputsChanged)
        }
    }
    @Test fun consumedHostActionClosesBeforeDispatchIsSingleUseAndCannotReopenOldQuery() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val owner=HarmonicRepository(api,detail,dj());val route=owner.open()!!
            owner.edit(route,HarmonicDraft("124","8A"));f.reply(history());owner.search(route)!!()
            val row=owner.state.value.result!!.tracks.first();val capture=owner.capture(route,0,row)!!
            var calls=0;var selected=true
            val work=owner.queueAction(capture,{selected}){calls++;assertFalse(owner.state.value.open)}!!
            selected=false
            assertNull(owner.search(route));owner.edit(route,HarmonicDraft("128","9A"))
            assertEquals("124",owner.state.value.draft.bpm)
            assertTrue(work());assertFalse(work());assertEquals(1,calls)
            val next=owner.open()!!;assertFalse(owner.current(capture));assertNull(owner.initial(next))
        }
    }
    @Test fun currentMembershipSelectionCanCloseAndReadBackWithoutLibraryProjection() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val manager=PlaylistManagementRepository(api,detail);val actions=PlaylistManagementActions(manager){it()}
            val owner=HarmonicRepository(api,detail,dj());val route=owner.open()!!
            owner.edit(route,HarmonicDraft("124","8A"));f.reply(history());owner.search(route)!!()
            val row=owner.state.value.result!!.tracks.last();val capture=owner.capture(route,1,row)!!
            assertNull(owner.queueTrack(capture))
            assertNull(owner.membership(capture,actions.capture()!!,manager){false})
            val work=owner.membership(capture,actions.capture()!!,manager){true}!!
            assertFalse(owner.state.value.open)
            f.reply("""{"added":[12],"skipped":[],"playlist":${managementSummary(ids=listOf(9,7,12))}}""")
            f.reply(managementDetail(ids=listOf(9,7,12)));work()
            assertEquals(MutationOutcome.Confirmed,manager.state.value.outcome)
            assertEquals(listOf(9L,7L,12L),detail.state.value.detail!!.tracks.map {it.id.value})
        }
    }
    @Test fun heldReadCannotRepublishAfterRouteAbaOrAcceptedDjOffOn() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41));f.server.takeRequest()
            val preference=dj();val owner=HarmonicRepository(api,detail,preference);val route=owner.open()!!
            owner.edit(route,HarmonicDraft("124","8A"));val work=owner.search(route)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(history()).build()}}
            val thread=Thread {work()};thread.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            preference.setEnabled(preference.capture()!!,false){true};preference.setEnabled(preference.capture()!!,true){true}
            owner.close(route);val next=owner.open()!!;release.countDown();thread.join(5000)
            assertFalse(thread.isAlive);assertNull(owner.state.value.result);assertNull(owner.capture(route,0,NearbyTrack(TrackId(11),"x")))
            assertNotSame(route,next)
        }
    }
    @Test fun heldResponseCannotPublishIntoReplacementQueryOrReauthenticatedAccount() {
        HttpsFixture().use {f->
            val session=playlistSession(f);val api=SoundQApi(session,f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41));f.server.takeRequest()
            val owner=HarmonicRepository(api,detail,dj());val route=owner.open()!!
            owner.edit(route,HarmonicDraft("124","8A"));val old=owner.search(route)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.queryParameter("bpm")=="124.0"){entered.countDown();check(release.await(5,TimeUnit.SECONDS))}
                return MockResponse.Builder().body(history()).build()
            }}
            val thread=Thread {old()};thread.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            owner.close(route);val replacement=owner.open()!!;owner.edit(replacement,HarmonicDraft("128","9A"));owner.search(replacement)!!()
            val accepted=owner.state.value.result;assertNotNull(accepted)
            session.retire();release.countDown();thread.join(5000)
            assertFalse(thread.isAlive);assertSame(accepted,owner.state.value.result)
            assertFalse(owner.owns(replacement));assertNull(owner.capture(replacement,0,accepted!!.tracks.first()))
        }
    }
    @Test fun disabledIsDistinctAndRetryUsesSameValidationGuard() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val owner=HarmonicRepository(api,detail,dj());val route=owner.open()!!
            owner.edit(route,HarmonicDraft("124","8A"));f.reply("{\"error\":\"private body\"}",404);owner.search(route)!!()
            assertTrue(owner.state.value.disabled);assertNull(owner.state.value.result)
            owner.edit(route,HarmonicDraft("NaN","8A"));assertNull(owner.search(route));assertEquals(2,f.server.requestCount)
            owner.edit(route,HarmonicDraft("124","8A"));f.reply(history());owner.search(route)!!();assertFalse(owner.state.value.disabled)
        }
    }
}
