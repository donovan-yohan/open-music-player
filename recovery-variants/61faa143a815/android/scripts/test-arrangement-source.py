#!/usr/bin/env python3
"""Exact service admission/READY callback extraction. Android/Media3 only are facades.

Real TimelineRepository, AccountSession, strict MixJson and JNI stream remain in use.
The baseline's absent custom command is executed as ordinary unsupported-command refusal.
"""
import argparse
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);a=p.parse_args()
base=Path(__file__).resolve().parents[1]/'app/src/main/kotlin/com/soundq/android'
text=(base/'playback/SoundQLibraryService.kt').read_text()
def block(marker):
    start=text.index(marker);opening=text.index('{',start);depth=1;i=opening+1
    while depth:
        if text[i]=='{':depth+=1
        elif text[i]=='}':depth-=1
        i+=1
    return text[start:i]
command=block('            if(customCommand.customAction==APPLY_ARRANGEMENT)') if 'if(customCommand.customAction==APPLY_ARRANGEMENT)' in text else ''
# This fixture intentionally exercises the legacy finite-source branch only. Native
# callback schedule is covered by test-overlap-* and real Host capture instead.
if '                    if(native!=null) {' in command:
    first=command.index('                    if(native!=null) {')
    end=command.index('                    require(graph.timeline.installAudition(request,scope,document) {', command.index('                        return result',first))
    command=command[:first]+command[end:]
command=command.replace('if(player is com.soundq.android.playback.nativeengine.NativeCallbackPlayer) \"soundqarrangement://schedule/${identity.install}\" else ', '')
command=command.replace('com.soundq.android.playback.nativeengine.NativeCallbackPlayer','NativeCallbackPlayerFacade')
helpers='\n'.join(block(marker) for marker in ['    private fun arrangementCurrent(', '    private fun arrangementReady(', '    private fun retireArrangement('] if marker in text)
ready_callback=block('            override fun onPlaybackStateChanged(').replace('override fun','fun') if 'override fun onPlaybackStateChanged(' in text else 'fun onPlaybackStateChanged(state:Int){}'
request=block('        override fun onPlayerCommandRequest(')
request=request[request.index('{')+1:-1]
# Type-only mapping for new native retirement hooks in this explicitly legacy-only facade.
request=request.replace('com.soundq.android.playback.nativeengine.NativeCallbackPlayer','NativeCallbackPlayerFacade')
import re
constants=sorted(set(re.findall(r'Player\.(COMMAND_\w+)',request)))
def controller_block(marker):
    global text
    prior=text;text=(base/'playback/ControllerProjection.kt').read_text()
    result=block(marker);text=prior;return result
