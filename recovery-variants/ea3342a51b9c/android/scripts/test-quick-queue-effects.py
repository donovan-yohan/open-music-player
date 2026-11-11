#!/usr/bin/env python3
"""Execute exact ProductViewModel queue effects and Controller enqueue with real read/preference owners.
MediaController boundary facade only. No Android runtime or audio acceptance.
"""
from pathlib import Path
import argparse,os
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--source-root',type=Path);a=p.parse_args()
r=a.source_root or Path(__file__).resolve().parents[1]
base=r/'app/src/main/kotlin/com/soundq/android'
vm=(base/'product/ProductViewModel.kt').read_text()
def block(text,marker):
 start=text.index(marker);opening=text.index('{',start);depth=1;end=opening+1
 while depth:
  if text[end]=='{':depth+=1
  elif text[end]=='}':depth-=1
  end+=1
 return text[start:end]
def until(marker,next_marker):
 return vm[vm.index(marker):vm.index(next_marker,vm.index(marker))]
effects=block(vm,'    fun enqueueLibrary(')
if '    fun quickQueueLibrary(' in vm:
 effects+='\n'+until('    fun quickQueueLibrary(','    fun quickQueuePlaylist(')
 effects+='\n'+block(vm,'    fun quickQueuePlaylist(')
 effects+='\n'+until('    fun homeQueue(','    fun enqueue(track:')
else:
 # Predecessor has no quick effect. Preserve the consuming callback and demonstrate
 # that its reveal-only reducer cannot emit the queue request.
 effects+='\nfun quickQueueLibrary(c:com.soundq.android.data.playlists.LibraryTrackCapture,v:()->Boolean)=enqueueLibrary(c,v)\n'
