package com.soundq.android.data.home

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Source capability controls. The script test-home-action-source.py additionally
 * composes the actual ViewModel/controller bodies and context ticket registry. */
class HomeActionSourceTest {
    private fun session(f:HttpsFixture)=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","fixture"))}
    private fun page()="""{"tracks":[${(1..20).joinToString(","){"""{"id":$it,"title":"Same title","inLibrary":${it!=1}}"""}}],"limit":20,"offset":0,"revision":"${"a".repeat(64)}","hasMore":false}"""

    @Test fun frozenGuardSurvivesDisplayRevealButNotSameRowsReplacementClaim() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page());repo.load(route,HomeSection.Recent)
            val rows=repo.recent.value.rows;var valid:()->Boolean={false};var calls=0
            val action=repo.playActionWithSource(route,HomeSection.Recent,rows,rows.last()) {tracks,index,source->
                assertEquals((2L..20L).toList(),tracks.map {it.id.value});assertEquals(18,index);valid=source;calls++
            }
            action();assertTrue(valid());assertEquals(1,calls)
            repo.load(route,HomeSection.Recent,repo.recent.value,true)
            assertSame(rows,repo.recent.value.rows);assertTrue(valid())
            action();assertEquals(2,calls)
            val claim=repo.claimRecent(route,repo.recent.value)!!
            assertSame(rows,repo.recent.value.rows);assertFalse(valid())
            repo.abandonRecent(claim);assertFalse(valid());action();assertEquals(2,calls)
            f.reply(page());repo.load(route,HomeSection.Recent,repo.recent.value)
            assertFalse(valid())
        }
    }

    @Test fun acceptedListReplacementUnderSameReadOwnerRetiresFrozenSource() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page());repo.load(route,HomeSection.Recent)
            val rows=repo.recent.value.rows
            val refresh=repo.claimRecent(route,repo.recent.value)!!
            assertSame(rows,repo.recent.value.rows)
            var valid:()->Boolean={false};var calls=0
            val action=repo.playActionWithSource(route,HomeSection.Recent,rows,rows.last()) {_,_,source->valid=source;calls++}
            action();assertTrue(valid())
            f.reply(page());repo.executeRecent(refresh)
            assertNotSame(rows,repo.recent.value.rows)
            assertFalse(valid());action();assertEquals(1,calls)
        }
    }

    @Test fun callbackDoesNotHoldRepositoryMonitorDuringRegistryEntry() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page());repo.load(route,HomeSection.Recent)
            val rows=repo.recent.value.rows;val worker=Executors.newSingleThreadExecutor();var calls=0
            try {
                repo.playActionWithSource(route,HomeSection.Recent,rows,rows.last()) {_,_,valid->
                    assertFalse("registry claim may call source while holding its own monitor",Thread.holdsLock(repo))
                    assertTrue(worker.submit<Boolean> {valid()}.get(2,TimeUnit.SECONDS));calls++
                }()
                assertEquals(1,calls)
            } finally {worker.shutdownNow()}
        }
    }

    @Test fun accountAndRouteAbaPermanentlyRetireFrozenSource() {
        for(account in listOf(false,true)) HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            f.reply(page());repo.load(route,HomeSection.Recent)
            val rows=repo.recent.value.rows;var valid:()->Boolean={false};var calls=0
            val action=repo.playActionWithSource(route,HomeSection.Recent,rows,rows.last()) {_,_,source->valid=source;calls++}
            action();assertTrue(valid())
            val again=if(account) {
                s.revoke();s.accept(s.beginIntent(),SecretTokens("b","rb","other"));s.revoke();s.accept(s.beginIntent(),SecretTokens("a2","ra2","fixture"));route
            } else {life.enter(HomeDestination.Library);life.enter(HomeDestination.Home)}
            // No intervening predicate invocation: identity checks themselves prevent ABA.
            assertFalse(valid());action();assertEquals(1,calls)
            f.reply(page());repo.load(again,HomeSection.Recent)
            assertFalse(valid());action();assertEquals(1,calls)
            val fresh=repo.recent.value.rows
            repo.playActionWithSource(again,HomeSection.Recent,fresh,fresh.last()) {_,_,source->assertTrue(source());calls++}()
            assertEquals(2,calls);assertFalse(valid())
        }
    }

    @Test fun absentOwnerAndRetainedBindingsNeverAdoptLaterAccount() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            val invented=HomeEntry(Track(TrackId(7),"Same title"),true);val rows=listOf(invented)
            val absent=repo.playActionWithSource(route,HomeSection.Recent,rows,invented) {_,_,_->fail("bound without owner")}
            f.reply(page());repo.load(route,HomeSection.Recent);absent()
            val accepted=repo.recent.value.rows
            val old=repo.playActionWithSource(route,HomeSection.Recent,accepted,accepted.last()) {_,_,_->fail("adopted replacement account")}
            s.accept(s.beginIntent(),SecretTokens("next","next-r","fixture"));old()
        }
    }

    @Test fun topAndSingletonHistoryCarryTheirOwnFrozenListGuard() {
        for(section in listOf(HomeSection.Top,HomeSection.History)) HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(if(section==HomeSection.History)HomeDestination.History else HomeDestination.Home)
            val body=if(section==HomeSection.Top)"""{"tracks":[{"id":7,"title":"Top","inLibrary":true},{"id":8,"title":"Top two","inLibrary":true}]}"""
                else """{"plays":[{"id":41,"track":{"id":7,"title":"History","inLibrary":true},"playedAt":"2026-10-28T00:00:00Z","skipped":false}],"limit":50,"offset":0}"""
            f.reply(body);repo.load(route,section)
            val rows:Any=if(section==HomeSection.Top)repo.top.value.rows else repo.history.value.rows
            val entry=if(section==HomeSection.Top)repo.top.value.rows.last() else repo.history.value.rows.single().entry
            var valid:()->Boolean={false};var calls=0
            val action=repo.playActionWithSource(route,section,rows,entry,41) {tracks,index,source->
                assertEquals(if(section==HomeSection.Top)listOf(7L,8L) else listOf(7L),tracks.map {it.id.value})
                assertEquals(if(section==HomeSection.Top)1 else 0,index);valid=source;calls++
            }
            action();assertTrue(valid())
            // Updating Recent cannot retire an unrelated Top source.
            if(section==HomeSection.Top){f.reply(page());repo.load(route,HomeSection.Recent);assertTrue(valid())}
            f.reply(body);repo.load(route,section)
            assertFalse(valid());action();assertEquals(1,calls)
        }
    }

    @Test fun slicedListAndIneligibleEntryCannotCreateSourceCapability() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page());repo.load(route,HomeSection.Recent)
            val rows=repo.recent.value.rows
            repo.playActionWithSource(route,HomeSection.Recent,rows.take(5),rows[1]) {_,_,_->fail("display list admitted")}()
            repo.playActionWithSource(route,HomeSection.Recent,rows,rows[0]) {_,_,_->fail("ineligible admitted")}()
        }
    }
}
