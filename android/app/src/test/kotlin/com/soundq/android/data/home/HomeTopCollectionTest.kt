package com.soundq.android.data.home

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test

class HomeTopCollectionTest {
    private fun session(f:HttpsFixture)=AccountSession(f.endpoint,MemoryStore()).also {
        it.accept(it.beginIntent(),SecretTokens("a","r","fixture"))
    }
    private fun tracks(count:Int)=(1..count).joinToString(",") {"""{"id":$it,"title":"Track $it","inLibrary":true}"""}

    @Test fun requestsAndAcceptsTwentyFiveOwnedTopTracks() {
        HttpsFixture().use {f->
            val s=session(f)
            f.reply("""{"tracks":[${tracks(25)}],"days":30,"limit":25,"ownedOnly":true}""")
            val rows=SoundQApi(s,f.client).top(s.capture()!!)
            assertEquals((1L..25L).toList(),rows.map {it.track.id.value})
            assertTrue(rows.all {it.eligible})
            val request=f.server.takeRequest()
            assertEquals("25",request.url.queryParameter("limit"))
            assertEquals("true",request.url.queryParameter("owned"))
            assertEquals("30",request.url.queryParameter("days"))
        }
    }
    @Test fun largerTopContractDoesNotWidenRecentPages() {
        HttpsFixture().use {f->
            val s=session(f);f.reply("""{"tracks":[${tracks(21)}]}""")
            val failure=runCatching {SoundQApi(s,f.client).recent(s.capture()!!)}.exceptionOrNull() as SafeFailure
            assertEquals(SafeFailure.Reason.InvalidResponse,failure.reason)
        }
    }
    @Test fun ownedProjectionCannotClaimAnUnavailableTrack() {
        HttpsFixture().use {f->
            val s=session(f);f.reply("""{"tracks":[{"id":1,"title":"Unavailable","inLibrary":false}],"ownedOnly":true}""")
            val failure=runCatching {SoundQApi(s,f.client).top(s.capture()!!)}.exceptionOrNull() as SafeFailure
            assertEquals(SafeFailure.Reason.InvalidResponse,failure.reason)
        }
    }
    @Test fun legacyMembershipFactsRemainUnavailableNotPlayable() {
        HttpsFixture().use {f->
            val s=session(f);f.reply("""{"tracks":[{"id":1,"title":"Unavailable","inLibrary":false}]}""")
            assertFalse(SoundQApi(s,f.client).top(s.capture()!!).single().eligible)
        }
    }
    @Test fun fullRecentRevealKeepsAcceptedRowsAndAdvancesNextPageOnlyOnce() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            val revision="a".repeat(64)
            f.reply("""{"tracks":[${tracks(20)}],"limit":20,"offset":0,"revision":"$revision","hasMore":true}""")
            repo.load(route,HomeSection.Recent)
            val before=repo.recent.value
            assertEquals(5,before.visibleCount)
            assertTrue(repo.revealRecent(route,before))
            assertSame(before.rows,repo.recent.value.rows)
            assertEquals(20,repo.recent.value.visibleCount)
            assertEquals(1,f.server.requestCount)
            val request=repo.claimRecent(route,repo.recent.value,append=true)
            assertNotNull(request)
            assertNull(repo.claimRecent(route,repo.recent.value,append=true))
            repo.abandonRecent(request!!)
            life.enter(HomeDestination.Library)
            assertFalse(repo.revealRecent(route,repo.recent.value))
        }
    }
}
