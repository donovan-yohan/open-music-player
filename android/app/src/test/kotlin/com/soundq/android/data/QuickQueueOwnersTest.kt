package com.soundq.android.data
import com.soundq.android.data.home.*
import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test
class QuickQueueOwnersTest {
 @Test fun homeQueueUsesOnlyEligibleOriginalRowAndRejectsRefreshRouteAndAccount() {
  HttpsFixture().use {f->
   val session=playlistSession(f);val repo=HomeFeedRepository(session,SoundQApi(session,f.client));val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
   val body="""{"tracks":[{"id":1,"title":"Blocked","inLibrary":false},{"id":7,"title":"Eligible","inLibrary":true}]}"""
   f.reply(body);repo.load(route,HomeSection.Recent);val rows=repo.recent.value.rows
   val queued=mutableListOf<Track>()
   val queue=repo.queueAction(route,HomeSection.Recent,rows,rows[1],queue={queued.add(it)})
   queue();assertEquals(listOf(7L),queued.map {it.id.value})
   repo.queueAction(route,HomeSection.Recent,rows,rows[0],queue={fail("ineligible")})()
   f.reply(body);repo.load(route,HomeSection.Recent,repo.recent.value);queue();assertEquals(1,queued.size)
   val fresh=repo.recent.value.rows
   val routeQueue=repo.queueAction(route,HomeSection.Recent,fresh,fresh[1],queue={queued.add(it)})
   life.enter(HomeDestination.History);life.enter(HomeDestination.Home);routeQueue();assertEquals(1,queued.size)
   session.revoke();session.accept(session.beginIntent(),SecretTokens("b","r","replacement"));routeQueue();assertEquals(1,queued.size)
  }
 }
 @Test fun playlistQueuesExactIndexWithoutContextLaunchAndRevokesOldCapture() {
  HttpsFixture().use {f->
   val session=playlistSession(f);val repo=PlaylistDetailRepository(SoundQApi(session,f.client))
   f.reply(playlistDetail());repo.open(PlaylistId(41));val capture=repo.capturePlayback()!!
   val track=repo.state.value.detail!!.tracks[1];val queued=mutableListOf<Track>()
   assertTrue(repo.queue(capture,1,track){queued.add(it)});assertSame(track,queued.single())
   assertFalse(repo.queue(capture,0,track){fail("wrong original row")})
   repo.retirePlayback();assertFalse(repo.queue(capture,1,track){fail("retired")})
   val fresh=repo.capturePlayback()!!;session.revoke()
   assertFalse(repo.queue(fresh,1,track){fail("account")})
  }
 }
}