seek=controller_block('    fun seekArrangement(')
prelude=r'''package com.soundq.android.extractedarrangement
import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import com.soundq.android.playback.mix.*
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import java.util.UUID
import java.io.File
import org.junit.Assert.*
class Bundle {val fields=mutableMapOf<String,Any>();fun putString(k:String,v:String){fields[k]=v};fun getString(k:String)=fields[k] as? String;fun putLong(k:String,v:Long){fields[k]=v};fun getLong(k:String,default:Long=0)=fields[k] as? Long ?: default;companion object {val EMPTY=Bundle()}}
class Uri private constructor(val value:String){val scheme get()=value.substringBefore(':');override fun toString()=value;companion object {fun parse(v:String)=Uri(v)}}
class MediaMetadata(val title:String="",val artist:String="",val extras:Bundle=Bundle()) {class Builder {var title="";var artist="";var extras=Bundle();fun setTitle(v:String)=apply{title=v};fun setArtist(v:String)=apply{artist=v};fun setExtras(v:Bundle)=apply{extras=v};fun setIsPlayable(v:Boolean)=this;fun setIsBrowsable(v:Boolean)=this;fun build()=MediaMetadata(title,artist,extras)}}
class LocalConfiguration(val uri:Uri)
class MediaItem(val mediaId:String,val uri:Uri?,val mediaMetadata:MediaMetadata) {val localConfiguration get()=uri?.let(::LocalConfiguration);class Builder {var id="";var uri:Uri?=null;var meta=MediaMetadata();fun setMediaId(v:String)=apply{id=v};fun setUri(v:Uri)=apply{uri=v};fun setMimeType(v:String)=this;fun setMediaMetadata(v:MediaMetadata)=apply{meta=v};fun build()=MediaItem(id,uri,meta)}}
class SessionResult(val resultCode:Int,val extras:Bundle=Bundle()) {companion object {const val RESULT_SUCCESS=0}}
object SessionError {const val ERROR_BAD_VALUE=-1;const val ERROR_PERMISSION_DENIED=-2;const val ERROR_INVALID_STATE=-3}
object Futures {fun immediateFuture(v:SessionResult)=v}
class Command(val customAction:String)
object Player {const val STATE_READY=3;const val COMMAND_SEEK_TO_NEXT_MEDIA_ITEM=1001;const val COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM=1002;const val COMMAND_SEEK_BACK=1003;const val COMMAND_SEEK_FORWARD=1004}
open class PlayerFacade {var items=listOf<MediaItem>();val mediaItemCount get()=items.size;val currentMediaItem get()=items.firstOrNull();val currentMediaItemIndex=0;val currentPosition=0L;var playbackState=0;var isPlaying=false;var playCalls=0;var position=0L;var prepareCalls=0;fun pause(){isPlaying=false};fun stop(){isPlaying=false;playbackState=0};fun setMediaItem(i:MediaItem){items=listOf(i);position=0};fun seekTo(ms:Long){position=ms};fun getMediaItemAt(i:Int)=items[i];fun prepare(){prepareCalls++;playbackState=2};fun play(){check(playbackState==3);isPlaying=true;playCalls++}}
class NativeCallbackPlayerFacade:PlayerFacade() {fun retirePerformanceTransport():Unit=error("Native path outside legacy facade");fun revokePerformance():Unit=error("Native path outside legacy facade")}
class Interruption {fun command(){}}
class TransportFacade(private val player:PlayerFacade) {fun selectionCommitted(){};fun retire(){};fun pause(){player.pause()}}
class SaveJob {fun cancel(){}}
class Graph(val session:AccountSession,val timeline:TimelineRepository)
class Service(val graph:Graph) {
 private val continuation=object {fun command(){};fun ended(state:Int){if(state!=Player.STATE_READY)error("Continuation outside arrangement READY fixture")}}
 val liveQualifications=mutableMapOf<String,Any>();val retiringLiveQualifications=mutableSetOf<String>()
 val player=PlayerFacade();val transport=TransportFacade(player);val serviceIncarnation=UUID.randomUUID().toString();var sourceQueueIncarnation="ordinary-1";var selectionEpoch=0L;var transportGeneration=0L;var account=graph.session.capture();val interruptions=Interruption();var saveJob:SaveJob?=null;var undo:Any?=null;var undoScope:AccountScope?=null;var undoIndex=0;var undoPosition=0L
 internal val mixGrants=java.util.concurrent.ConcurrentHashMap<String,MixGrant>()
 var tempoCaller:Any?=null
 var acceptedArrangement:AcceptedArrangement?=null;var arrangementItems:List<MediaItem>?=null;var pendingArrangement:Pair<AcceptedArrangement,Long>?=null
 val APPLY_ARRANGEMENT="soundq.arrangement.apply"
 fun sourceOccurrences()=player.items.map {QueueOccurrence(it.mediaId,7,"Duplicate","Fixture",false,2000)}
 fun publishSessionExtras(){}
 fun admitted(controller:Any)=true
'''
prelude=prelude.replace('object Player {','object Player {'+';'.join('const val '+c+'='+str(2000+i) for i,c in enumerate(constants) if 'const val '+c+'=' not in prelude)+';')
# The missing baseline types are test-only compatibility shapes. The production
# mapping below is intentionally not provided by these shapes.
compat=''
if not (base/'playback/Arrangement.kt').exists():
    compat='''data class ArrangementIdentity(val service:String,val accountEpoch:Long,val queue:String,val revision:Long,val install:String)
data class AcceptedArrangement(val identity:ArrangementIdentity,val document:TimelineDocument,val sources:List<QueueOccurrence>)
'''
fixture=r'''
class ControllerFacade(val currentMediaItem:MediaItem?,val sessionExtras:Bundle=Bundle()) {val duration=1000000L;var paused=false;var seeked:Long?=null;fun pause(){paused=true};fun seekTo(ms:Long){seeked=ms}}
class ControllerHarness(val controller:ControllerFacade?,p:PlaybackProjection) {val state=kotlinx.coroutines.flow.MutableStateFlow(p)
'''+seek+'''
}
class ArrangementServiceExtractedTest {
 @org.junit.Test fun exactControllerGlobalSeekUsesSameInstalledPlayerAndPauses() {
  val (g,s,d)=setup();assertEquals(0,apply(s,d).resultCode);val accepted=s.acceptedArrangement!!
  val facade=ControllerFacade(s.player.currentMediaItem,Bundle().apply {putLong("accountEpoch",accepted.identity.accountEpoch)})
  val c=ControllerHarness(facade,PlaybackProjection(arrangement=accepted))
  c.seekArrangement(accepted.identity,750);assertTrue(facade.paused);assertEquals(750L,facade.seeked)
  facade.seeked=null;c.seekArrangement(accepted.identity.copy(install="retired"),100);assertNull(facade.seeked)
 }
 fun setup():Triple<Graph,Service,TimelineDocument> {
  val s=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore());s.accept(s.beginIntent(),SecretTokens("a","r","fixture"))
  val directory=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"arrangement-test-").toFile()
  val repo=TimelineRepository(s,directory){_,_,_,_->error("No waveform IO")}
  val g=Graph(s,repo);val service=Service(g)
  service.player.items=listOf("occ-a","occ-b").map {MediaItem(it,null,MediaMetadata())}
  repo.observe(s.capture()!!,listOf("occ-a","occ-b").map {TimelineSource(it,7,"Duplicate",2000,QueueSegment.Context)})
  fun edit(index:Int,kind:EditKind,value:Long){val d=repo.state.value.document;check(repo.commit(TimelineEdit(d.revision,d.clips[index],kind,value)){true})}
  edit(0,EditKind.TrimIn,250);edit(0,EditKind.TrimOut,1500);edit(1,EditKind.Placement,500);edit(1,EditKind.TrimOut,1250)
  return Triple(g,service,repo.state.value.document)
 }
 fun apply(s:Service,d:TimelineDocument,epoch:Long=s.graph.session.capture()!!.epoch,queue:String=s.sourceQueueIncarnation,service:String=s.serviceIncarnation):SessionResult {
  var admitted=true
  val token=s.graph.timeline.captureAudition(s.graph.session.capture()!!,d){admitted} ?: "retired"
  val args=Bundle().apply {putString("document",Json.encodeToString(d));putString("service",service);putString("queue",queue);putLong("accountEpoch",epoch);putString("request",token)}
  return s.command(args)
 }
 @org.junit.Test fun actualProductionCommandAcceptsFrozenDuplicateOccurrenceDraftAndReadyCallbackPlaysOnlyInstalledIdentity() {
  val (g,s,d)=setup()
  val result=apply(s,d)
  assertEquals("Explicit accepted waveform command is missing or refused",0,result.resultCode)
  assertFalse(s.player.isPlaying);assertEquals(1,s.player.prepareCalls)
  val accepted=s.acceptedArrangement!!;assertEquals(d,accepted.document);assertEquals(listOf("occ-a","occ-b"),accepted.sources.map {it.occurrenceId})
  g.timeline.observe(g.session.capture()!!,accepted.sources.map {TimelineSource(it.occurrenceId,it.trackId,it.title,it.durationMs,QueueSegment.Context)})
  assertSame(d,g.timeline.state.value.document)
  s.player.playbackState=Player.STATE_READY;s.ready()
  assertTrue(s.player.isPlaying);assertEquals(1,s.player.playCalls)
  assertEquals(d,s.acceptedArrangement!!.document)
 }
 @org.junit.Test fun sameContentAccountServiceQueueAndDocumentAbaRefuseWithoutReplacingOldOwner() {
  val (g,s,d)=setup();val original=s.player.items
  assertEquals(-1,apply(s,d,service="retired-service").resultCode);assertSame(original,s.player.items)
  assertEquals(-1,apply(s,d,queue="retired-queue").resultCode);assertSame(original,s.player.items)
  val epoch=g.session.capture()!!.epoch;g.session.accept(g.session.beginIntent(),SecretTokens("a","r","fixture"))
  assertEquals(-1,apply(s,d,epoch).resultCode);assertSame(original,s.player.items)
  val (g2,s2,d2)=setup();val c=d2.clips.first();g2.timeline.commit(TimelineEdit(d2.revision,c,EditKind.Placement,1)){true}
  assertEquals(-1,apply(s2,d2).resultCode);assertNull(s2.acceptedArrangement)
 }
 @org.junit.Test fun acceptedProductionCommandFeedsActualJniMixedTrimPlacementOracle() {
  val fixture=System.getProperty("soundq.mix.fixture") ?: error("JNI fixture is required for this acceptance")
  val (_,s,d)=setup();assertEquals(0,apply(s,d).resultCode)
  val plan=s.mixGrants.values.single().plan
  assertEquals(listOf("occ-a","occ-b"),plan.clips.map {it.occurrence});assertEquals(1750L,plan.duration)
  val decoded=java.nio.ByteBuffer.wrap(File(fixture,"arrangement.decoded").readBytes()).order(java.nio.ByteOrder.LITTLE_ENDIAN)
  var checked=0
  NativeMixStream(plan,mapOf(7L to File(fixture,"arrangement.opus").absolutePath)).use {stream ->
   val bytes=ByteArray(2048*8)
   var frame=0L
   while(frame<84000) {
    val count=minOf(2048L,84000-frame).toInt();assertEquals(count*8,stream.read(44+frame*8,bytes,0,count*8))
    val out=java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
    repeat(count) {f ->val t=frame+f;repeat(2) {ch ->
     var expected=0f
     if(t<60000)expected+=decoded.getFloat(((12000+t)*2+ch).toInt()*4)
     if(t>=24000 && t<84000)expected+=decoded.getFloat(((t-24000)*2+ch).toInt()*4)
     assertEquals(expected,out.float,.00008f);checked++
    }}
    frame+=count
   }
   // Backwards global seek uses the same immutable native handle and source trims.
   stream.read(44+30000*8L,bytes,0,8)
   val seek=java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
   repeat(2){ch->assertEquals(decoded.getFloat((42000*2+ch)*4)+decoded.getFloat((6000*2+ch)*4),seek.float,.00008f)}
  }
  assertEquals(168000,checked)
 }
 @org.junit.Test fun acceptedRepositoryNonOneRateReachesServiceRefusalBeforeOwnerMutation() {
  val (g,s,d)=setup()
  val scope=g.session.capture()!!
  val directory=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"arrangement-rate-").toFile()
  val hash=java.security.MessageDigest.getInstance("SHA-256").digest((g.session.endpoint.identity+"\u0000"+scope.accountId).toByteArray()).joinToString(""){"%02x".format(it)}
  val bad=d.copy(clips=d.clips.map {it.copy(rates=RateAutomation(1.25))})
  File(directory,"arrangement-$hash.v1.json").writeText("""{"version":1,"document":${Json.encodeToString(bad)}}""")
  val repo=TimelineRepository(g.session,directory){_,_,_,_->error("no analysis")}
  repo.observe(scope,d.clips.map {TimelineSource(it.occurrence,it.track,it.title,it.sourceDurationMs,it.segment)})
  val graph=Graph(g.session,repo);val service=Service(graph);service.player.items=s.player.items
  val accepted=repo.state.value.document;assertEquals(1.25,accepted.clips.first().rates.baseRate,0.0)
  val before=service.player.items
  assertEquals(-1,apply(service,accepted).resultCode);assertSame(before,service.player.items);assertNull(service.acceptedArrangement)
  assertSame(accepted,repo.state.value.document)
 }
 @org.junit.Test fun unsupportedRateRefusalKeepsExistingInstalledOwnerAndDraft() {
  val (g,s,d)=setup();assertEquals(0,apply(s,d).resultCode);val old=s.acceptedArrangement;val items=s.player.items
  val clip=d.clips.first();val edit=TimelineEdit(d.revision,clip.copy(rates=RateAutomation(1.25)),EditKind.Placement,0)
  val bad=d.copy(revision=d.revision+1,clips=listOf(clip.copy(rates=RateAutomation(1.25)))+d.clips.drop(1))
  assertTrue(runCatching {bad.arrangementPlan()}.isFailure)
  assertEquals(-1,apply(s,bad).resultCode);assertSame(old,s.acceptedArrangement);assertSame(items,s.player.items)
 }
 @org.junit.Test fun canceledQueuedCommandAndCanceledHeldReadyCannotInstallOrPlay() {
  val (g,s,d)=setup();var live=true;val token=g.timeline.captureAudition(g.session.capture()!!,d){live}!!
  val args=Bundle().apply {putString("document",Json.encodeToString(d));putString("service",s.serviceIncarnation);putString("queue",s.sourceQueueIncarnation);putLong("accountEpoch",g.session.capture()!!.epoch);putString("request",token)}
  live=false;assertEquals(-1,s.command(args).resultCode);assertNull(s.acceptedArrangement)
  live=true;val next=g.timeline.captureAudition(g.session.capture()!!,d){live}!!;args.putString("request",next)
  assertEquals(0,s.command(args).resultCode);live=false
  s.player.playbackState=Player.STATE_READY;s.ready();assertEquals(0,s.player.playCalls)
 }
 @org.junit.Test fun actualSeekVariantsRetirePendingArrangementNotOnlySelectionMetadata() {
  for(command in listOf(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,Player.COMMAND_SEEK_BACK,Player.COMMAND_SEEK_FORWARD)) {
   val (_,s,d)=setup();assertEquals(0,apply(s,d).resultCode);val old=s.acceptedArrangement!!;s.playerCommand(command)
   assertEquals(0,apply(s,d).resultCode);assertNotEquals(old.identity,s.acceptedArrangement!!.identity)
   // Simulated old loader READY cannot play because it is not the installed media item.
   val current=s.player.items;s.player.items=listOf(MediaItem(old.identity.install,null,MediaMetadata()));s.player.playbackState=Player.STATE_READY;s.ready();assertEquals(0,s.player.playCalls)
   s.player.items=current
   assertEquals(0,apply(s,d).resultCode);s.playerCommand(command)
   s.player.playbackState=Player.STATE_READY;s.ready();assertEquals("Held arrangement must not play after command $command",0,s.player.playCalls)
  }
 }
 @org.junit.Test fun heldReadyAfterStopSeekLocalLockAccountOrDraftReplacementNeverPlays() {
  for(change in 0..4) {
   val (g,s,d)=setup();assertEquals(0,apply(s,d).resultCode)
   when(change) {0,1->s.selectionEpoch++;2->g.session.lockLocal();3->g.session.accept(g.session.beginIntent(),SecretTokens("a","r","fixture"));4->g.timeline.commit(TimelineEdit(d.revision,d.clips.first(),EditKind.Placement,1)){true}}
   s.player.playbackState=Player.STATE_READY;s.ready();assertEquals(0,s.player.playCalls)
  }
 }

 @org.junit.Test fun explicitlyAcceptedOccurrenceCrossfadeReachesServiceJniEqualPowerEnvelope() {
  val fixture=System.getProperty("soundq.mix.fixture") ?: error("JNI fixture required")
  val (g,s,before)=setup()
  val edit=TimelineFadeEdit(before.revision,before.clips[0],before.clips[1],750)
  assertTrue(g.timeline.preview(edit).accepted);assertSame(before,g.timeline.state.value.document)
  assertTrue(g.timeline.commit(edit){true})
  val d=g.timeline.state.value.document
  assertEquals(0,apply(s,d).resultCode)
  val plan=s.mixGrants.values.single().plan
  assertEquals(750L,plan.clips[0].fadeOut);assertEquals(750L,plan.clips[1].fadeIn)
  assertEquals(500L,plan.clips[0].end-plan.clips[0].fadeOut)
  assertEquals(1250L,plan.clips[1].start+plan.clips[1].fadeIn)
  val decoded=java.nio.ByteBuffer.wrap(File(fixture,"arrangement.decoded").readBytes()).order(java.nio.ByteOrder.LITTLE_ENDIAN)
  var checked=0
  NativeMixStream(plan,mapOf(7L to File(fixture,"arrangement.opus").absolutePath)).use {stream ->
   val bytes=ByteArray(2048*8);var frame=0L
   while(frame<84000) {
    val count=minOf(2048L,84000-frame).toInt();assertEquals(count*8,stream.read(44+frame*8,bytes,0,count*8))
    val out=java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
    repeat(count) {f->val t=frame+f
     val u=(t-24000).toDouble()/36000
     val outgoing=if(t<24000)1.0 else kotlin.math.cos(u*Math.PI/2)
     val incoming=if(t>=60000)1.0 else kotlin.math.sin(u*Math.PI/2)
     repeat(2) {ch->
      var expected=0.0
      if(t<60000)expected+=decoded.getFloat(((12000+t)*2+ch).toInt()*4)*outgoing
      if(t>=24000)expected+=decoded.getFloat(((t-24000)*2+ch).toInt()*4)*incoming
      assertEquals(expected.toFloat(),out.float,.00008f);checked++
     }
    };frame+=count
   }
   // Exact envelope midpoint after a backwards seek, through the same native handle.
   assertEquals(8,stream.read(44+42000*8L,bytes,0,8))
   val seek=java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
   repeat(2) {ch->val expected=(decoded.getFloat((54000*2+ch)*4)+decoded.getFloat((18000*2+ch)*4))*kotlin.math.sqrt(.5f);assertEquals(expected,seek.float,.00008f)}
  }
  assertEquals(168000,checked)
 }
 @org.junit.Test fun referenceLinkedPlacementFullDocumentAckReachesServiceJniAndBackwardsSeek() {
  val fixture=System.getProperty("soundq.mix.fixture") ?: error("JNI fixture required")
  val (g,s,unlinked)=setup()
  val phase=PhaseEdit(unlinked.revision,unlinked.clips[0],unlinked.clips[1],
    PhaseGrid("manual:7:2000","local-a",500,500,0),PhaseGrid("manual:7:2000","local-b",500,250,250),1,430)
  assertTrue(g.timeline.preview(phase).accepted);assertTrue(g.timeline.commit(phase){true})
  val before=g.timeline.state.value.document
  assertEquals(500L,before.clips[1].globalStartMs);assertEquals(1L,before.phaseLink!!.relativeSteps)
  val edit=TimelineFadeEdit(before.revision,before.clips[0],before.clips[1],750)
  assertTrue(g.timeline.preview(edit).accepted);assertSame(before,g.timeline.state.value.document)
  assertTrue(g.timeline.commit(edit){true})
  val d=g.timeline.state.value.document
  assertEquals(0,apply(s,d).resultCode)
  assertEquals(d,s.acceptedArrangement!!.document)
  assertNotNull(s.acceptedArrangement!!.document.phaseLink)
  val plan=s.mixGrants.values.single().plan
  assertEquals(750L,plan.clips[0].fadeOut);assertEquals(750L,plan.clips[1].fadeIn)
  assertEquals(500L,plan.clips[0].end-plan.clips[0].fadeOut)
  assertEquals(1250L,plan.clips[1].start+plan.clips[1].fadeIn)
  val decoded=java.nio.ByteBuffer.wrap(File(fixture,"arrangement.decoded").readBytes()).order(java.nio.ByteOrder.LITTLE_ENDIAN)
  var checked=0
  NativeMixStream(plan,mapOf(7L to File(fixture,"arrangement.opus").absolutePath)).use {stream ->
   val bytes=ByteArray(2048*8);var frame=0L
   while(frame<84000) {
    val count=minOf(2048L,84000-frame).toInt();assertEquals(count*8,stream.read(44+frame*8,bytes,0,count*8))
    val out=java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
    repeat(count) {f->val t=frame+f
     val u=(t-24000).toDouble()/36000
     val outgoing=if(t<24000)1.0 else kotlin.math.cos(u*Math.PI/2)
     val incoming=if(t>=60000)1.0 else kotlin.math.sin(u*Math.PI/2)
     repeat(2) {ch->
      var expected=0.0
      if(t<60000)expected+=decoded.getFloat(((12000+t)*2+ch).toInt()*4)*outgoing
      if(t>=24000)expected+=decoded.getFloat(((t-24000)*2+ch).toInt()*4)*incoming
      assertEquals(expected.toFloat(),out.float,.00008f);checked++
     }
    };frame+=count
   }
   // Exact envelope midpoint after a backwards seek, through the same native handle.
   assertEquals(8,stream.read(44+42000*8L,bytes,0,8))
   val seek=java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
   repeat(2) {ch->val expected=(decoded.getFloat((54000*2+ch)*4)+decoded.getFloat((18000*2+ch)*4))*kotlin.math.sqrt(.5f);assertEquals(expected,seek.float,.00008f)}
  }
  assertEquals(168000,checked)
 }
 @org.junit.Test fun referenceLinkedGeneratedImpulsesReachSameJniMappingAndEnvelope() {
  val fixture=java.nio.file.Files.createTempDirectory(java.io.File(System.getenv("TMPDIR")).toPath(),"phase-clicks-").toFile()
  for(name in listOf("clicks.opus","clicks.decoded"))File(fixture,name).writeBytes(javaClass.getResource("/waveform/$name")!!.readBytes())
  try {
  val (g,s,unlinked)=setup()
  val phase=PhaseEdit(unlinked.revision,unlinked.clips[0],unlinked.clips[1],
    PhaseGrid("manual:7:2000","local-a",500,500,0),PhaseGrid("manual:7:2000","local-b",500,250,250),1,430)
  assertTrue(g.timeline.preview(phase).accepted);assertTrue(g.timeline.commit(phase){true})
  val before=g.timeline.state.value.document
  assertEquals(500L,before.clips[1].globalStartMs);assertEquals(1L,before.phaseLink!!.relativeSteps)
  val edit=TimelineFadeEdit(before.revision,before.clips[0],before.clips[1],750)
  assertTrue(g.timeline.preview(edit).accepted);assertSame(before,g.timeline.state.value.document)
  assertTrue(g.timeline.commit(edit){true})
  val d=g.timeline.state.value.document
  assertEquals(0,apply(s,d).resultCode)
  assertEquals(d,s.acceptedArrangement!!.document)
  assertNotNull(s.acceptedArrangement!!.document.phaseLink)
  val plan=s.mixGrants.values.single().plan
  assertEquals(750L,plan.clips[0].fadeOut);assertEquals(750L,plan.clips[1].fadeIn)
  assertEquals(500L,plan.clips[0].end-plan.clips[0].fadeOut)
  assertEquals(1250L,plan.clips[1].start+plan.clips[1].fadeIn)
  val decoded=java.nio.ByteBuffer.wrap(File(fixture,"clicks.decoded").readBytes()).order(java.nio.ByteOrder.LITTLE_ENDIAN)
  var checked=0
  NativeMixStream(plan,mapOf(7L to File(fixture,"clicks.opus").absolutePath)).use {stream ->
   val bytes=ByteArray(2048*8);var frame=0L
   while(frame<84000) {
    val count=minOf(2048L,84000-frame).toInt();assertEquals(count*8,stream.read(44+frame*8,bytes,0,count*8))
    val out=java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
    repeat(count) {f->val t=frame+f
     val u=(t-24000).toDouble()/36000
     val outgoing=if(t<24000)1.0 else kotlin.math.cos(u*Math.PI/2)
     val incoming=if(t>=60000)1.0 else kotlin.math.sin(u*Math.PI/2)
     repeat(2) {ch->
      var expected=0.0
      if(t<60000)expected+=decoded.getFloat(((12000+t)*2+ch).toInt()*4)*outgoing
      if(t>=24000)expected+=decoded.getFloat(((t-24000)*2+ch).toInt()*4)*incoming
      assertEquals(expected.toFloat(),out.float,.00008f);checked++
     }
    };frame+=count
   }
   // Exact envelope midpoint after a backwards seek, through the same native handle.
   assertEquals(8,stream.read(44+42000*8L,bytes,0,8))
   val seek=java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
   repeat(2) {ch->val expected=(decoded.getFloat((54000*2+ch)*4)+decoded.getFloat((18000*2+ch)*4))*kotlin.math.sqrt(.5f);assertEquals(expected,seek.float,.00008f)}
  }
  assertEquals(168000,checked)
  } finally {fixture.deleteRecursively()}
 }
}
'''
source=prelude+('}\n'+compat+'class Unused {\n' if compat else '')+helpers+'\nfun playerCommand(playerCommand:Int):Int {val controller=Any();'+request+'}\n'+'''
 fun command(args:Bundle):SessionResult {val customCommand=Command(APPLY_ARRANGEMENT)
'''+command+'''
 return SessionResult(SessionError.ERROR_BAD_VALUE)
 }
 fun ready(){onPlaybackStateChanged(player.playbackState)}
'''+ready_callback+'''
}
'''+fixture
if compat:
    # baseline still executes the actual absent-command fallback in the same
    # service-shaped facade, with no fabricated production acceptance.
    source=prelude+'''fun command(args:Bundle)=SessionResult(SessionError.ERROR_BAD_VALUE);fun ready(){}\n}\n'''+compat+fixture
# MixGrant is internal, so ordinary JVM test compilation uses the real class.
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'ArrangementServiceExtractedTest.kt').write_text(source)
