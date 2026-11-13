#!/usr/bin/env python3
"""Execute exact ControllerProjection listener/publication bodies on host boundaries."""
import argparse,os
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--source-root',type=Path);a=p.parse_args()
r=a.source_root or Path(os.environ.get('SOUNDQ_PLAYER_DETAILS_SOURCE',str(Path(__file__).resolve().parents[1])))
s=(r/'app/src/main/kotlin/com/soundq/android/playback/ControllerProjection.kt').read_text()
def block(marker):
 start=s.index(marker);i=s.index('{',start);depth=1;j=i+1
 while depth:
  depth+=(s[j]=='{')-(s[j]=='}');j+=1
 return s[start:j]
listener=block('    private val listener=')
detach=next(line for line in s.splitlines() if '{c -> ' in line and 'c.removeListener(listener)' in line)
detach=detach[detach.index('->')+2:detach.rindex('}')]
publish=block('    private fun publish(')
fields='\n'.join(line for line in s.splitlines() if line.startswith(('    private var ','    private val ')) and any(x in line for x in ['selectionIncarnation','observedSelection','performancePublication','syncAdmissions=','failureEvents=']))
sync_admission=block('    private class SyncAdmission(') if '    private class SyncAdmission(' in s else ''
helper=block('    private fun retireSelection(') if '    private fun retireSelection(' in s else ''
text='''package com.soundq.android.playerdetailssource
import com.soundq.android.playback.*
import com.soundq.android.playback.PerformanceCommands as ProductionPerformanceCommands
import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.Json
import org.junit.Assert.*
class Bundle {val fields=mutableMapOf<String,Any>();fun getLong(k:String,d:Long=0)=fields[k] as? Long ?: d;fun getString(k:String)=fields[k] as? String;fun getBoolean(k:String)=fields[k] as? Boolean ?: false;companion object {val EMPTY=Bundle()}}
class Meta(val extras:Bundle?=Bundle(),val title:String="Queued",val artist:String="Ensemble")
class Local(val uri:Uri);class Uri(val scheme:String)
class MediaItem(val mediaId:String,val mediaMetadata:Meta=Meta(),val localConfiguration:Local?=null)
class Timeline
class PlaybackException(val errorCode:Int=1,message:String="failure"):Exception(message)
interface Player {class Events;interface Listener {fun onPlayerErrorChanged(error:PlaybackException?){};fun onTimelineChanged(t:Timeline,reason:Int){};fun onEvents(p:Player,e:Events){};fun onMediaItemTransition(item:MediaItem?,reason:Int){}};companion object {const val COMMAND_PLAY_PAUSE=1;const val STATE_BUFFERING=2;const val REPEAT_MODE_OFF=0}}
class Facade:Player {var items=listOf(MediaItem("a",Meta(Bundle().apply {fields["trackId"]=7L})),MediaItem("b",Meta(Bundle().apply {fields["trackId"]=8L})));var index=0;val mediaItemCount get()=items.size;fun getMediaItemAt(i:Int)=items[i];val currentMediaItem get()=items.getOrNull(index);val mediaMetadata get()=currentMediaItem!!.mediaMetadata;var currentPosition=0L;val duration=12000L;var isPlaying=true;val shuffleModeEnabled=false;val repeatMode=0;val playerError:Exception?=null;val playbackState=3;val sessionExtras=Bundle().apply {fields["accountEpoch"]=1L;fields["incarnation"]="service";fields["sourceQueueIncarnation"]="queue"};fun removeListener(listener:Player.Listener){};fun isCommandAvailable(c:Int)=true;fun hasNextMediaItem()=true;fun hasPreviousMediaItem()=true}
class Handler {fun removeCallbacks(value:Any){}}
class Connection {fun accepts(c:Facade)=true}
class SessionCommand(val action:String,val extras:Bundle)
object SoundQLibraryService {const val PLAY_MIX="soundq.mix.play";const val APPLY_ARRANGEMENT="soundq.arrangement.apply"}
val supportedSessionCommands=mutableSetOf<String>()
fun Facade.isSessionCommandAvailable(command:SessionCommand)=command.action in supportedSessionCommands
// Host Bundle type boundary only: this observation fixture owns no performance payload.
// Keep the production publication/filter branch intact; refuse any attempted payload.
object PerformanceCommands {
 val BEGIN=ProductionPerformanceCommands.BEGIN
 val DECKS=ProductionPerformanceCommands.DECKS
 val TEMPO_STATE=ProductionPerformanceCommands.TEMPO_STATE
 inline fun <reified T> read(args:Bundle,key:String):T? {
  check(args.getString(key)==null) {"Performance payload outside player-details fixture"}
  return null
 }
}
class Harness {
 var contextError:String?=null
 val mutable=MutableStateFlow(PlaybackProjection());val state=mutable;var closed=false;val device=Facade();var controller:Facade?=device;val handler=Handler();val tick=Any();val connection=Connection();var queueRevision=0L;var projectedRevision=-1L;var projectedQueue=listOf<QueueOccurrence>()
 // No scratch capability/lease is owned here; retirement must not simulate one.
 private fun retireScratch(){check(PerformanceCommands.BEGIN !in supportedSessionCommands) {"Scratch owner outside player-details fixture"}}
'''+sync_admission+'\n'+fields+'\n'+helper+'\n'+listener+'\n'+publish+'''
 fun disconnect(){val c=controller!!;
'''+detach+'''
 }
 fun emit(){listener.onEvents(device,Player.Events())}
 fun transition(index:Int){device.index=index;listener.onMediaItemTransition(device.currentMediaItem,1)}
 fun reorder(){device.items=device.items.reversed();device.index=1;listener.onTimelineChanged(Timeline(),0);emit()}
}
class PlayerDetailsSourceObservationTest {
 @org.junit.Test fun mixedPlaybackCapabilitiesFollowActualSessionAdmission() {
  supportedSessionCommands.clear()
  val h=Harness();h.emit()
  assertFalse(h.state.value.canPlayMix);assertFalse(h.state.value.canAuditionArrangement)
  supportedSessionCommands.add(SoundQLibraryService.PLAY_MIX);h.emit()
  assertTrue(h.state.value.canPlayMix);assertFalse(h.state.value.canAuditionArrangement)
  supportedSessionCommands.add(SoundQLibraryService.APPLY_ARRANGEMENT);h.emit()
  assertTrue(h.state.value.canPlayMix);assertTrue(h.state.value.canAuditionArrangement)
  supportedSessionCommands.clear();h.emit()
  assertFalse(h.state.value.canPlayMix);assertFalse(h.state.value.canAuditionArrangement)
 }
 private fun incarnation(p:PlaybackProjection):Long=p.javaClass.methods.singleOrNull {it.name=="getSelectionIncarnation"}?.invoke(p) as? Long ?: 0L
 @org.junit.Test fun sameOccurrenceAbaRetiresBeforeConflatedPublicationButTicksAndReorderRemainValid() {
  val h=Harness();h.emit();val old=h.state.value;val generation=incarnation(old)
  h.device.currentPosition=4500;h.device.isPlaying=false;h.emit();assertEquals(generation,incarnation(h.state.value))
  h.reorder();assertEquals("a",h.state.value.selectedOccurrence);assertEquals(generation,incarnation(h.state.value))
  h.transition(0);h.transition(1);h.emit()
  assertEquals(old.selectedOccurrence,h.state.value.selectedOccurrence)
  assertTrue("Actual Media3 A-B-A callbacks must retire the old source even if only the final snapshot publishes",incarnation(h.state.value)>generation)
 }
 @org.junit.Test fun disconnectSameControllerReattachAndServiceQueueReplacementRetireOldObservation() {
  val h=Harness();h.emit();val old=incarnation(h.state.value)
  h.disconnect();assertTrue(incarnation(h.state.value)>old)
  h.controller=h.device;h.emit();val reattached=incarnation(h.state.value);assertTrue(reattached>old)
  h.device.sessionExtras.fields["sourceQueueIncarnation"]="replacement";h.emit();assertTrue(incarnation(h.state.value)>reattached)
 }
}
'''
a.generate.mkdir(parents=True,exist_ok=True);(a.generate/'PlayerDetailsSourceObservationTest.kt').write_text(text)
app=(r/'app/src/main/kotlin/com/soundq/android/product/ProductApp.kt').read_text()
start=app.index('"Player"->{');opening=app.index('{',start);depth=1;j=opening+1
while depth:
 depth+=(app[j]=='{')-(app[j]=='}');j+=1
