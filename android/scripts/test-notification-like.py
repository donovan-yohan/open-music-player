#!/usr/bin/env python3
"""Actual service custom command/current-offer bodies, real repository/API/TLS.
Only Android player/session presentation is a facade; no mutation logic is copied.
"""
import argparse, ast, hashlib, json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
s=(root/'app/src/main/kotlin/com/soundq/android/playback/SoundQLibraryService.kt').read_text()
def block(text,marker):
 start=text.index(marker);o=text.index('{',start);d=1;i=o+1
 while d:
  d+=(text[i]=='{')-(text[i]=='}');i+=1
 return text[start:i]
tree=ast.parse((root/'scripts/test-mix-selection.py').read_text())
prelude=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='prelude' for t in n.targets))
prelude=prelude.replace('package com.soundq.android.mixselection','package com.soundq.android.notificationlike')
prelude=prelude.replace('private typealias Player=androidx.media3.common.Player','private object Player {const val COMMAND_PREPARE=99;const val COMMAND_CHANGE_MEDIA_ITEMS=1;const val COMMAND_PLAY_PAUSE=2;const val COMMAND_STOP=3;const val COMMAND_SEEK_TO_DEFAULT_POSITION=4;const val COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM=5;const val COMMAND_SEEK_TO_MEDIA_ITEM=6;const val COMMAND_SEEK_TO_NEXT=7;const val COMMAND_SEEK_TO_PREVIOUS=8;const val COMMAND_SEEK_TO_NEXT_MEDIA_ITEM=9;const val COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM=10;const val COMMAND_SEEK_BACK=11;const val COMMAND_SEEK_FORWARD=12;const val COMMAND_GET_TIMELINE=13;const val COMMAND_GET_CURRENT_MEDIA_ITEM=14;const val COMMAND_GET_METADATA=15}')
prelude=prelude.replace('private class PlayerFacade: PinnedCommandQueue.PlayerWrapper','private class PlayerFacade')
prelude=prelude.replace('override fun seek','fun seek')
prelude=prelude.replace('private class MediaSession {class ControllerInfo;var extras=Bundle.EMPTY;fun setSessionExtras(b:Bundle){extras=b}}','private class MediaSession {class ControllerInfo(val own:Boolean=true,val allowed:Boolean=true);var buttons=listOf<CommandButton>();fun setMediaButtonPreferences(v:List<CommandButton>){buttons=v};val connectedControllers=emptyList<ControllerInfo>();fun setAvailableCommands(c:ControllerInfo,s:Any,p:Any){}}')
prelude=prelude.replace('val jamAdmission=JamPort();fun rememberTracks','val library=LibraryRepository(session,api::library,api::like);val jamAdmission=JamPort();fun rememberTracks')
prelude=prelude.replace('fun own(c:MediaSession.ControllerInfo)=true','fun own(c:MediaSession.ControllerInfo)=c.own').replace('fun admitted(c:MediaSession.ControllerInfo)=true','fun admitted(c:MediaSession.ControllerInfo)=c.allowed')
prelude=prelude.replace(' fun publishSessionExtras(){}',' fun publishSessionExtras(){}\n val session=MediaSession();fun sessionCommands(c:MediaSession.ControllerInfo)=Any();fun commands(a:Boolean,c:MediaSession.ControllerInfo)=Any()')
prelude=prelude.replace('private const val LIKE="soundq.library.like."','')
prelude=prelude.replace('private class JamPort {','private class JamPort {fun detachOwner(){};')
prelude=prelude.replace('private class PlayerFacade {','private open class PlayerFacade {fun release(){};')
prelude=prelude.replace('import java.util.concurrent.*','import java.util.concurrent.*\nimport java.util.UUID')
prelude=prelude.replace('import com.soundq.android.playback.AcceptedArrangement','import com.soundq.android.playback.AcceptedArrangement\nimport com.soundq.android.playback.PlaybackRef\nimport com.soundq.android.playback.PerformanceCommands')