controller=block((base/'playback/ControllerProjection.kt').read_text(),'    fun enqueue(')
pre='''package com.soundq.android.quickqueuefixture
import com.soundq.android.data.*
import com.soundq.android.data.home.*
import com.soundq.android.data.playlists.*
import com.soundq.android.data.preferences.*
import com.soundq.android.playback.QueuePolicy
import com.soundq.designsystem.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
class Bundle {val fields=mutableMapOf<String,Boolean>();fun putBoolean(k:String,v:Boolean){fields[k]=v};fun getBoolean(k:String)=fields[k]?:false}
class MediaMetadata(val extras:Bundle?=null)
class MediaItem(val mediaId:String,val requestMetadata:RequestMetadata=RequestMetadata(),val mediaMetadata:MediaMetadata=MediaMetadata()) {
 class RequestMetadata(val extras:Bundle?=null) {class Builder {var extras:Bundle?=null;fun setExtras(v:Bundle)=apply{extras=v};fun build()=RequestMetadata(extras)}}
 class Builder {var id="";var request=RequestMetadata();fun setMediaId(v:String)=apply{id=v};fun setRequestMetadata(v:RequestMetadata)=apply{request=v};fun build()=MediaItem(id,request)}
}
class Facade {
 val items=mutableListOf(MediaItem("current"),MediaItem("manual",mediaMetadata=MediaMetadata(Bundle().apply{putBoolean("manual",true)})),MediaItem("context"))
 val mediaItemCount get()=items.size
 var currentMediaItemIndex=0;var position=2300L;var playing=false
 fun getMediaItemAt(i:Int)=items[i]
 fun addMediaItem(i:Int,m:MediaItem){items.add(i,m)}
}
class Controller {val controller:Facade?=Facade()
CONTROLLER
}
class Graph(val library:LibraryRepository,val home:HomeFeedRepository,val playlistDetail:PlaylistDetailRepository,val swipeQueuePreferences:SwipeQueuePreferences) {fun rememberTracks(t:List<Track>){} }
class Model(val graph:Graph) {val controller=Controller();val home=graph.home
EFFECTS
}
class QuickQueueEffectsExtractedTest {
 @Test fun actualHomeAndPlaylistEffectsRouteAcceptedDestinationWithoutPlay() {
  com.soundq.android.data.HttpsFixture().use {f->
   val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
   val api=SoundQApi(session,f.client);val home=HomeFeedRepository(session,api);val detail=PlaylistDetailRepository(api)
   val library=LibraryRepository(session,{_,_,_->LibraryPage(emptyList(),0,20,0)},{_,_,_->})
   val dir=Files.createTempDirectory("quick-owner-effects").toFile()
   try {
    val pref=SwipeQueuePreferences(dir.resolve("swipe"));pref.load();val model=Model(Graph(library,home,detail,pref));val c=model.controller.controller!!
    val route=HomeRouteLifetime().enter(HomeDestination.Home)
    f.reply("""{"tracks":[{"id":7,"title":"Home","inLibrary":true}]}""");home.load(route,HomeSection.Top)
    val rows=home.top.value.rows;val queue=model.homeQueue(route,HomeSection.Top,rows,rows.single())
    queue();assertEquals(listOf("current","manual","7","context"),c.items.map {it.mediaId})
    assertTrue(pref.setMode(pref.capture()!!,SwipeQueue.PlayNext){true})
    f.reply("""{"id":41,"name":"Queue only","isPublic":true,"trackCount":1,"durationMs":12000,"tracks":[{"id":9,"title":"Playlist","durationMs":12000}]}""");detail.open(PlaylistId(41))
    val capture=detail.capturePlayback()!!;val track=detail.state.value.detail!!.tracks.single()
    assertTrue(model.quickQueuePlaylist(capture,0,track){true})
    assertEquals(listOf("current","9","manual","7","context"),c.items.map {it.mediaId})
    assertFalse(c.playing);assertEquals(2300L,c.position);assertEquals(0,c.currentMediaItemIndex)
    detail.retire();assertFalse(model.quickQueuePlaylist(capture,0,track){true});assertEquals(5,c.mediaItemCount)
   }finally {dir.deleteRecursively()}
  }
 }
 @Test fun actualReleaseQueuesOriginalLibraryRowOnceWithoutStartingPlayback() {
  val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
  val row=Track(TrackId(7),"Original");val library=LibraryRepository(session,{_,_,_->LibraryPage(listOf(row),1,20,0)},{_,_,_->});library.refine(LibraryQuery())
  val dir=Files.createTempDirectory("quick-effect").toFile()
  try {
   val pref=SwipeQueuePreferences(dir.resolve("swipe"));pref.load()
   val api=SoundQApi(session);val model=Model(Graph(library,HomeFeedRepository(session,api),PlaylistDetailRepository(api),pref))
   val capture=library.captureTrack(row)!!;val state=RowRevealState(RowRevealOwner());val c=model.controller.controller!!
   fun gesture() {state.begin(0f);state.follow(-170f,184f);val release:Any?=state.end(112f,.5f,0f,.3f);if(release==true)model.quickQueueLibrary(capture){true};state.complete(state.revision,112f)}
   gesture();assertEquals(listOf("current","manual","7","context"),c.items.map {it.mediaId})
   assertTrue(c.items[2].requestMetadata.extras!!.getBoolean("manual"));assertEquals(0,c.currentMediaItemIndex);assertEquals(2300L,c.position);assertFalse(c.playing)
   assertTrue(pref.setMode(pref.capture()!!,SwipeQueue.PlayNext){true})
   val restored=SwipeQueuePreferences(dir.resolve("swipe"));restored.load();assertEquals(SwipeQueue.PlayNext,restored.state.value.mode)
   gesture();assertEquals(listOf("current","7","manual","7","context"),c.items.map {it.mediaId})
   assertEquals(2,c.items.count {it.mediaId=="7"});assertFalse(c.playing)
   session.revoke();gesture();assertEquals(5,c.mediaItemCount)
  }finally {dir.deleteRecursively()}
 }
}
'''
a.generate.mkdir(parents=True,exist_ok=True)
state=Path(os.environ.get('SOUNDQ_QUICK_QUEUE_REDUCER',r/'designsystem/src/main/kotlin/com/soundq/designsystem/RowRevealState.kt'))
(a.generate/'RowRevealState.kt').write_text(state.read_text().replace('package com.soundq.designsystem','package com.soundq.android.quickqueuefixture'))
(a.generate/'QuickQueueEffectsExtractedTest.kt').write_text(pre.replace('CONTROLLER',controller).replace('EFFECTS',effects))
