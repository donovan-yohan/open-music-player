package com.soundq.android.data

import com.soundq.android.data.discovery.*
import org.junit.Assert.*
import org.junit.Test

class ReleaseRadarOwnershipTest {
 private fun wire()=javaClass.getResource("/release-radar-wire.json")!!.readText()
 @Test fun radarFindSourcesUsesFreshSearchAndBackPreservesPageWhileStaleClicksRefuse(){
  HttpsFixture().use {f->
   val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
   val repo=DiscoveryRepository(session,SoundQApi(session,f.client),radarAdmitted=true)
   val view=repo.open()!!;repo.showRadar(view){true};val read=repo.claimRadar(view)!!;f.reply(wire());repo.loadRadar(read)
   val page=repo.radar.value.page!!;val song=page.songs.single()
   val find=repo.claimFindSources(view,page,song,repo.state.value.draft)!!
   f.reply("""{"recordingMbid":"${song.recording.value}","inLibrary":false}""")
   val request=repo.findSources(find)!!
   assertEquals("Synthetic newest song Synthetic listened artist",request.draft.text)
   f.replySong(DiscoveryBoundaryTest.search(request.draft.text));repo.searchBlocking(request)
   val sources=repo.state.value.results!!;val choice=repo.inspect(view,sources.rows.single())!!
   assertTrue(repo.preview(view,choice){})
   assertTrue(repo.back(view));assertSame(page,repo.radar.value.page);assertTrue(repo.state.value.draft.text.isBlank())
   assertNull(repo.claimFindSources(view,page,RadarJson.page(kotlinx.serialization.json.Json.parseToJsonElement(wire()).let {it as kotlinx.serialization.json.JsonObject}).songs.single(),repo.state.value.draft))
   val oldDraft=repo.state.value.draft
   repo.edit(view,"search");assertNull(repo.claimFindSources(view,page,song,oldDraft));repo.edit(view,"")
   assertNull(repo.claimFindSources(view,page,song,oldDraft))
   val stale=repo.claimFindSources(view,page,song,repo.state.value.draft)!!;repo.edit(view,"changed");assertNull(repo.findSources(stale))
  }
 }
 @Test fun accountQueryRouteAndLibraryChangesRevokeHeldReadsAndActions(){
  HttpsFixture().use {f->
   val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
   val repo=DiscoveryRepository(session,SoundQApi(session,f.client),radarAdmitted=true);val view=repo.open()!!;repo.showRadar(view){true}
   val old=repo.claimRadar(view)!!;repo.edit(view,"typing");repo.loadRadar(old);assertNull(repo.radar.value.page)
   repo.edit(view,"");val fresh=repo.claimRadar(view)!!;f.reply(wire());repo.loadRadar(fresh)
   val page=repo.radar.value.page!!;val action=repo.claimFindSources(view,page,page.songs.single(),repo.state.value.draft)!!
   repo.libraryChanged();assertNull(repo.findSources(action));assertTrue(repo.radar.value.stale)
   repo.close(view);assertNull(repo.claimFindSources(view,page,page.songs.single(),repo.state.value.draft))
   session.accept(session.beginIntent(),SecretTokens("new","new","B"));assertNull(repo.claimRadar(view))
  }
 }
 // Historical selector retained. This is the unadmitted repository control, not normal AppGraph policy.
 @Test fun productionDefaultDoesNotDispatchPersonalizedReads(){
  HttpsFixture().use {f->val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))};val repo=DiscoveryRepository(session,SoundQApi(session,f.client));assertNull(repo.claimRadar(repo.open()!!));assertEquals(0,f.server.requestCount)}
 }
}