prelude=prelude.replace('import com.soundq.android.playback.AcceptedArrangement','import com.soundq.android.data.timeline.projectTempoDocument\nimport com.soundq.android.playback.nativeArrangementPayload\nimport com.soundq.android.playback.AcceptedArrangement')
prelude+='''
 private const val LIKE="soundq.library.like."
 private class CommandButton(val sessionCommand:SessionCommand,val enabled:Boolean,val label:String) {
  class Builder(val icon:Int) {var command=SessionCommand("",Bundle.EMPTY);var enabled=true;var label="";fun setSessionCommand(v:SessionCommand)=apply{command=v};fun setDisplayName(v:String)=apply{label=v};fun setEnabled(v:Boolean)=apply{enabled=v};fun setSlots(vararg v:Int)=this;fun build()=CommandButton(command,enabled,label)}
  companion object {const val ICON_HEART_FILLED=1;const val ICON_HEART_UNFILLED=2;const val SLOT_OVERFLOW=6}
 }
'''
native_types={
 'com.soundq.android.playback.nativeengine.NativeCallbackPlayer':'NativeCallbackPlayerBoundary',
 'com.soundq.android.playback.nativeengine.NativeCallbackArrangement':'NativeCallbackArrangementBoundary',
}
prelude+='''
// Declaration-only native collaborator: Like never constructs or enters this owner.
// Keep the full production branch type-checkable with this probe's MediaItem type.
private class NativeCallbackArrangementBoundary
private class NativeCallbackPlayerBoundary:PlayerFacade() {
 suspend fun retirePhoneFile(ref:com.soundq.android.playback.PlaybackRef.Device):Boolean=error("Original mutation outside Like fixture")
 suspend fun prepareArrangement(document:TimelineDocument,sourceItems:List<MediaItem>,current:()->Boolean):NativeCallbackArrangementBoundary=error("Native arrangement outside Like fixture")
 fun installArrangement(candidate:NativeCallbackArrangementBoundary,item:MediaItem,sourceItems:List<MediaItem>):Unit=error("Native arrangement outside Like fixture")
 suspend fun discardArrangement(candidate:NativeCallbackArrangementBoundary):Unit=error("Native arrangement outside Like fixture")
 fun bindPerformance(identity:ArrangementIdentity):Unit=error("Native performance outside Like fixture")
 fun revokePerformance():Unit=error("Native performance outside Like fixture")
 suspend fun sourceReturn(identity:ArrangementIdentity,current:()->Boolean):Pair<String,Long>?=error("Native source return outside Like fixture")
}
'''
# Last opening brace in inherited prelude belongs to ExtractedService. Add all
# production notification methods/fields there, keeping their bodies untouched.
prelude=prelude.replace(' private const val LIKE=', '}\n private const val LIKE=',1)
prelude+='\nprivate object Dispatchers {var IO:CoroutineDispatcher=kotlinx.coroutines.Dispatchers.IO}\nprivate open class ServiceBoundary {open fun onDestroy(){}}\nprivate class CloseBoundary {fun close(){}}\n'
prelude+='\nprivate class LikeService(val graph:Graph,val player:PlayerFacade,val jobs:CoroutineScope):ServiceBoundary() {\n fun renewPhoneGrants(){};fun localAccess()=false;var undoVersion=-1L;fun resolveDevice(item:MediaItem):MediaItem=error("Phone source separately tested");fun grantFor(item:MediaItem,scope:AccountScope?)=MediaGrant(requireNotNull(scope),TrackId(item.mediaMetadata.extras!!.getLong("trackId")),item.mediaMetadata.extras!!.getBoolean("localOnly"));\n var session:MediaSession?=MediaSession();val recorder=CloseBoundary();val artwork=CloseBoundary();var account=graph.session.capture();val interruptions=Interruptions();val transport=TransportFacade(player);val grants=ConcurrentHashMap<String,MediaGrant>();val mixGrants=ConcurrentHashMap<String,com.soundq.android.playback.mix.MixGrant>();var selectionEpoch=0L;val mixLoads=AtomicInteger();var undo:List<MediaItem>?=null;var undoScope:AccountScope?=null;var undoIndex=0;var undoPosition=0L;var saveJob:Job?=null\n fun supportsSourceActions()=true;fun own(c:MediaSession.ControllerInfo)=c.own;fun admitted(c:MediaSession.ControllerInfo)=c.allowed;fun publishSessionExtras(){};fun sessionCommands(c:MediaSession.ControllerInfo)=Any();fun commands(a:Boolean,c:MediaSession.ControllerInfo)=Any();fun resolve(v:List<MediaItem>):List<MediaItem> = error("unrelated Jam")\n'
prelude=prelude.replace('private class Interruptions {','private class Interruptions {fun close(){};')
prelude=prelude.replace('private class MediaSession {class ControllerInfo(val own:', 'private class MediaSession {fun release(){};class ControllerInfo(val own:')
prelude+=block(s,'    override fun onDestroy(')
prelude+='\n class WakeLockBoundary {val isHeld=false;fun release(){error("OS wake lock outside Like fixture")}}\n var playbackWakeLock:WakeLockBoundary?=null\n fun supportsMixActions()=false\n fun supportsArrangementActions()=false // Unrelated owner; refuse before arrangement preparation.\n'
# onDestroy is extracted unchanged. Continuation owns no Like work in this facade.
prelude+='\n val continuation=CloseBoundary()\n fun saveJamQueue():Unit=error("Jam persistence outside Like fixture")\n'
prelude+='''
 private val START_CONTEXT="soundq.context.start"
 fun startContext(args:Bundle):ListenableFuture<SessionResult> = error("Large context outside Like fixture")
 // Clock transport is outside the Like fixture and must fail closed if entered.
 val CLOCK_SEEK="soundq.clock.seek.v1"
 fun seekClock(args:Bundle):ListenableFuture<SessionResult> = error("Clock outside Like fixture")
 // Listening speed is outside the Like fixture and must fail closed if entered.
 val SONG_SPEED="soundq.song.speed.v1";val RETIRE_PHONE_FILE="soundq.phone.retire.v1"
 fun songSpeed(args:Bundle):ListenableFuture<SessionResult> = error("Selected song speed outside Like fixture")
 val SET_LISTENING_SPEED="soundq.listening.speed.v1"
 fun setListeningSpeed(args:Bundle):ListenableFuture<SessionResult> = error("Speed outside Like fixture")
 var pendingArrangement:Pair<AcceptedArrangement,Long>?=null
 var acceptedArrangement:AcceptedArrangement?=null
 var arrangementItems:List<MediaItem>?=null
 val serviceIncarnation="outside-arrangement"
 val sourceQueueIncarnation="outside-arrangement"
 fun sourceOccurrences():List<com.soundq.android.playback.QueueOccurrence> = error("Arrangement outside Like fixture")
 fun arrangementCurrent(accepted:AcceptedArrangement):Boolean=error("Arrangement outside Like fixture")
 fun retireArrangement():Unit=error("Arrangement outside Like fixture")
 // Unrelated performance/return owners are explicit refusals; never run their bodies.
 fun performanceCommand(controller:MediaSession.ControllerInfo,action:String,args:Bundle):ListenableFuture<SessionResult> = Futures.immediateFuture(SessionResult(SessionError.ERROR_NOT_SUPPORTED))
 fun future(body:suspend ()->SessionResult):ListenableFuture<SessionResult> = Futures.immediateFuture(SessionResult(SessionError.ERROR_NOT_SUPPORTED))
'''
markers=['    private fun currentLikeTarget(', '    private fun refreshLikeButton(', '    private fun likeCommand(']
if '    private fun currentLikeTarget(' in s:
 fields=s[s.index('    private data class LikeTarget'):s.index('    private fun currentLikeTarget(')]
 prelude+=fields+'\n'+'\n'.join(block(s,m).replace('private fun refreshLikeButton','fun refreshLikeButton') for m in markers)
