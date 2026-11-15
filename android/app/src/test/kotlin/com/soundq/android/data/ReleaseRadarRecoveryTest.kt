package com.soundq.android.data

import com.soundq.android.data.discovery.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

/** Real TLS GET ownership; provider/daily admission remains server-owned, not simulated here. */
class ReleaseRadarRecoveryTest {
    private fun wire(tag:String="Synthetic newest song")=javaClass.getResource("/release-radar-wire.json")!!.readText().replace("Synthetic newest song",tag)
    private fun session(f:HttpsFixture)=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
    @Test fun unenteredAutomaticAbandonIsSingleUseAndCannotClearFreshReservation() {
        HttpsFixture().use {f->
            val s=session(f);val r=DiscoveryRepository(s,SoundQApi(s,f.client),radarAdmitted=true)
            val v=r.open()!!;r.showRadar(v){true}
            val old=r.claimRadar(v,automatic=true)!!;r.abandonRadar(old)
            assertEquals(RadarPhase.Idle,r.radar.value.phase);assertEquals(0,f.server.requestCount)
            val fresh=r.claimRadar(v,automatic=true)!!;r.abandonRadar(old);r.loadRadar(old)
            assertEquals(RadarPhase.Loading,r.radar.value.phase);assertEquals(0,f.server.requestCount)
            f.reply(wire());r.loadRadar(fresh);r.loadRadar(fresh)
            assertEquals(RadarPhase.Ready,r.radar.value.phase);assertEquals(1,f.server.requestCount)
            assertNull(r.claimRadar(v,automatic=true))
        }
    }
    @Test fun interruptedDispatchedInitialGetResumesSameViewAndOldCompletionCannotPublishOrClearFreshRead() {
        HttpsFixture().use {f->
            val s=session(f);val r=DiscoveryRepository(s,SoundQApi(s,f.client),radarAdmitted=true)
            val v=r.open()!!;val first=r.showRadar(v){true}!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val calls=AtomicInteger()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                assertEquals("GET",request.method);assertEquals("/api/v1/me/discovery/releases",request.url.encodedPath)
                val n=calls.incrementAndGet()
                if(n==1){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}
                return MockResponse.Builder().body(wire(if(n==1)"Obsolete" else "Fresh")).build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val old=r.claimRadar(v,automatic=true)!!;val result=pool.submit {r.loadRadar(old)}
                assertTrue(entered.await(2,TimeUnit.SECONDS));r.hideRadar(first)
                assertEquals(RadarPhase.Idle,r.radar.value.phase)
                r.showRadar(v){true};val fresh=r.claimRadar(v,automatic=true)
                assertNotNull("unfinished dispatched read must release local visit admission",fresh)
                release.countDown();result.get(3,TimeUnit.SECONDS)
                r.abandonRadar(old);assertEquals(RadarPhase.Loading,r.radar.value.phase);assertNull(r.radar.value.page)
                r.loadRadar(fresh!!);val page=r.radar.value.page!!
                assertEquals("Fresh",page.songs.single().title);assertEquals(2,calls.get())
                r.hideRadar(r.showRadar(v){true}!!);r.showRadar(v){true}
                assertNull(r.claimRadar(v,automatic=true));assertSame(page,r.radar.value.page)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun completedVisitAndInterruptedRetainedPageDoNotRepeatAutomaticRead() {
        HttpsFixture().use {f->
            val s=session(f);val r=DiscoveryRepository(s,SoundQApi(s,f.client),radarAdmitted=true)
            val v=r.open()!!;val landing=r.showRadar(v){true}!!
            f.reply(wire());r.loadRadar(r.claimRadar(v,automatic=true)!!);val page=r.radar.value.page!!
            val refresh=r.claimRadar(v,refresh=true)!!;r.hideRadar(landing)
            r.loadRadar(refresh);r.abandonRadar(refresh);r.showRadar(v){true}
            assertSame(page,r.radar.value.page);assertNull(r.claimRadar(v,automatic=true))
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun canceledGetStillRefusesRootDraftAndAccountAbaBeforeDispatch() {
        for(retirement in listOf("root","draft","account")) HttpsFixture().use {f->
            val s=session(f);val r=DiscoveryRepository(s,SoundQApi(s,f.client),radarAdmitted=true)
            val v=r.open()!!;val landing=r.showRadar(v){true}!!;val old=r.claimRadar(v,automatic=true)!!
            r.hideRadar(landing);r.showRadar(v){true};val fresh=r.claimRadar(v,automatic=true)!!
            when(retirement) {
                "root"->r.close(v)
                "draft"->{r.edit(v,"search");r.edit(v,"")}
                "account"->{s.accept(s.beginIntent(),SecretTokens("b","rb","B"));s.accept(s.beginIntent(),SecretTokens("a2","ra2","A"))}
            }
            r.loadRadar(old);r.loadRadar(fresh);r.abandonRadar(old);r.abandonRadar(fresh)
            assertEquals(0,f.server.requestCount);assertNull(r.radar.value.page)
        }
    }
    @Test fun repeatedReadbackInvalidationHasDistinctAcknowledgementEvenWhenReadyStaleIsEqual() {
        HttpsFixture().use {f->
            val s=session(f);val r=DiscoveryRepository(s,SoundQApi(s,f.client),radarAdmitted=true)
            val v=r.open()!!;r.showRadar(v){true};f.reply(wire());r.loadRadar(r.claimRadar(v,automatic=true)!!)
            val before=r.radarInvalidation.value;r.libraryChanged(s.capture()!!)
            val stale=r.radar.value;val refresh=r.claimRadar(v)!!
            r.libraryChanged(s.capture()!!)
            assertEquals(stale,r.radar.value);assertEquals(before+2,r.radarInvalidation.value)
            r.loadRadar(refresh);assertEquals(1,f.server.requestCount)
            f.reply(wire("Refiltered"));r.loadRadar(r.claimRadar(v)!!)
            assertEquals("Refiltered",r.radar.value.page!!.songs.single().title);assertFalse(r.radar.value.stale)
            val revision=r.radarInvalidation.value;val oldScope=s.capture()!!
            s.accept(s.beginIntent(),SecretTokens("a2","r2","A"));r.libraryChanged(oldScope)
            assertEquals(revision,r.radarInvalidation.value);assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun acknowledgedLibraryRowCancelsInitialGetAndOldCompletionCannotClearReplacement() {
        HttpsFixture().use {f->
            val s=session(f);lateinit var r:DiscoveryRepository
            val api=SoundQApi(s,f.client,libraryOwnershipReadback={scope->r.libraryChanged(scope)})
            r=DiscoveryRepository(s,api,radarAdmitted=true)
            val v=r.open()!!;r.showRadar(v){true}
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val calls=AtomicInteger()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/api/v1/library")return MockResponse.Builder().body("""{"tracks":[{"id":1,"title":"Owned","artist":"Fixture","has_metadata_override":false,"mb_verified":false}],"total":1,"limit":100,"offset":0}""").build()
                assertEquals("/api/v1/me/discovery/releases",request.url.encodedPath)
                val n=calls.incrementAndGet()
                if(n==1){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}
                return MockResponse.Builder().body(wire(if(n==1)"Obsolete" else "Fresh")).build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val old=r.claimRadar(v,automatic=true)!!;val result=pool.submit {r.loadRadar(old)}
                assertTrue(entered.await(2,TimeUnit.SECONDS));val revision=r.radarInvalidation.value
                assertEquals(TrackId(1),api.trackDetailsSnapshot(s.capture()!!,TrackId(1)){true}!!.track.id)
                assertNull(r.radar.value.page);assertEquals(RadarPhase.Idle,r.radar.value.phase)
                assertEquals(revision+1,r.radarInvalidation.value)
                // Screen scheduling is covered separately by the exact-effect probe/mounted journey.
                val fresh=r.claimRadar(v,automatic=true)!!
                assertNull(r.claimRadar(v,automatic=true))
                release.countDown();result.get(3,TimeUnit.SECONDS);r.abandonRadar(old)
                assertNull(r.radar.value.page);assertEquals(RadarPhase.Loading,r.radar.value.phase)
                r.loadRadar(fresh);assertEquals("Fresh",r.radar.value.page!!.songs.single().title)
                assertEquals(2,calls.get());assertNull(r.claimRadar(v,automatic=true))
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun acknowledgedLibraryRowDoesNotTurnGenuineInitialFailureIntoAutomaticRetry() {
        HttpsFixture().use {f->
            val s=session(f);lateinit var r:DiscoveryRepository
            val api=SoundQApi(s,f.client,libraryOwnershipReadback={scope->r.libraryChanged(scope)})
            r=DiscoveryRepository(s,api,radarAdmitted=true)
            val v=r.open()!!;val landing=r.showRadar(v){true}!!
            f.reply("{}",503);r.loadRadar(r.claimRadar(v,automatic=true)!!)
            val revision=r.radarInvalidation.value
            f.reply("""{"tracks":[{"id":1,"title":"Owned","artist":"Fixture","has_metadata_override":false,"mb_verified":false}],"total":1,"limit":100,"offset":0}""")
            assertNotNull(api.trackDetailsSnapshot(s.capture()!!,TrackId(1)){true})
            assertEquals(revision+1,r.radarInvalidation.value)
            r.hideRadar(landing);r.showRadar(v){true}
            assertEquals(RadarPhase.Failed,r.radar.value.phase);assertNull(r.radar.value.page)
            assertNull(r.claimRadar(v,automatic=true));assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun failedInitialAutomaticReadIsNotAnInterruptedReadAndNeedsExplicitRetry() {
        HttpsFixture().use {f->
            val s=session(f);val r=DiscoveryRepository(s,SoundQApi(s,f.client),radarAdmitted=true)
            val v=r.open()!!;val landing=r.showRadar(v){true}!!
            f.reply("{}",503);r.loadRadar(r.claimRadar(v,automatic=true)!!)
            r.hideRadar(landing);r.showRadar(v){true};assertNull(r.claimRadar(v,automatic=true))
            assertEquals(RadarPhase.Failed,r.radar.value.phase);assertEquals(1,f.server.requestCount)
            f.reply(wire());r.loadRadar(r.claimRadar(v,refresh=true)!!)
            assertEquals(RadarPhase.Ready,r.radar.value.phase);assertEquals(2,f.server.requestCount)
        }
    }
}
