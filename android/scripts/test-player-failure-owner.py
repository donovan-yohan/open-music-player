#!/usr/bin/env python3
"""Exact service extras -> controller publication -> root sync -> Toast receipt.

Android/Media3 and lifecycle are closed boundary facades. AccountSession, source
identities, error receipts, and all three consuming production bodies execute.
This is not mounted Compose, a real MediaSession, or Android Toast rendering.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--generate', type=Path, required=True)
p.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
p.add_argument('--standalone', action='store_true', help='Copy collaborators for private non-Gradle execution')
a = p.parse_args()
b = a.source_root / 'app/src/main/kotlin/com/soundq/android'
a.generate.mkdir(parents=True, exist_ok=True)
extracted = {}


def block(path, marker):
    text = (b / path).read_text()
    start = text.index(marker)
    i = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[i] == '{') - (text[i] == '}')
        i += 1
    result = text[start:i]
    extracted[path + ':' + marker.strip()] = hashlib.sha256(result.encode()).hexdigest()
    return result


def emit(name, text):
    (a.generate / name).write_text(text)


controller_path = 'playback/ControllerProjection.kt'
controller = (b / controller_path).read_text()
declarations = controller[controller.index('@kotlinx.serialization.Serializable data class QueueOccurrence'):controller.index('/** Disposable immutable projection')]
fields = '\n'.join(line for line in controller.splitlines() if line.startswith(('    private var ', '    private val ')) and any(k in line for k in ['selectionIncarnation', 'observedSelection', 'failureEvents=']))
service_path = 'playback/SoundQLibraryService.kt'
service = '\n'.join(block(service_path, marker) for marker in ['    private fun resolveDevice(', '    private fun grantFor(', '    private fun publishSessionExtras('])
if '    private fun selectedDeviceOwner(' in (b / service_path).read_text():
    service += '\n' + block(service_path, '    private fun selectedDeviceOwner(')
grant = block('playback/SignedAudioDataSource.kt', 'internal class MediaGrant').replace('MediaGrant', 'ProbeMediaGrant').replace('AppGraph', 'Graph')
# Type-only rebinding avoids a duplicate production MediaGrant in the canonical gate.
service = service.replace('MediaGrant', 'ProbeMediaGrant')
service = service.replace('com.soundq.android.playback.nativeengine.NativeCallbackPlayer', 'NativeCallbackPlayer')
probe = r'''package com.soundq.android.failureownerprobe
import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import org.junit.Assert.*
import org.junit.Test

class Bundle {val fields=mutableMapOf<String,Any>();fun getLong(k:String,d:Long=0)=fields[k] as? Long ?: d;fun getBoolean(k:String)=fields[k] as? Boolean ?: false;fun getString(k:String)=fields[k] as? String;fun putLong(k:String,v:Long){fields[k]=v};fun putBoolean(k:String,v:Boolean){fields[k]=v};fun putString(k:String,v:String){fields[k]=v};companion object {val EMPTY=Bundle()}}
class Uri(val raw:String) {val scheme get()=raw.substringBefore(':');override fun toString()=raw;companion object {fun parse(v:String)=Uri(v)}}
class MediaMetadata(val title:String="Queued",val artist:String="Ensemble",val extras:Bundle?=Bundle()) {class Builder {var title="";var artist="";var e:Bundle?=null;fun setTitle(v:String)=apply{title=v};fun setArtist(v:String)=apply{artist=v};fun setAlbumTitle(v:String)=this;fun setIsPlayable(v:Boolean)=this;fun setIsBrowsable(v:Boolean)=this;fun setExtras(v:Bundle)=apply{e=v};fun build()=MediaMetadata(title,artist,e)}}
class MediaItem(val mediaId:String,val mediaMetadata:MediaMetadata=MediaMetadata(),val localConfiguration:Local?=null,val requestMetadata:Request=Request()) {class Local(val uri:Uri);class Request(val extras:Bundle?=null,val mediaUri:Uri?=null);class Builder {var id="";var meta=MediaMetadata();var uri:Uri?=null;fun setMediaId(v:String)=apply{id=v};fun setUri(v:Uri)=apply{uri=v};fun setMediaMetadata(v:MediaMetadata)=apply{meta=v};fun build()=MediaItem(id,meta,uri?.let(::Local))}}
class Timeline
class PlaybackException(val errorCode:Int=1,message:String="failure"):Exception(message)
interface Player {class Events;interface Listener {fun onPlayerErrorChanged(error:PlaybackException?){};fun onTimelineChanged(timeline:Timeline,reason:Int){};fun onEvents(player:Player,events:Events){};fun onMediaItemTransition(mediaItem:MediaItem?,reason:Int){}};companion object {const val COMMAND_PLAY_PAUSE=1;const val STATE_BUFFERING=2;const val REPEAT_MODE_OFF=0}}
open class Facade:Player {var items=listOf<MediaItem>();var index=0;val mediaItemCount get()=items.size;fun getMediaItemAt(i:Int)=items[i];val currentMediaItem get()=items.getOrNull(index);val mediaMetadata get()=currentMediaItem?.mediaMetadata ?: MediaMetadata();var currentPosition=0L;val duration=12000L;var isPlaying=false;val shuffleModeEnabled=false;val repeatMode=0;var playerError:PlaybackException?=null;var playbackState=3;var sessionExtras=Bundle();fun isCommandAvailable(c:Int)=true;fun hasNextMediaItem()=false;fun hasPreviousMediaItem()=false;fun isSessionCommandAvailable(c:SessionCommand)=false}
class Connection {var active=true;fun accepts(c:Facade)=active}
class SessionCommand(val action:String,val extras:Bundle)
object SoundQLibraryService {const val PLAY_MIX="mix";const val APPLY_ARRANGEMENT="arrangement"}
object PerformanceCommands {const val DECKS="decks";const val TEMPO_STATE="tempo";const val BEGIN="begin";inline fun <reified T> read(b:Bundle,k:String):T? {check(b.getString(k)==null);return null}}
const val LISTENING_SPEED_STATE="speed"
const val SET_LISTENING_SPEED="set-speed"
class SessionFacade(val player:Facade) {fun setSessionExtras(extras:Bundle){player.sessionExtras=extras}}
class Store:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
class Phone(val graph:Graph) {
 val ref=PlaybackRef.Device("00000000-0000-0000-0000-000000000001","a".repeat(64),64,1)
 val id=DeviceFileId(UUID.fromString(ref.id));val revision=ContentRevision(ref.sha256,ref.bytes)
 val row=DeviceAudio(id,ProviderObjectId("fixture","one"),revision,1,OriginalMetadata("one.mp3"),12000,listOf(LocatorAccess(ScanGrantId(UUID(0,2)),ProviderLocator("fixture","one"),AccessState.AVAILABLE)))
 var accepted=graph.session.version();var authority=0L
 val state=MutableStateFlow(PhoneState(DeviceListeningSnapshot(0,listOf(row),emptyList(),emptyList())))
 fun current(version:Long)=accepted==version&&graph.session.owns(version)&&graph.session.state.value !is AuthState.LocalLocked
 fun sourceAuthority(ref:PlaybackRef.Device)=authority
 fun observed(ref:PlaybackRef.Device)=state.value.snapshot?.resolve(DeviceFileId(UUID.fromString(ref.id)),ContentRevision(ref.sha256,ref.bytes),ref.incarnation)
 fun unavailable(){authority++;state.value=PhoneState(state.value.snapshot!!.copy(files=listOf(row.copy(aliases=row.aliases.map {it.copy(state=AccessState.UNREADABLE)}))))}
}
class PhoneState(val snapshot:DeviceListeningSnapshot?)
class Graph {val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store()).apply{retire()};val phoneAudio=Phone(this);val jamAdmission=objectJam();class objectJam {val incarnation="session"}}
GRANT
class Service(val graph:Graph,val player:Facade) {val liveQualifications=emptyMap<String,Pair<()->Boolean,()->Boolean>>();val grants=ConcurrentHashMap<String,ProbeMediaGrant>();val session:SessionFacade?=SessionFacade(player);var account:AccountScope?=null;val undo:Any?=null;val serviceIncarnation="service";val sourceQueueIncarnation="queue";val acceptedArrangement:AcceptedArrangement?=null
 fun clockProjection():PlaybackProjection?=null;fun arrangementCurrent(a:AcceptedArrangement)=false;fun localAccess()=graph.phoneAudio.current(graph.session.version())
SERVICE
 fun device():MediaItem {val ref=graph.phoneAudio.ref;val item=resolveDevice(MediaItem("device:${ref.id}",requestMetadata=MediaItem.Request(Bundle().apply {putString("playbackRef",ref.wire())})));grants[item.localConfiguration!!.uri.toString()]=grantFor(item,account);return item}
 fun extras(){publishSessionExtras()}
}
class Controller(val device:Facade) {val mutable=MutableStateFlow(PlaybackProjection());val state=mutable;var closed=false;var controller:Facade?=device;val connection=Connection();var queueRevision=0L;var projectedRevision=-1L;var projectedQueue=listOf<QueueOccurrence>();var contextError:String?=null;val syncAdmissions=mutableMapOf<String,SyncAdmission>();var performancePublication=0L
 class SyncAdmission {val identity:ArrangementIdentity?=null;val unlinkPublication:Long?=null;fun completeUnlink(observed:Boolean){error("Out of scope")}}
 fun retireScratch(){}
FIELDS
RETIRE
LISTENER
PUBLISH
 fun emit(){listener.onEvents(device,Player.Events())}
 fun error(error:PlaybackException?){device.playerError=error;listener.onPlayerErrorChanged(error);emit()}
 fun transition(index:Int){device.index=index;listener.onMediaItemTransition(device.currentMediaItem,1)}
}
class Fixture {val graph=Graph();val player=Facade();val service=Service(graph,player);val controller=Controller(player);val root=com.soundq.android.product.FailureRoot(graph,controller.state)
 init {player.items=listOf(service.device());service.extras();controller.emit();root.sync()}
 fun fail(){graph.phoneAudio.unavailable();service.extras();controller.error(PlaybackException());root.sync()}
}
internal fun Fixture.folded():DeviceAudio {
 val phone=graph.phoneAudio
 val survivor=phone.row.copy(id=DeviceFileId(UUID(0,3)),incarnation=7,objectId=ProviderObjectId("fixture","survivor"))
 phone.state.value=PhoneState(phone.state.value.snapshot!!.copy(files=listOf(survivor),retired=listOf(RetiredDeviceIdentity(phone.row.owner,survivor.id))))
 assertEquals(survivor,phone.state.value.snapshot!!.resolve(phone.id,phone.revision,phone.ref.incarnation))
 assertEquals(survivor,phone.observed(phone.ref));assertTrue(service.grants.values.single().current(graph))
 service.extras();controller.emit();root.sync();assertEquals(phone.ref,controller.state.value.selectedDeviceOwner!!.ref)
 return survivor
}
class PlayerFailureOwnerSeamTest {
 @Test fun providerProvenFoldedOriginalStillReportsUnavailableSourceFailure() {
  android.widget.Toast.reset();val f=Fixture();val survivor=f.folded();val phone=f.graph.phoneAudio
  phone.authority++;phone.state.value=PhoneState(phone.state.value.snapshot!!.copy(files=listOf(survivor.copy(aliases=survivor.aliases.map {it.copy(state=AccessState.UNREADABLE)}))))
  assertNull(phone.state.value.snapshot!!.resolve(phone.id,phone.revision,phone.ref.incarnation));assertFalse(f.service.grants.values.single().current(f.graph))
  f.service.extras();f.controller.error(PlaybackException());f.root.sync()
  assertEquals("A folded original retains its owner after read failure",listOf("Audio could not be played. Retry playback."),android.widget.Toast.shown)
 }
 @Test fun foldedOriginalCannotBorrowMissingAmbiguousChangedOrReusedOwnership() {
  for(kind in listOf("revision","length","mapping-missing","mapping-ambiguous","mapping-old-incarnation","target-missing","target-ambiguous","direct-reused-revision","direct-reused-incarnation","retired-only")) {
   android.widget.Toast.reset();val f=Fixture();val survivor=f.folded();val phone=f.graph.phoneAudio;val snapshot=phone.state.value.snapshot!!
   val changed=when(kind) {
    "revision"->snapshot.copy(files=listOf(survivor.copy(revision=ContentRevision("b".repeat(64),phone.ref.bytes))))
    "length"->snapshot.copy(files=listOf(survivor.copy(revision=ContentRevision(phone.ref.sha256,phone.ref.bytes+1))))
    "mapping-missing"->snapshot.copy(retired=emptyList())
    "mapping-ambiguous"->snapshot.copy(retired=snapshot.retired+RetiredDeviceIdentity(phone.row.owner,DeviceFileId(UUID(0,4))))
    "mapping-old-incarnation"->snapshot.copy(retired=listOf(RetiredDeviceIdentity(phone.row.owner.copy(incarnation=2),survivor.id)))
    "target-missing"->snapshot.copy(files=listOf(survivor.copy(id=DeviceFileId(UUID(0,4)))))
    "target-ambiguous"->snapshot.copy(files=listOf(survivor,survivor.copy(incarnation=8)))
    "direct-reused-revision"->snapshot.copy(files=listOf(survivor,phone.row.copy(revision=ContentRevision("b".repeat(64),phone.ref.bytes))))
    "direct-reused-incarnation"->snapshot.copy(files=listOf(survivor,phone.row.copy(incarnation=2)))
    "retired-only"->snapshot.copy(files=emptyList())
    else->error(kind)
   }
   phone.state.value=PhoneState(changed);assertNull(kind,changed.resolve(phone.id,phone.revision,phone.ref.incarnation));assertFalse(kind,f.service.grants.values.single().current(f.graph))
   phone.authority++;phone.state.value=PhoneState(changed.copy(files=changed.files.map {row->row.copy(aliases=row.aliases.map {it.copy(state=AccessState.UNREADABLE)})}))
   f.service.extras();f.controller.error(PlaybackException());f.root.sync();assertTrue("Refuse folded $kind",android.widget.Toast.shown.isEmpty())
  }
 }
 @Test fun foldedOriginalCannotBorrowNewLocalSessionAndDoesNotReplay() {
  android.widget.Toast.reset();val f=Fixture();f.folded();val phone=f.graph.phoneAudio
  f.graph.session.retire();phone.accepted=f.graph.session.version();assertNotNull(phone.observed(phone.ref));assertFalse(f.service.grants.values.single().current(f.graph))
  f.service.extras();f.controller.emit();f.root.sync();f.controller.error(PlaybackException());f.root.sync();assertTrue(android.widget.Toast.shown.isEmpty())
  f.root.sync();assertTrue(android.widget.Toast.shown.isEmpty())
 }
 @Test fun malformedDeviceIdentityWireProofIsIneligibleWithoutRootException() {
  for(kind in listOf("uuid","noncanonical-uuid","digest","length","incarnation")) {
   android.widget.Toast.reset();val f=Fixture();val valid=f.player.sessionExtras.getString("selectedDeviceOwner")!!;val ref=f.graph.phoneAudio.ref
   val invalid=when(kind) {"uuid"->valid.replace(ref.id,"not-a-uuid");"noncanonical-uuid"->valid.replace(ref.id,"0-0-0-0-1");"digest"->valid.replace(ref.sha256,"bad");"length"->valid.replace("\"bytes\":64","\"bytes\":-1");"incarnation"->valid.replace("\"incarnation\":1","\"incarnation\":0");else->error(kind)}
   assertNotEquals(valid,invalid);f.player.sessionExtras.putString("selectedDeviceOwner",invalid);f.controller.emit();f.root.sync();assertNull(f.controller.state.value.selectedDeviceOwner)
   f.graph.phoneAudio.unavailable();f.controller.error(PlaybackException());f.root.sync();assertTrue(kind,android.widget.Toast.shown.isEmpty())
  }
 }
 @Test fun catalogResolverKeepsReadReadinessAndExistingFoldCandidateFiltering() {
  val f=Fixture();val phone=f.graph.phoneAudio;val survivor=f.folded();val folded=phone.state.value.snapshot!!
  val unreadable=survivor.copy(aliases=survivor.aliases.map {it.copy(state=AccessState.UNREADABLE)})
  assertNull(folded.copy(files=listOf(unreadable)).resolve(phone.id,phone.revision,phone.ref.incarnation))
  // Existing read resolution filters availability while counting folded candidates.
  assertEquals(survivor,folded.copy(files=listOf(survivor,unreadable)).resolve(phone.id,phone.revision,phone.ref.incarnation))
  assertNull(folded.copy(files=listOf(survivor,survivor)).resolve(phone.id,phone.revision,phone.ref.incarnation))
  assertNull(folded.copy(files=listOf(survivor,phone.row.copy(incarnation=2))).resolve(phone.id,phone.revision,phone.ref.incarnation))
  assertEquals(phone.row,folded.copy(files=listOf(survivor,phone.row)).resolve(phone.id,phone.revision,phone.ref.incarnation))
  assertNull(folded.copy(files=listOf(survivor,phone.row.copy(aliases=emptyList()))).resolve(phone.id,phone.revision,phone.ref.incarnation))
 }
 @Test fun normalPreparationAndCursorPublicationsRemainSilent() {
  android.widget.Toast.reset();val f=Fixture();f.player.playbackState=Player.STATE_BUFFERING
  repeat(3){f.player.currentPosition++;f.controller.emit();f.root.sync()}
  assertTrue(f.controller.state.value.preparing);assertEquals(0L,f.controller.state.value.failureRevision);assertTrue(android.widget.Toast.shown.isEmpty())
 }
 @Test fun accountEpochMatchCannotSubstituteForSelectedDeviceGrantVersion() {
  android.widget.Toast.reset();val f=Fixture();val n=f.graph.session.beginIntent();f.graph.session.accept(n,SecretTokens("access","refresh","account"));f.service.account=f.graph.session.capture();f.graph.phoneAudio.accepted=f.graph.session.version()
  f.service.extras();f.controller.emit();f.root.sync();assertEquals(f.graph.session.version(),f.controller.state.value.accountEpoch)
  f.fail();assertTrue("Account epoch is not the selected phone grant",android.widget.Toast.shown.isEmpty())
 }
 @Test fun malformedOrMissingWireProofCannotUseTheGuestSentinelAsAuthority() {
  for(raw in listOf(null,"{broken}","x".repeat(4097))) {android.widget.Toast.reset();val f=Fixture();if(raw==null)f.player.sessionExtras.fields.remove("selectedDeviceOwner")else f.player.sessionExtras.putString("selectedDeviceOwner",raw);f.controller.emit();f.root.sync();f.graph.phoneAudio.unavailable();f.controller.error(PlaybackException());f.root.sync();assertTrue(android.widget.Toast.shown.isEmpty())}
 }
 @Test fun signedOutSelectedDeviceFailureUsesGrantVersionDespiteNegativeAccountSentinel() {
  android.widget.Toast.reset();val f=Fixture();assertTrue(f.graph.session.version()>0);assertEquals(-1L,f.controller.state.value.accountEpoch)
  f.fail();assertNull(f.graph.phoneAudio.observed(f.graph.phoneAudio.ref));assertFalse(f.service.grants.values.single().current(f.graph));assertEquals("Fresh guest failure must reach the root Toast",listOf("Audio could not be played. Retry playback."),android.widget.Toast.shown)
 }
 @Test fun currentAccountOwnedFailureStillReachesRootButStaleEpochDoesNot() {
  android.widget.Toast.reset();val f=Fixture();val intent=f.graph.session.beginIntent();assertTrue(f.graph.session.accept(intent,SecretTokens("access","refresh","account")));f.service.account=f.graph.session.capture()
  f.player.items=listOf(MediaItem("server",MediaMetadata(extras=Bundle().apply {putLong("trackId",7);putString("playbackRef",PlaybackRef.Server("endpoint","account",7).wire())})));f.service.extras();f.controller.queueRevision++;f.controller.emit();f.root.sync()
  f.controller.error(PlaybackException());f.root.sync();assertEquals(1,android.widget.Toast.shown.size)
  f.controller.error(null);f.root.sync();f.graph.session.retire();f.controller.error(PlaybackException());f.root.sync();assertEquals(1,android.widget.Toast.shown.size)
 }
 @Test fun staleLocalVersionAndAccountAbaCannotBorrowCurrentSession() {
  for(replace in listOf(false,true)) {android.widget.Toast.reset();val f=Fixture();if(replace){val n=f.graph.session.beginIntent();f.graph.session.accept(n,SecretTokens("access","refresh","account"))};f.graph.session.retire();f.graph.phoneAudio.accepted=f.graph.session.version();f.service.extras();f.controller.emit();f.root.sync();f.fail();assertTrue(android.widget.Toast.shown.isEmpty())}
 }
 @Test fun unknownOrDifferentRefSelectionAndNonQueueSourcesFailClosed() {
  for(kind in listOf("null","different-ref","selection","source","removed","replacement","duplicate")) {android.widget.Toast.reset();val f=Fixture();val p=f.controller.state.value
   when(kind) {
    "null"->f.player.items=listOf(MediaItem(p.selectedOccurrence!!,MediaMetadata(extras=Bundle().apply {putBoolean("localOnly",true)})))
    "different-ref"->f.player.items=listOf(MediaItem(p.selectedOccurrence!!,MediaMetadata(extras=Bundle().apply {putBoolean("localOnly",true);putString("playbackRef",f.graph.phoneAudio.ref.copy(sha256="b".repeat(64)).wire())}),f.player.currentMediaItem!!.localConfiguration))
    "selection"->f.player.items=listOf(MediaItem("replacement",f.player.currentMediaItem!!.mediaMetadata))
    "source"->f.player.items=listOf(MediaItem("mix:replacement"))
    "removed"->f.graph.phoneAudio.state.value=PhoneState(null)
    "replacement"->f.graph.phoneAudio.state.value=PhoneState(f.graph.phoneAudio.state.value.snapshot!!.copy(files=listOf(f.graph.phoneAudio.row.copy(incarnation=2))))
    "duplicate"->f.player.items=f.player.items+f.player.items
   }
   f.service.extras();f.controller.queueRevision++;f.controller.emit();f.root.sync();f.controller.error(PlaybackException());f.root.sync();assertTrue("Refused $kind",android.widget.Toast.shown.isEmpty())
  }
 }
 @Test fun backgroundLockedPendingAndUnacceptedPhoneFailuresAreConsumedWithoutReplay() {
  for(kind in listOf("background","locked","pending","phone-pending","disconnected")) {android.widget.Toast.reset();val f=Fixture()
   when(kind){"background"->f.root.lifecycle.currentState=com.soundq.android.product.Lifecycle.State.STARTED;"locked"->{val n=f.graph.session.beginIntent();f.graph.session.accept(n,SecretTokens("access","refresh","account"));f.graph.session.lockLocal()};"pending"->f.graph.session.beginIntent();"phone-pending"->f.graph.phoneAudio.accepted=-1;"disconnected"->f.controller.mutable.value=f.controller.state.value.copy(connection=PlaybackProjection.Connection.Disconnected)}
   if(kind=="disconnected"){f.controller.mutable.value=f.controller.state.value.copy(error="Audio could not be played. Retry playback.",failureRevision=1);f.root.sync()}else f.fail()
   assertTrue(kind,android.widget.Toast.shown.isEmpty());f.root.lifecycle.currentState=com.soundq.android.product.Lifecycle.State.RESUMED;f.graph.phoneAudio.accepted=f.graph.session.version();f.root.sync();assertTrue("No replay $kind",android.widget.Toast.shown.isEmpty())
  }
 }
 @Test fun selectionAbaPollingAndCanonicalClearNeverReplayAndOnlyFreshEpisodeRearms() {
  android.widget.Toast.reset();val f=Fixture();val item=f.player.items.single();f.player.items=listOf(item,MediaItem("other"));f.controller.queueRevision++;f.controller.emit();f.root.sync();f.fail();assertEquals(1,android.widget.Toast.shown.size)
  val old=f.controller.state.value.selectionIncarnation;f.controller.transition(1);f.controller.transition(0);f.controller.emit();f.root.sync();assertTrue(f.controller.state.value.selectionIncarnation>old);assertEquals(1,android.widget.Toast.shown.size)
  repeat(3){f.controller.error(PlaybackException());f.root.sync()};assertEquals(1,android.widget.Toast.shown.size)
  f.controller.error(null);f.root.sync();repeat(3){f.controller.emit();f.root.sync()};assertEquals(1,android.widget.Toast.shown.size)
  f.controller.error(PlaybackException());f.root.sync();assertEquals(2,android.widget.Toast.shown.size)
  f.root.feedback.close();f.controller.error(null);f.controller.error(PlaybackException());f.root.sync();assertEquals(2,android.widget.Toast.shown.size)
 }
}
'''
probe = probe.replace('android.widget.Toast', 'ProbeToast')
probe = re.sub(r'^(class (?!PlayerFailureOwnerSeamTest)|open class |interface |object )', r'internal \1', probe, flags=re.MULTILINE)
for marker, value in [('GRANT', grant), ('SERVICE', service), ('FIELDS', fields), ('RETIRE', block(controller_path, '    private fun retireSelection(')), ('LISTENER', block(controller_path, '    private val listener=')), ('PUBLISH', block(controller_path, '    private fun publish('))]:
    probe = probe.replace('\n' + marker + '\n', '\n' + value + '\n')
emit('PlayerFailureOwnerSeamTest.kt', probe)
if a.standalone:
    emit('Projection.kt', 'package com.soundq.android.playback\nimport com.soundq.android.failureownerprobe.Player\n' + declarations)
root_sync = block('product/PlayerFailureToasts.kt', '    fun sync()')
emit('FailureRoot.kt', '''package com.soundq.android.product
import com.soundq.android.data.*
import com.soundq.android.playback.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.failureownerprobe.Graph
import com.soundq.android.failureownerprobe.ProbeContext
import com.soundq.android.failureownerprobe.ProbeToast
import kotlinx.coroutines.flow.MutableStateFlow
class Lifecycle {enum class State {STARTED,RESUMED;fun isAtLeast(other:State)=ordinal>=other.ordinal};var currentState=State.RESUMED}
internal class FailureModel(val graph:Graph,val playback:MutableStateFlow<PlaybackProjection>)
internal class FailureRoot(graph:Graph,playback:MutableStateFlow<PlaybackProjection>) {val model=FailureModel(graph,playback);val lifecycle=Lifecycle();val feedback=ProbePlayerFailureFeedback(ProbeContext())
''' + root_sync + '\n}\n')
feedback = (b / 'product/PlayerFailureFeedback.kt').read_text().replace('PlayerFailureFeedback', 'ProbePlayerFailureFeedback').replace('import android.content.Context', 'import com.soundq.android.failureownerprobe.ProbeContext as Context').replace('import android.widget.Toast', 'import com.soundq.android.failureownerprobe.ProbeToast as Toast')
emit('Feedback.kt', feedback)
emit('Toast.kt', '''package com.soundq.android.failureownerprobe
internal class ProbeContext
internal class ProbeToast(val message:String) {fun show(){shown+=message};fun cancel(){cancelled++};companion object {const val LENGTH_LONG=1;val shown=mutableListOf<String>();var cancelled=0;fun reset(){shown.clear();cancelled=0};fun makeText(c:ProbeContext,m:String,d:Int)=ProbeToast(m)}}
''')
if a.standalone:
    emit('OutOfScope.kt', '''package com.soundq.android.playback
import kotlinx.serialization.Serializable
@Serializable data class ArrangementIdentity(val install:String="",val accountEpoch:Long=0)
@Serializable class AcceptedArrangement(val identity:ArrangementIdentity,val sources:List<QueueOccurrence>) {fun withProjectedDocument()=this}
@Serializable class PerformanceTarget(val identity:ArrangementIdentity,val occurrence:String)
@Serializable class PerformanceDeck(val target:PerformanceTarget,val syncState:LiveSyncState)
@Serializable enum class LiveSyncState {Off}
@Serializable class TempoPreviewState
@Serializable data class PlaybackClockAuthority(val spans:List<String>?=null)
@Serializable class ListeningSpeedState(val occurrence:String)
''')
emit('NativeBoundary.kt', '''package com.soundq.android.failureownerprobe
import com.soundq.android.playback.*
internal class NativeCallbackPlayer:Facade() {fun listeningSpeed():ListeningSpeedState?=error("Native speed outside fixture");val tempoPreviewState:TempoPreviewState? get()=error("Outside fixture");val performanceDecks:Map<String,PerformanceDeck> get()=error("Outside fixture");fun canPerform(i:ArrangementIdentity):Boolean=error("Outside fixture")}
''')
if a.standalone:
    emit('DataBoundary.kt', 'package com.soundq.android.data\nclass LibraryCollection\n')
    emit('DeviceBoundary.kt', 'package com.soundq.android.data.device\nclass PhoneSourceAdmission\n')
# Collaborator sources are copied, never linked against a running Gradle build.
for rel in ['data/Contracts.kt', 'data/AccountSession.kt', 'data/deviceaudio/DeviceAudioTypes.kt', 'playback/PlaybackRef.kt', 'playback/QueueOrigin.kt', 'playback/PlaybackFailureEvents.kt', 'product/PlayerFailureFeedback.kt', 'playback/SelectedDevicePlaybackOwner.kt']:
    src = b / rel
    if src.exists():
        if a.standalone and rel != 'product/PlayerFailureFeedback.kt':
            emit(src.name, src.read_text())
        extracted[rel] = hashlib.sha256(src.read_bytes()).hexdigest()
(a.generate / 'extraction.json').write_text(json.dumps(extracted, indent=2) + '\n')
print('Generated real service/controller/root failure seam in', a.generate)