else:
 prelude+='fun refreshLikeButton(){}\n'
command=block(s,'        override fun onCustomCommand(').replace('override fun','fun',1)
for production_type,boundary_type in native_types.items():
 command=command.replace(production_type,boundary_type)
prelude+='\n fun validateSelection(items:List<MediaItem>,index:Int,position:Long){}\n'+command
prelude+='\nfun action():SessionCommand {refreshLikeButton();return session!!.buttons.firstOrNull()?.sessionCommand ?: SessionCommand(LIKE+"fixture",Bundle.EMPTY)}\n}\n'
fixture='''
private class Store:SessionStore {override fun load(e:ApiEndpoint):SecretTokens?=null;override fun save(e:ApiEndpoint,t:SecretTokens){};override fun clear(){}}
private class Harness:AutoCloseable {
 val server=MockWebServer();val main=Executors.newSingleThreadExecutor().asCoroutineDispatcher();val jobs=CoroutineScope(SupervisorJob()+main);val player=PlayerFacade();val graph:Graph;val service:LikeService
 val writes=AtomicInteger();var liked=false;val entered=CountDownLatch(1);val release=CountDownLatch(1);var hold=false;var lost=false;var unknown=false
 var disjoint=false;var likedB=false;val heldRead=CountDownLatch(1);val releaseRead=CountDownLatch(1);val aReads=AtomicInteger();val methods=CopyOnWriteArrayList<String>()
 init {
  val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build();server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory())
  server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
   check(r.headers["Authorization"]=="Bearer synthetic-access")
   if(disjoint) {
    if(r.method!="GET") {
     val id=r.url.encodedPath.substringBefore("/like").substringAfterLast('/').toLong();check(id in listOf(7L,8L))
     methods.add("${r.method}:$id");writes.incrementAndGet();if(id==7L)liked=r.method=="POST" else likedB=r.method=="POST"
     return MockResponse.Builder().code(204).build()
    }
    val id=if(r.url.queryParameter("q")=="B")8L else 7L;val value=if(id==7L)liked else likedB
    if(id==7L&&aReads.incrementAndGet()==2){heldRead.countDown();check(releaseRead.await(8,TimeUnit.SECONDS))}
    return MockResponse.Builder().body("""{"tracks":[{"id":$id,"title":"track$id","is_liked":$value}],"total":1,"limit":20,"offset":0}""").build()
   }
   if(r.method!="GET"){check(r.url.encodedPath=="/api/v1/library/tracks/7/like");writes.incrementAndGet();liked=r.method=="POST";entered.countDown();if(hold)check(release.await(8,TimeUnit.SECONDS));return if(lost)MockResponse.Builder().body("""{"ack":true}""").setHeader("Content-Length","1000").onResponseBody(SocketEffect.CloseSocket()).build() else MockResponse.Builder().code(204).build()}
   check(r.url.encodedPath=="/api/v1/library");return MockResponse.Builder().body("""{"tracks":[{"id":7,"title":"Owned","is_liked":${if(unknown)"null" else liked}}],"total":1,"limit":20,"offset":0}""").build()
  }};server.start()
  val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build();val account=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),Store());check(account.accept(account.beginIntent(),SecretTokens("synthetic-access","synthetic-refresh","A")))
  graph=Graph(account,SoundQApi(account,OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()));graph.library.refine(LibraryQuery())
  service=LikeService(graph,player,jobs);player.setMediaItem(item("A",7));service.grants[player.currentMediaItem!!.localConfiguration!!.uri.toString()]=MediaGrant(account.capture()!!,TrackId(7),false)
 }
 fun item(id:String,track:Long,local:Boolean=false)=MediaItem.Builder().setMediaId(id).setUri(Uri.parse("soundq://track/$track/$id")).setMediaMetadata(MediaMetadata.Builder().setTitle(id).setExtras(Bundle().apply{putLong("trackId",track);putBoolean("localOnly",local)}).build()).build()
 fun <T> onMain(f:()->T):T=runBlocking {withContext(main){f()}}
 fun send(command:SessionCommand=onMain{service.action()},c:MediaSession.ControllerInfo=MediaSession.ControllerInfo())=onMain{service.onCustomCommand(service.session!!,c,command,Bundle.EMPTY)}
 override fun close(){releaseRead.countDown();release.countDown();runBlocking{jobs.coroutineContext[Job]!!.cancelAndJoin()};main.close();server.close()}
}
class NotificationLikeServiceTest {
 @Test fun cancelledLaunchReleasesClaimAndCompletesFuture() {cancelledService("launch")}
 @Test fun cancelledIoEntryReleasesClaimAndCompletesFuture() {cancelledService("io")}
 private fun cancelledService(stage:String) {
  for(caller in listOf("row","system")) Harness().use {h ->
   val queued=LinkedBlockingQueue<Runnable>()
   val oldIo=Dispatchers.IO
   val heldIo=object:CoroutineDispatcher(){override fun dispatch(context:kotlin.coroutines.CoroutineContext,block:Runnable){queued.add(block)}}
   val oldScope=h.graph.session.capture()!!
   val item=h.player.currentMediaItem!!
   var replacementJobs:CoroutineScope?=null
   try {
    Dispatchers.IO=heldIo
    val command=h.onMain{h.service.action()}
    if(stage=="launch")h.jobs.cancel()
    val f=h.send(command)
    if(stage=="io") {
     val worker=queued.poll(3,TimeUnit.SECONDS)
     assertNotNull("Like must be queued before IO entry",worker)
     h.onMain{h.service.onDestroy()}
     worker!!.run()
    } else h.onMain{h.service.onDestroy()}
    runBlocking{withTimeout(3000){h.jobs.coroutineContext[Job]!!.join()}}
    assertTrue(h.graph.session.remoteCurrent(oldScope));assertEquals(0,h.writes.get())
    assertNotNull("Never-entered Like must restore same-account row admission ($stage/$caller)",h.graph.library.offerLike(oldScope,TrackId(7)))
    assertTrue("Controller future must settle even if launch never starts",f.isDone)
    assertEquals(SessionError.ERROR_INVALID_STATE,f.get().resultCode)
    Dispatchers.IO=oldIo
    replacementJobs=CoroutineScope(SupervisorJob()+h.main)
    val replacement=LikeService(h.graph,h.player,replacementJobs)
    replacement.grants[item.localConfiguration!!.uri.toString()]=MediaGrant(oldScope,TrackId(7),false)
    val action=h.onMain{replacement.action()}
    assertEquals("Like",h.onMain{replacement.session!!.buttons.single().label})
    if(caller=="row")h.graph.library.like(h.graph.library.state.value.rows.single())
    else assertEquals(0,h.onMain{replacement.onCustomCommand(replacement.session!!,MediaSession.ControllerInfo(false,true),action,Bundle.EMPTY)}.get(5,TimeUnit.SECONDS).resultCode)
    assertEquals(1,h.writes.get());assertEquals(true,h.graph.library.likeView(oldScope,TrackId(7))!!.track.liked)
   } finally {Dispatchers.IO=oldIo;while(true){val r=queued.poll() ?: break;r.run()};replacementJobs?.cancel()}
  }
 }
 @Test fun serviceCancellationAfterWriteEntryKeepsUncertainOwnerAndNeverReplays() {Harness().use {h ->
  h.hold=true;h.lost=true;val f=h.send();assertTrue(h.entered.await(3,TimeUnit.SECONDS))
  val scope=h.graph.session.capture()!!;h.onMain{h.service.onDestroy()}
  assertNull("Entered write keeps its lock",h.graph.library.offerLike(scope,TrackId(7)))
  h.graph.library.like(h.graph.library.state.value.rows.single());assertEquals(1,h.writes.get())
  h.release.countDown();assertEquals(SessionError.ERROR_INVALID_STATE,f.get(5,TimeUnit.SECONDS).resultCode)
  assertEquals(MutationOutcome.Uncertain,h.graph.library.likeView(scope,TrackId(7))!!.outcome)
  assertNull(h.graph.library.offerLike(scope,TrackId(7)));assertEquals(1,h.writes.get())
 }}
 @Test fun disjointRowSettlementKeepsNotificationUnlikeAndNextDelete() {Harness().use {h ->
  h.disjoint=true;h.graph.library.refine(LibraryQuery(text="A"))
  val first=h.send();assertTrue(h.heldRead.await(3,TimeUnit.SECONDS));assertFalse(first.isDone)
  h.graph.library.refine(LibraryQuery(text="B"));h.graph.library.like(h.graph.library.state.value.rows.single());val b=h.graph.library.state.value
  assertEquals(listOf("POST:7","POST:8"),h.methods.toList())
  h.releaseRead.countDown();assertEquals(0,first.get(5,TimeUnit.SECONDS).resultCode)
  assertSame(b,h.graph.library.state.value)
  val next=h.onMain{h.service.action()};assertEquals("Unlike",h.service.session!!.buttons.single().label)
  assertEquals(0,h.send(next).get(5,TimeUnit.SECONDS).resultCode)
  assertEquals(listOf("POST:7","POST:8","DELETE:7"),h.methods.toList())
 }}
 @Test fun offPageCurrentSongReadsOwnedLibraryWithoutChangingVisibleFilter() {Harness().use {h ->
  h.graph.library.retire();val before=h.graph.library.state.value.query
  h.onMain{h.service.refreshLikeButton()}
  val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
  while(h.graph.library.likeView(h.graph.session.capture()!!,TrackId(7))==null&&System.nanoTime()<deadline)Thread.yield()
  assertNotNull("Current owned song needs an acknowledged read",h.graph.library.likeView(h.graph.session.capture()!!,TrackId(7)))
  assertEquals(before,h.graph.library.state.value.query);assertEquals(0,h.writes.get());assertEquals("Like",h.onMain{h.service.action();h.service.session.buttons.single().label})
 }}
 @Test fun staleOfferAfterNextOrSameIdReplacementNeverTargetsReplacement() {for(same in listOf(false,true))Harness().use {h ->
  val old=h.onMain{h.service.action()}
  h.onMain {h.player.setMediaItem(h.item(if(same)"A" else "B",if(same)7 else 8));h.service.refreshLikeButton()}
  assertEquals(SessionError.ERROR_INVALID_STATE,h.send(old).get(3,TimeUnit.SECONDS).resultCode);assertEquals(0,h.writes.get())
 }}
 @Test fun enteredLikeSurvivesNextAndLibraryRetapsShareItsLock() {Harness().use {h ->
  h.hold=true;val command=h.onMain{h.service.action()};val row=h.graph.library.state.value.rows.single();val f=h.send(command)
  assertTrue(h.entered.await(3,TimeUnit.SECONDS));assertFalse(f.isDone);assertEquals(false,h.graph.library.state.value.rows.single().liked)
  h.graph.library.like(row);assertEquals(1,h.writes.get());assertEquals(SessionError.ERROR_INVALID_STATE,h.send(command).get().resultCode)
  h.onMain {h.player.setMediaItem(h.item("B",8));h.service.refreshLikeButton();assertTrue(h.service.session.buttons.isEmpty())}
  h.release.countDown();assertEquals(0,f.get(5,TimeUnit.SECONDS).resultCode)
  h.onMain {assertEquals("B",h.player.currentMediaItem!!.mediaId);assertTrue(h.service.session.buttons.isEmpty())}
  assertEquals(true,h.graph.library.state.value.rows.single().liked);assertEquals(1,h.writes.get())
 }}
 @Test fun accountReplacementAndLocalLockRefuseRetainedOfferBeforeDispatch() {for(lock in listOf(false,true))Harness().use {h ->
  val old=h.onMain{h.service.action()};if(lock)h.graph.session.lockLocal() else h.graph.session.accept(h.graph.session.beginIntent(),SecretTokens("new","new-r","B"))
  assertEquals(SessionError.ERROR_INVALID_STATE,h.send(old).get().resultCode);assertEquals(0,h.writes.get());h.onMain{assertTrue(h.service.session.buttons.isEmpty())}
 }}
 @Test fun heldReplyCannotPublishIntoReplacementAccountOrLockedScope() {for(lock in listOf(false,true))Harness().use {h ->
  h.hold=true;val f=h.send();assertTrue(h.entered.await(3,TimeUnit.SECONDS))
  if(lock)h.graph.session.lockLocal() else {h.graph.session.accept(h.graph.session.beginIntent(),SecretTokens("synthetic-access","new-r","B"));h.graph.library.retire();h.graph.library.refine(LibraryQuery())}
  val accepted=h.graph.library.state.value;h.release.countDown();f.get(5,TimeUnit.SECONDS)
  assertSame(accepted,h.graph.library.state.value);h.onMain{h.service.refreshLikeButton();assertTrue(h.service.session.buttons.isEmpty())};assertEquals(1,h.writes.get())
 }}
 @Test fun unknownLocalOnlyMixAndUntrustedControllerMakeZeroWrites() {for(kind in listOf("unknown","local","mix","foreign"))Harness().use {h ->
  val old=h.onMain{h.service.action()}
  when(kind) {
   "unknown"->{h.unknown=true;h.graph.library.refine(LibraryQuery())}
   "local"->h.onMain{h.player.setMediaItem(h.item("local",7,true))}
   "mix"->h.onMain{h.player.setMediaItem(MediaItem.Builder().setMediaId("mix").setUri(Uri.parse("soundqmix://fixture")).build())}
  }
  val c=MediaSession.ControllerInfo(own=false,allowed=kind!="foreign")
  assertTrue(h.send(old,c).get().resultCode!=0);assertEquals(0,h.writes.get())
 }}
 @Test fun trustedSystemControllerCanUseOnlyCapturedLikeAction() {Harness().use {h ->
  assertEquals(0,h.send(c=MediaSession.ControllerInfo(false,true)).get(5,TimeUnit.SECONDS).resultCode);assertEquals(1,h.writes.get())
  assertEquals(SessionError.ERROR_PERMISSION_DENIED,h.send(SessionCommand(PLAY_MIX,Bundle.EMPTY),MediaSession.ControllerInfo(false,true)).get().resultCode)
 }}
 @Test fun lostReplySendsOnceAndRequiresExplicitGetOnlyReconciliation() {Harness().use {h ->
  h.lost=true;val old=h.onMain{h.service.action()};assertEquals(SessionError.ERROR_INVALID_STATE,h.send(old).get(5,TimeUnit.SECONDS).resultCode)
  assertEquals(1,h.writes.get());assertEquals(MutationOutcome.Uncertain,h.graph.library.state.value.mutations[TrackId(7)])
  h.graph.library.like(h.graph.library.state.value.rows.single());assertEquals(1,h.writes.get());assertTrue(h.send(old).get().resultCode!=0)
  val reload=h.onMain{h.service.action()};assertEquals("Reload Like status",h.service.session.buttons.single().label)
  assertEquals(0,h.send(reload).get(5,TimeUnit.SECONDS).resultCode);assertEquals(1,h.writes.get())
  assertEquals("Unlike",h.onMain{h.service.action();h.service.session.buttons.single().label})
 }}

 @Test fun actualCustomCommandUsesTlsThenSharedAcknowledgedLibraryAndUnlike() {Harness().use {h ->
  val epoch=h.service.selectionEpoch;val before=h.player.items;val pauses=h.player.pauses;val plays=h.player.plays
  assertEquals("Actual service Like callback must succeed",0,h.send().get(5,TimeUnit.SECONDS).resultCode)
  assertEquals(1,h.writes.get());assertEquals(true,h.graph.library.state.value.rows.single().liked)
  val unlike=h.onMain{h.service.action()};assertEquals("Unlike",h.service.session.buttons.single().label)
  assertEquals(0,h.send(unlike).get(5,TimeUnit.SECONDS).resultCode);assertEquals(2,h.writes.get());assertEquals(false,h.graph.library.state.value.rows.single().liked)
  assertEquals(epoch,h.service.selectionEpoch);assertEquals(before,h.player.items);assertEquals(pauses,h.player.pauses);assertEquals(plays,h.player.plays)
 }}
}
'''
fixture=fixture.replace('h.service.session','h.service.session!!')
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'NotificationLikeServiceTest.kt').write_text(prelude+fixture)
(a.generate/'extraction.json').write_text(json.dumps({'serviceSha256':hashlib.sha256(s.encode()).hexdigest(),'bodyTransformations':['remove override modifier','rebind native collaborator type names only; no statement edits'],'nativeTypeFacades':native_types,'facades':['Android player, Bundle, Uri, session presentation, out-of-scope native arrangement/performance/source-return declarations and refusal-only command/future boundaries']},indent=2)+'\n')
