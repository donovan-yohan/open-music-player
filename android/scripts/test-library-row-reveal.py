#!/usr/bin/env python3
"""Compile actual Library binding and effect methods with native registration/controller facades.
This is a host callback boundary, not mounted Compose or Media3 runtime acceptance.
"""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--source-root',type=Path);a=p.parse_args()
r=a.source_root or Path(__file__).resolve().parents[1]
s=(r/'app/src/main/kotlin/com/soundq/android/product/ProductApp.kt').read_text()
start=s.index('                            val mutation=library.mutations[track.id]')
end=s.index('\n                        }',start)
binding=s[start:end]
vm=(r/'app/src/main/kotlin/com/soundq/android/product/ProductViewModel.kt').read_text()
def block(text,needle):
 start=text.index(needle);opening=text.index('{',start);depth=1;end=opening+1
 while depth:
  if text[end]=='{':depth+=1
  elif text[end]=='}':depth-=1
  end+=1
 return text[start:end]
effects=''
if '    fun likeLibrary(' in vm:
 effects=block(vm,'    fun likeLibrary(')+'\n'+block(vm,'    fun enqueueLibrary(')
 if '    fun quickQueueLibrary(' in vm:
  begin=vm.index('    fun quickQueueLibrary(');end=vm.index('    fun quickQueuePlaylist(',begin);effects+='\n'+vm[begin:end]