# Execute the exact branch statements, not an uninvoked standalone lambda.
player=app[opening+1:j-1]
close=''
if '    fun closeDetails(' in app:
 start=app.index('    fun closeDetails(');opening=app.index('{',start);depth=1;j=opening+1
 while depth:
  depth+=(app[j]=='{')-(app[j]=='}');j+=1
 close=app[start:j]
caller='''package com.soundq.android.playerdetailscaller
import com.soundq.android.data.*
import com.soundq.android.data.trackdetails.*
import com.soundq.android.playback.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
fun <T> remember(block:()->T)=block()
val disposals=mutableListOf<()->Unit>()
class Disposal {fun onDispose(block:()->Unit){disposals.add(block)}}
fun DisposableEffect(key:Any?,block:Disposal.()->Unit){Disposal().block()}
enum class SoundQIcon {Info}
enum class SoundQButtonVariant {Secondary}
enum class FeedbackKind {Error}
object SoundQ {object typography {val heading=0}}
val icons=mutableMapOf<String,()->Unit>()
fun SoundQIconButton(icon:SoundQIcon,label:String,action:()->Unit){icons[label]=action}
fun SoundQSheet(label:String,onDismiss:()->Unit,content:()->Unit){content()}
fun Text(text:String,style:Int=0){}
fun SoundQFeedback(text:String,kind:FeedbackKind,detail:String){}
fun SoundQSeek(p:Long,d:Long,o:String?,seek:(Long)->Unit){}
fun SoundQTransport(p:Boolean,c:Boolean,b:Boolean,t:()->Unit,prev:()->Unit,next:()->Unit,cp:Boolean,cn:Boolean){}
fun SoundQButton(label:String,action:()->Unit,variant:SoundQButtonVariant){}
// Typed visual boundary, matching PlayerComponents.kt. Record Info only; no
// transport, dismissal, slot acquisition or network action is simulated here.
class FocusRequester
class Dp
object Modifier {fun fillMaxSize()=this}
class BoxConstraints {val maxWidth=Dp()}
fun BoxWithConstraints(modifier:Modifier,content:BoxConstraints.()->Unit){BoxConstraints().content()}
fun SoundQFullPlayer(
 title:String,artist:String,playing:Boolean,available:Boolean,preparing:Boolean,
 position:Long,duration:Long,selectedOccurrence:String?,
 onClose:()->Unit,onPrimary:()->Unit,onSeek:(Long)->Unit,onQueue:()->Unit,
 onPrevious:(()->Unit)?=null,onNext:(()->Unit)?=null,canPrevious:Boolean=false,canNext:Boolean=false,
 shuffle:Boolean=false,repeat:Int=0,onShuffle:(()->Unit)?=null,onRepeat:(()->Unit)?=null,
 onDevices:(()->Unit)?=null,onInfo:(()->Unit)?=null,artwork:(()->Unit)?=null,error:String?=null,
 returnFocus:FocusRequester?=null,clockContent:(()->Unit)?=null,
 speedCell:Any?=null,speedContent:(()->Unit)?=null,
) {if(onInfo!=null)icons["Song details"]=onInfo}
class DetailCallerSpeed {val cell:Any?=null;val content:(()->Unit)?=null}
fun rememberFullPlayerSpeed(p:PlaybackProjection,request:(PlaybackProjection,Double,()->Boolean,(Boolean)->Unit)->Unit)=DetailCallerSpeed()
class DetailCallerPhone {internal fun observed(ref:PlaybackRef.Device):com.soundq.android.data.deviceaudio.DeviceAudio?=null}
class DetailCallerGraph(val session:AccountSession,val trackDetails:TrackDetailsRepository){val phoneAudio=DetailCallerPhone()}
fun FullPlayerClock(p:PlaybackProjection,seek:(PlaybackProjection,com.soundq.android.playback.PlayerClockMode,Long,()->Boolean,(Boolean)->Unit)->Unit){}
class DetailCallerController {var commands=0;fun toggle(){commands++};fun seek(p:Long){commands++};fun previous(){commands++};fun next(){commands++};fun shuffle(){commands++};fun repeat(){commands++};fun seekClock(p:PlaybackProjection,m:com.soundq.android.playback.PlayerClockMode,t:Long,v:()->Boolean,d:(Boolean)->Unit){error("Out of scope clock")};fun setListeningSpeed(p:PlaybackProjection,s:Double,v:()->Boolean,d:(Boolean)->Unit){error("Out of scope speed")}}
class DetailCallerModel(val graph:DetailCallerGraph,p:PlaybackProjection) {val playback=MutableStateFlow(p);val controller=DetailCallerController();var scheduled:DetailsRoute?=null;fun loadTrackDetails(r:DetailsRoute){scheduled=r}}
class DetailCaller(val model:DetailCallerModel) {internal var selectedPhone:com.soundq.android.data.deviceaudio.DeviceAudio?=null;
 var panel:String?="Player";var detailsRoute:DetailsRoute?=null
 var transportReturn:String?=null
 val auth:AuthState=AuthState.SignedIn(model.graph.session.capture()!!.accountId)
'''+close+'''
 fun render(){val playback=model.playback.value
'''+player+'''
 }
 fun dismiss(){
'''+('detailsRoute?.let(::closeDetails)' if close else 'error("No details route")')+'''
 }
}
class PlayerDetailsCallerExtractedTest {
 @org.junit.Test fun actualRenderedInfoOpensCanonicalOwnedReadForFilteredTrackAndReturnsToPlayer() {
  HttpsFixture().use {f->
   val (api,_,_)=detailsSetup(f);val scope=api.session.capture()!!
   val library=LibraryRepository(api.session,{_,_,_->LibraryPage(listOf(Track(TrackId(8),"Other")),1,20,0)},{_,_,_->error("No Library mutation")})
   library.refine(LibraryQuery(text="hides-playing-song"));val repo=TrackDetailsRepository(api,library)
   assertTrue(library.state.value.rows.none {it.id.value==7L})
   val p=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,title="Queued",queue=listOf(QueueOccurrence("owned-off-page",7,"Queued","",false)),selectedOccurrence="owned-off-page",sessionIdentity="service",sourceQueueIncarnation="queue",accountEpoch=scope.epoch)
   val model=DetailCallerModel(DetailCallerGraph(api.session,repo),p);val caller=DetailCaller(model)
   icons.clear();caller.render()
   assertTrue("Ordinary rendered Now playing must expose Song details Info",icons.containsKey("Song details"))
   icons.getValue("Song details")();val route=caller.detailsRoute!!
   assertSame(route,model.scheduled);assertEquals("Details",caller.panel);assertEquals(0,f.server.requestCount)
   f.reply(detailsPage());f.reply("{}",404);repo.load(model.scheduled!!)
   assertEquals("Original",repo.state.value.detail!!.track.title)
   val command=repo.claim(route,repo.state.value.detail!!,DetailsAction.Metadata(MetadataDraft("Personal")))!!
   f.reply("""{"track_id":7,"has_metadata_override":true,"title":"Personal","artist":null,"album":null}""");f.reply(detailsPage(detailsRow("Personal",true)));repo.execute(command)
   assertEquals("Personal",repo.state.value.detail!!.track.title)
   caller.dismiss();assertEquals("Player",caller.panel);assertFalse(repo.current(route))
   assertEquals(0,model.controller.commands);assertEquals(p,model.playback.value);assertEquals("hides-playing-song",library.state.value.query.text)
  }
 }
 @org.junit.Test fun actualRetainedRenderedCallbackRefusesSelectionAbaAndDisposedPlayer() {
  HttpsFixture().use {f->
   val (api,_,repo)=detailsSetup(f);val scope=api.session.capture()!!
   val p=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,queue=listOf(QueueOccurrence("a",7,"Queued","",false)),selectedOccurrence="a",sessionIdentity="service",sourceQueueIncarnation="queue",accountEpoch=scope.epoch)
   val model=DetailCallerModel(DetailCallerGraph(api.session,repo),p);val caller=DetailCaller(model)
   icons.clear();disposals.clear();caller.render();assertTrue(icons.containsKey("Song details"));val stale=icons.getValue("Song details")
   model.playback.value=p.copy(selectionIncarnation=p.selectionIncarnation+2);stale();assertNull(caller.detailsRoute)
   caller.render();val closed=icons.getValue("Song details");disposals.forEach {it()};closed();assertNull(caller.detailsRoute)
   assertEquals(0,f.server.requestCount);assertEquals(0,model.controller.commands)
  }
 }
}
'''
(a.generate/'PlayerDetailsCallerExtractedTest.kt').write_text(caller)
# Declaration-only unrelated slot boundary. Map AppGraph and Compose Dp to this
# caller fixture's typed declarations; keep the fully qualified production call.
(a.generate/'PlayerArtworkSlotFacade.kt').write_text('''package com.soundq.android.product.artwork
import com.soundq.android.playerdetailscaller.DetailCallerGraph
import com.soundq.android.playerdetailscaller.Dp
import com.soundq.android.playback.PlaybackProjection
fun PlayerArtwork(graph:DetailCallerGraph,observed:PlaybackProjection,size:Dp,current:()->Boolean) {}
''')