# Only the test registration and frame completion boundaries are replaced.
pre='''package com.soundq.android.rowmetadatafixture
import com.soundq.android.data.*
import com.soundq.android.data.playlists.*
import com.soundq.android.product.LibraryRowLifetime
import com.soundq.android.product.RowIdentity
import com.soundq.android.product.LibraryMetadataField
import com.soundq.android.product.libraryRowMetadata
import com.soundq.designsystem.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
class Playback(val queue:List<Entry> = emptyList(),val selectedOccurrence:String?=null)
class Entry(val occurrenceId:String,val trackId:Long)
class Graph(val library:LibraryRepository) {
 val swipeQueuePreferences=com.soundq.android.data.preferences.SwipeQueuePreferences(java.io.File(System.getProperty("java.io.tmpdir"),"unused-row-fixture"))
 val libraryArtwork=Unit
 val session get()=library.session
 fun rememberTracks(tracks:List<Track>){}
}
class Controller {var queued=0;fun enqueue(track:Track,next:Boolean){queued++}}
class Model(val graph:Graph) {
 var plays=0
 val controller=Controller()
 val viewModelScope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
 fun play(index:Int,rows:List<Track>){plays++}
 fun playLibraryCollection(expected:LibraryState,selected:TrackId?=null,current:()->Boolean){error("Collection path is outside this ordinary-row fixture")}
EFFECTS
}
fun <T> remember(vararg keys:Any?,block:()->T):T=block()
class Disposal {fun onDispose(block:()->Unit){}}
fun DisposableEffect(vararg keys:Any?,block:Disposal.()->Unit){Disposal().block()}
class Driver {
 var activate:()->Unit={};var like:()->Unit={};var queue:()->Unit={}
 var state:RowRevealState?=null
 fun swipeLeft(){state?.let {it.begin(0f);it.follow(-112f,112f);it.end(112f,0.5f,0f,0.3f);it.complete(it.revision,112f)}}
 fun quickSwipe(){state?.let {it.begin(0f);it.follow(-170f,184f);if(it.end(112f,0.5f,0f,0.3f))quick();it.complete(it.revision,112f)}}
 var quick:()->Unit={}
 var artwork:(()->Unit)?=null
 internal var metadata:List<LibraryMetadataField> = emptyList()
}
internal fun LibraryMetadataContent(fields:List<LibraryMetadataField>){driver.metadata=fields}
fun SoundQMediaRow(title:String,artist:String,current:Boolean,onActivate:()->Unit,onMore:()->Unit,supporting:String?=null){driver.activate=onActivate}
fun SoundQRevealMediaRow(title:String,subtitle:String,current:Boolean,state:RowRevealState,enabled:Boolean,liked:Boolean?,likeEnabled:Boolean,onLike:()->Unit,onQueue:()->Unit,onActivate:()->Unit,onMore:()->Unit,supporting:String?=null,onQuickQueue:()->Unit=onQueue,artwork:(()->Unit)?=null,metadata:(()->Unit)?=null) {
 driver.artwork=artwork
 metadata?.invoke()
 driver.state=state
 driver.quick=onQuickQueue
 driver.activate={if(enabled&&state.frontTap())onActivate()}
 val ticket=state.revision
 driver.like={if(enabled&&likeEnabled&&state.admit(ticket))onLike()}
 driver.queue={if(enabled&&state.admit(ticket))onQueue()}
}
private lateinit var driver:Driver
class LibraryRowBindingExtractedTest {
 @Test fun openFrontTapClosesInsteadOfPlayingThroughActualLibraryBinding() {
  val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
  session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
  val repository=LibraryRepository(session,{_,_,_->LibraryPage(listOf(Track(TrackId(1),"Fixture",durationMs=222000,liked=false)),1,20,0,analysis=mapOf(TrackId(1) to LibraryAnalysisFacts("analyzed",128.0,"A minor","8A")))},{_,_,_->})
  repository.refine(LibraryQuery())
  val model=Model(Graph(repository));val library=repository.state.value
  val keyNotation=com.soundq.android.data.preferences.KeyNotationState(ready=true)
  val track=library.rows.single();val index=0;val playback=Playback()
  val libraryActions:LibraryPlaylistActions?=null
  val rowLifetime=LibraryRowLifetime {true};val revealOwner=RowRevealOwner()
  var trackCapture:LibraryTrackCapture?=null;var trackPlaylistActions:LibraryPlaylistActions?=null
  var selected:Track?=null;var panel:String?=null
  val collectionCurrent={true}
  driver=Driver()
BINDING
  assertNotNull("Actual Library binding must provide the existing artwork slot",driver.artwork)
  assertEquals("Actual Library binding must render accepted page metadata",listOf("3:42","128 BPM","8A"),driver.metadata.map {it.display})
  driver.quickSwipe()
  assertEquals("Full threshold must consume the real Library queue callback",1,model.controller.queued)
  assertEquals(0,model.plays)
  driver.swipeLeft();driver.activate()
  assertEquals("An open Library front must close, not play",0,model.plays)
 }
}
'''
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'LibraryRowBindingExtractedTest.kt').write_text(pre.replace('BINDING',binding).replace('EFFECTS',effects))
if effects:
 (a.generate/'LibraryRowEffectsExtractedTest.kt').write_text('''package com.soundq.android.rowmetadatafixture
import com.soundq.android.data.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
class LibraryRowEffectsExtractedTest {
 private class Harness {
  val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
  var liked=false;var writes=0;var observedBeforeWrite:Boolean?=null
  val row=Track(TrackId(1),"Fixture",liked=false)
  val repository:LibraryRepository=LibraryRepository(session,{_,_,_->LibraryPage(listOf(if(liked)row.copy(liked=true)else row),1,20,0)},{_,_,value->observedBeforeWrite=repository.state.value.rows.single().liked;writes++;liked=value})
  val model=Model(Graph(repository))
  init {session.accept(session.beginIntent(),SecretTokens("a","r","A"));repository.refine(LibraryQuery())}
 }
 @Test fun queueUsesOriginalAcknowledgedAccountBeforeOldRowsCollectorClears() {
  val h=Harness();val captured=h.repository.captureTrack(h.row)!!
  assertTrue(h.model.enqueueLibrary(captured,{true}));assertEquals(1,h.model.controller.queued)
  h.session.accept(h.session.beginIntent(),SecretTokens("b","r","B"))
  assertFalse(h.model.enqueueLibrary(captured,{true}));assertFalse(h.model.likeLibrary(captured,{true}))
  assertEquals(1,h.model.controller.queued);assertEquals(0,h.writes)
 }
 @Test fun queryAndRouteRetirementNeverReviveSameObjectCapture() {
  val h=Harness();val captured=h.repository.captureTrack(h.row)!!
  h.repository.refine(LibraryQuery(text="new"));h.repository.refine(LibraryQuery())
  assertFalse(h.model.enqueueLibrary(captured,{true}));assertFalse(h.model.likeLibrary(captured,{true}))
  val fresh=h.repository.captureTrack(h.row)!!
  assertFalse(h.model.enqueueLibrary(fresh,{false}));assertFalse(h.model.likeLibrary(fresh,{false}))
  assertEquals(0,h.model.controller.queued);assertEquals(0,h.writes)
 }
 @Test fun explicitLikeClaimsBeforeIoThenAcknowledgesWithoutOptimisticHeart()=runBlocking {
  val h=Harness();val capture=h.repository.captureTrack(h.row)!!
  assertTrue(h.model.likeLibrary(capture,{true}))
  withTimeout(5000){while(h.model.viewModelScope.coroutineContext[Job]!!.children.any {it.isActive})delay(5)}
  assertEquals(1,h.writes);assertEquals(false,h.observedBeforeWrite)
  assertEquals(true,h.repository.state.value.rows.single().liked)
  assertEquals(MutationOutcome.Confirmed,h.repository.state.value.mutations[h.row.id])
 }
    @Test fun neverEnteredCancelledScopeAbandonsOnlyItsOwnClaim()=runBlocking {
  val h=Harness();val capture=h.repository.captureTrack(h.row)!!
  h.model.viewModelScope.cancel();assertTrue(h.model.likeLibrary(capture,{true}))
  withTimeout(5000){while(h.repository.offerLike(capture.scope,capture.track.id)==null)delay(5)}
  assertEquals(0,h.writes);assertNotNull(h.repository.offerLike(capture.scope,capture.track.id))
 }
}
''')
