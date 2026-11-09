#!/usr/bin/env python3
"""Source-bound queue save/startup/resumption regression; Android boundaries only.

Actual snapshot/parser, account capabilities, coroutine save/read and transport
read bodies execute on JVM. Facades stand in for Android player/Bundle/AtomicFile;
this is not decoder, process-death or native runtime qualification.
"""
import argparse, hashlib, json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);a=p.parse_args()
base=Path(__file__).resolve().parents[1]/'app/src/main/kotlin/com/soundq/android'
service=(base/'playback/SoundQLibraryService.kt').read_text()
def block(text,marker):
 s=text.index(marker);i=text.index('{',s)+1;depth=1
 while depth:
  depth+=(text[i]=='{')-(text[i]=='}');i+=1
 return text[s:i]
markers=['    private fun queueFile(','    private fun queueObservation(','    private fun writeQueueObservation(','    private fun saveJamQueue(','    private fun scheduleSave(','    private fun restoreQueue(','    private suspend fun readSavedQueue(','    private fun savedItems(','    private fun <T> future(']
markers+=['    private fun scheduleGuestSave(','    private fun restoreGuestQueue(']
if '    private fun restoreModes(' in service:markers.append('    private fun restoreModes(')
if '    private fun savedCompatible(' in service:markers.append('    private fun savedCompatible(')
methods='\n'.join(block(service,m) for m in markers).replace('com.soundq.android.playback.listening.ListeningServicePlayer','ListeningServicePlayer')
methods+='\n'+next(line for line in service.splitlines() if 'private fun guestFile()' in line)
resume=block(service,'        override fun onPlaybackResumption(').replace('override fun','fun',1)
repeat=block(service,'            override fun onRepeatModeChanged(').replace('override fun','fun',1)
shuffle=block(service,'            override fun onShuffleModeEnabledChanged(').replace('override fun','fun',1)
transport=(base/'playback/system/ServiceTransportPlayer.kt').read_text()
transport_body=transport[transport.index('internal class ServiceTransportPlayer'):]
prelude='''package com.soundq.android.queuepersistenceprobe
import com.soundq.android.data.*
import com.soundq.android.playback.*
import com.soundq.android.data.timeline.*
import com.google.common.util.concurrent.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Test
import org.junit.Assert.*
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicLong

private class Bundle {val b=mutableMapOf<String,Any>();fun putLong(k:String,v:Long){b[k]=v};fun getLong(k:String)=b[k] as? Long ?: 0L;fun putString(k:String,v:String){b[k]=v};fun getString(k:String)=b[k] as? String;fun putBoolean(k:String,v:Boolean){b[k]=v};fun getBoolean(k:String)=b[k] as? Boolean ?: false}
private class Uri(val raw:String){val scheme get()=raw.substringBefore(':');override fun toString()=raw;companion object {fun parse(v:String)=Uri(v)}}
private class MediaMetadata {var title:CharSequence?=null;var artist:CharSequence?=null;var extras:Bundle?=null
 class Builder {val m=MediaMetadata();fun setTitle(v:CharSequence?)=apply{m.title=v};fun setArtist(v:CharSequence?)=apply{m.artist=v};fun setIsPlayable(v:Boolean)=this;fun setIsBrowsable(v:Boolean)=this;fun setExtras(v:Bundle)=apply{m.extras=v};fun build()=m}}
private class MediaItem {class LocalConfiguration(val uri:Uri);var mediaId="";var localConfiguration:LocalConfiguration?=null;var mediaMetadata=MediaMetadata()
 class Builder {val m=MediaItem();fun setMediaId(v:String)=apply{m.mediaId=v};fun setUri(v:Uri)=apply{m.localConfiguration=LocalConfiguration(v)};fun setMediaMetadata(v:MediaMetadata)=apply{m.mediaMetadata=v};fun build()=m}}
private class ListeningServicePlayer:Player() {fun validateMetadata(sources:List<TimelineSource>,index:Int,position:Long){error("Bounded adapter covered by real ServiceAdmissionTest")}}
private open class Player {
 companion object {const val REPEAT_MODE_OFF=0;const val REPEAT_MODE_ONE=1;const val REPEAT_MODE_ALL=2}
 var items=listOf<MediaItem>();var currentMediaItemIndex=0;var currentPosition=0L;var prepares=0;var plays=0;var playing=false;var failInstall=false
 // Traversal policy executes with real ServiceQueuePlayer in ShuffleRestoreCompositionTest.
 fun <T> restoringShuffle(enabled:Boolean,action:()->T):T=action()
 var repeatChanged:()->Unit={};var shuffleChanged:()->Unit={};var timelineChanged:()->Unit={}
 var shuffleModeEnabled=false;set(v){if(field!=v){field=v;shuffleChanged()}}
 var repeatMode=REPEAT_MODE_OFF;set(v){if(field!=v){field=v;repeatChanged()}}
 val mediaItemCount get()=items.size;fun getMediaItemAt(i:Int)=items[i]
 open fun setMediaItems(v:List<MediaItem>,index:Int,position:Long){check(!failInstall);items=v;currentMediaItemIndex=index;currentPosition=position;timelineChanged()}
 open fun setMediaItems(v:List<MediaItem>,reset:Boolean)=setMediaItems(v,0,0)
 open fun setMediaItems(v:List<MediaItem>)=setMediaItems(v,true)
 open fun setMediaItem(v:MediaItem)=setMediaItems(listOf(v))
 open fun setMediaItem(v:MediaItem,position:Long)=setMediaItems(listOf(v),0,position)
 open fun setMediaItem(v:MediaItem,reset:Boolean)=setMediaItems(listOf(v),reset)
 open fun addMediaItem(v:MediaItem)=addMediaItems(listOf(v))
 open fun addMediaItem(index:Int,v:MediaItem)=addMediaItems(index,listOf(v))
 open fun addMediaItems(v:List<MediaItem>)=addMediaItems(items.size,v)
 open fun addMediaItems(index:Int,v:List<MediaItem>){items=items.toMutableList().apply{addAll(index,v)}}
 open fun prepare(){prepares++};open fun play(){plays++;playing=true};open fun pause(){playing=false};open fun stop(){playing=false};open fun clearMediaItems(){items=emptyList();timelineChanged()}
 open fun setPlayWhenReady(v:Boolean){if(v)play() else pause()}
}
private open class ForwardingPlayer(val wrapped:Player):Player() {
 override fun setMediaItems(v:List<MediaItem>)=wrapped.setMediaItems(v)
 override fun setMediaItem(v:MediaItem)=wrapped.setMediaItem(v)
 override fun setMediaItem(v:MediaItem,position:Long)=wrapped.setMediaItem(v,position)
 override fun setMediaItem(v:MediaItem,reset:Boolean)=wrapped.setMediaItem(v,reset)
 override fun addMediaItem(v:MediaItem)=wrapped.addMediaItem(v)
 override fun addMediaItem(index:Int,v:MediaItem)=wrapped.addMediaItem(index,v)
 override fun addMediaItems(v:List<MediaItem>)=wrapped.addMediaItems(v)
 override fun addMediaItems(index:Int,v:List<MediaItem>)=wrapped.addMediaItems(index,v)
 override fun setMediaItems(v:List<MediaItem>,index:Int,position:Long)=wrapped.setMediaItems(v,index,position)
 override fun setMediaItems(v:List<MediaItem>,reset:Boolean)=wrapped.setMediaItems(v,reset)
 override fun prepare()=wrapped.prepare();override fun play()=wrapped.play();override fun pause()=wrapped.pause();override fun stop()=wrapped.stop();override fun clearMediaItems()=wrapped.clearMediaItems()
}
private class MediaSession {class ControllerInfo;class MediaItemsWithStartPosition(val mediaItems:List<MediaItem>,val startIndex:Int,val startPositionMs:Long)}
private object C {const val INDEX_UNSET=-1;const val TIME_UNSET=-9223372036854775807L}
// A deterministic IO-admission gate, not a replacement read or parser.
private object Dispatchers {
 val IO=GateDispatcher()
 class GateDispatcher:CoroutineDispatcher() {
  var entered=CountDownLatch(1);@Volatile var hold=false;set(v){if(v)entered=CountDownLatch(1);field=v};val pending=ConcurrentLinkedQueue<Pair<kotlin.coroutines.CoroutineContext,Runnable>>()
  override fun dispatch(c:kotlin.coroutines.CoroutineContext,r:Runnable){if(hold){pending.add(c to r);entered.countDown()}else kotlinx.coroutines.Dispatchers.IO.dispatch(c,r)}
  fun release(){hold=false;while(true){val p=pending.poll() ?: return;kotlinx.coroutines.Dispatchers.IO.dispatch(p.first,p.second)}}
 }
}
private class Graph(val session:AccountSession,val directory:java.io.File){val endpoint=session.endpoint;val phoneAudio=PhoneBoundary()}
private class PhoneBoundary {val authorityVersion=0L}
private class Continuation {fun repeatChanged(){};fun shuffleChanged(){}}
'''
fixture='''
private class ExtractedService(val graph:Graph,val jobs:CoroutineScope) {
 var clockRevision=0L;var guestRestoredVersion=-1L;var guestRejectedQueue=false
 fun localAccess()=account==null

 fun guestStart(){restoreGuestQueue()};fun guestFileBytes()=guestFile()
 val player=Player();var account=graph.session.capture();val transport=ServiceTransportPlayer(player){account?.let(graph.session::current)==true}
 val grants=ConcurrentHashMap<String,MediaGrant>();var selectionEpoch=0L;var saveJob:Job?=null;var restoring=false;var rejectedQueue=false
 private val queueFileLock=Any();@Volatile private var queueSaveEpoch=0L
 val continuation=Continuation()
 fun admitted(c:MediaSession.ControllerInfo)=true
 fun bind(){player.repeatChanged={onRepeatModeChanged(player.repeatMode)};player.shuffleChanged={onShuffleModeEnabledChanged(player.shuffleModeEnabled)};player.timelineChanged={scheduleSave()}}
 fun start(){restoreQueue(account!!)}
 fun save(){scheduleSave()}
 fun acknowledgeJam(){saveJamQueue()}
 fun file()=queueFile(account!!)
 fun mount(saved:QueueSnapshot){player.setMediaItems(savedItems(account!!,saved),saved.selected,saved.position)}
 METHODS
 RESUME
 REPEAT
 SHUFFLE
}
private class Store:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
private class Harness:AutoCloseable {
 val directory=java.nio.file.Files.createTempDirectory(java.nio.file.Path.of(System.getenv("TMPDIR")),"queue-modes-").toFile()
 val main=Executors.newSingleThreadExecutor().asCoroutineDispatcher();val jobs=CoroutineScope(SupervisorJob()+main)
 val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
 val service:ExtractedService
 init {check(session.accept(session.beginIntent(),SecretTokens("synthetic-access","synthetic-refresh","A")));service=ExtractedService(Graph(session,directory),jobs);onMain{service.bind()}}
 fun <T> onMain(b:()->T):T=runBlocking{withContext(main){b()}}
 fun seed(shuffle:Boolean=true,repeat:String="all"):String {
 val rows=listOf(SavedOccurrence("occ-context",7,"Context","Fixture",false,false,6000,QueueOrigin.Context),SavedOccurrence("occ-manual",7,"Manual","Fixture",true,true,7000,QueueOrigin.Manual),SavedOccurrence("occ-continuation",8,"Continuation","Fixture",false,false,8000,QueueOrigin.Continuation))
 val legacy=QueueSnapshot(session.endpoint.identity,"A",rows,1,2300).encode()
 val raw=buildJsonObject {Json.parseToJsonElement(legacy).jsonObject.forEach{(k,v)->put(k,v)};put("shuffleEnabled",shuffle);put("loopMode",repeat)}.toString()
 onMain{service.file().writeText(raw)};return raw
 }
 fun settled(){runBlocking{withTimeout(5000){while(jobs.coroutineContext[Job]!!.children.any{it.isActive})delay(5)}}}
 override fun close(){Dispatchers.IO.release();runBlocking{jobs.coroutineContext[Job]!!.cancelAndJoin()};main.close();directory.deleteRecursively()}
}
class QueueModePersistenceExtractedTest {
 @Test fun failedGuestRestoreCannotPoisonAccountSaveOrJamAndPreservesGuestBytes(){Harness().use {h->
 val ref=PlaybackRef.Device("12345678-1234-1234-1234-123456789013","a".repeat(64),100,1)
 val guest=QueueSnapshot(h.session.endpoint.identity,"guest",listOf(SavedOccurrence("phone",0,"Phone","Artist",true,true,601000,ref=ref)),0,42000)
 val file=h.service.guestFileBytes();QueueSnapshotStore(file).write(guest);val bytes=file.readBytes()
 h.onMain{h.service.account=null;h.service.player.failInstall=true;h.service.guestStart()};h.settled();h.onMain{h.service.player.failInstall=false}
 h.onMain{h.service.save()};h.settled();assertArrayEquals(bytes,file.readBytes())
 h.onMain{h.service.account=h.session.capture()};h.seed();h.onMain{h.service.start()};h.settled()
 assertFalse(h.service.rejectedQueue)
 h.onMain{h.service.player.currentPosition=3210;h.service.save()};h.settled()
 assertEquals(3210L,QueueSnapshotStore(h.service.file()).read(h.session.endpoint.identity,"A")!!.position)
 h.onMain{h.service.acknowledgeJam()};assertArrayEquals(bytes,file.readBytes())
 // Successful acknowledged guest restoration on a fresh session releases only its own hold.
 h.onMain{h.service.account=null;h.service.player.clearMediaItems();h.service.saveJob?.cancel();h.session.retire();h.service.guestStart()};h.settled()
 h.onMain{h.service.player.currentPosition=1234;h.service.save()};h.settled()
 assertEquals(1234L,QueueSnapshotStore(file).read(h.session.endpoint.identity,"guest")!!.position)
 }}
 @Test fun mixedServerAndPhoneRestoreKeepsTypedDeviceGrantAndNeverConstructsPhoneTrackId(){Harness().use {h->
 val ref=PlaybackRef.Device("12345678-1234-1234-1234-123456789013","a".repeat(64),100,1)
 val rows=listOf(SavedOccurrence("server",7,"Server","Artist",false,durationMs=6000),SavedOccurrence("phone",0,"Phone","Original artist",true,true,601000,ref=ref))
 val expected=QueueSnapshot(h.session.endpoint.identity,"A",rows,1,43000,true,SavedRepeatMode.All)
 QueueSnapshotStore(h.service.file()).write(expected)
 h.onMain{h.service.start()};h.settled()
 val phone=h.service.player.items[1];assertEquals("soundqdevice",phone.localConfiguration!!.uri.scheme)
 val grant=h.service.grants[phone.localConfiguration!!.uri.toString()]!!;assertEquals(ref,grant.device)
 assertTrue(runCatching {grant.track}.isFailure);assertEquals(43000L,h.service.player.currentPosition)
 assertFalse(h.service.player.playing);assertEquals(0,h.service.player.prepares);assertEquals(0,h.service.player.plays)
 h.onMain {h.service.save()};h.settled()
 val reopened=QueueSnapshotStore(h.service.file()).read(h.session.endpoint.identity,"A")!!
 assertEquals(expected,reopened);assertEquals(7L,(reopened.reference(reopened.items[0]) as PlaybackRef.Server).trackId.value)
 }}

 @Test fun heldDelayedSaveCannotDropAcknowledgedCanonicalJamMetadata(){Harness().use {h->
 h.seed();h.onMain{h.service.start()};h.settled()
 Dispatchers.IO.hold=true;h.onMain{h.service.save()};assertTrue(Dispatchers.IO.entered.await(5,TimeUnit.SECONDS))
 val identity=com.soundq.android.data.jam.JamOccurrence("c".repeat(64),"123e4567-e89b-42d3-a456-426614174000","fixture-service:1")
 h.onMain{h.service.player.items[1].mediaMetadata.extras!!.putString("soundqJam",identity.encode());h.service.acknowledgeJam()}
 Dispatchers.IO.release();h.settled()
 val saved=QueueSnapshotStore(h.service.file()).read(h.session.endpoint.identity,"A")!!
 assertEquals(identity,saved.items[1].jam);assertEquals("occ-manual",saved.items[1].occurrence)
 assertEquals(2300L,saved.position);assertFalse(h.service.player.playing);assertEquals(0,h.service.player.plays)
 }}
 @Test fun pausedRestorationKeepsJamKeyOnTheSameActualSavedOccurrence(){Harness().use {h->
 val raw=h.seed();val original=QueueSnapshot.decode(raw,h.session.endpoint.identity,"A")!!
 val identity=com.soundq.android.data.jam.JamOccurrence("c".repeat(64),"123e4567-e89b-42d3-a456-426614174000","fixture-service:1")
 val saved=original.copy(items=original.items.mapIndexed{i,row->if(i==1)row.copy(jam=identity)else row})
 h.service.file().writeText(saved.encode());h.onMain{h.service.start()};h.settled()
 val observed=h.service.player.items[1]
 assertEquals("occ-manual",observed.mediaId);assertEquals(identity,com.soundq.android.data.jam.JamOccurrence.decode(observed.mediaMetadata.extras!!.getString("soundqJam")))
 assertEquals(2300L,h.service.player.currentPosition);assertFalse(h.service.player.playing);assertEquals(0,h.service.player.prepares);assertEquals(0,h.service.player.plays)
 }}
 @Test fun metadataOnlyResumptionReturnsSavedSelectionWithoutChangingLiveModes(){Harness().use {h->
 h.seed();h.onMain{h.service.player.repeatMode=Player.REPEAT_MODE_ONE;h.service.saveJob?.cancel()}
 val f=h.onMain{h.service.onPlaybackResumption(MediaSession(),MediaSession.ControllerInfo(),false)};val result=f.get(5,TimeUnit.SECONDS);h.settled()
 assertEquals(1,result.startIndex);assertEquals(2300L,result.startPositionMs);assertEquals(3,result.mediaItems.size)
 h.onMain{assertEquals(0,h.service.player.mediaItemCount);assertFalse(h.service.player.shuffleModeEnabled);assertEquals(Player.REPEAT_MODE_ONE,h.service.player.repeatMode);assertEquals(0,h.service.player.plays)}
 }}
 @Test fun heldResumptionCannotRestoreModesAfterNewSelectionOrRetiredAccount(){for(retireAccount in listOf(false,true))Harness().use {h->
 h.seed();Dispatchers.IO.hold=true;h.onMain{h.service.onPlaybackResumption(MediaSession(),MediaSession.ControllerInfo(),true)};assertTrue(Dispatchers.IO.entered.await(5,TimeUnit.SECONDS))
 h.onMain{if(retireAccount)h.session.retire() else {h.service.transport.retire();h.service.player.repeatMode=Player.REPEAT_MODE_ONE}}
 Dispatchers.IO.release();h.settled();h.onMain{assertEquals(0,h.service.player.mediaItemCount);assertFalse(h.service.player.shuffleModeEnabled);assertEquals(if(retireAccount)Player.REPEAT_MODE_OFF else Player.REPEAT_MODE_ONE,h.service.player.repeatMode);assertEquals(0,h.service.player.plays);assertTrue(h.service.grants.isEmpty())}
 }}
 @Test fun startupRetiredAccountCannotRestoreModesOrGrants(){Harness().use {h->
 h.seed();Dispatchers.IO.hold=true;h.onMain{h.service.start()};assertTrue(Dispatchers.IO.entered.await(5,TimeUnit.SECONDS));h.session.retire();Dispatchers.IO.release();h.settled()
 assertEquals(0,h.service.player.mediaItemCount);assertFalse(h.service.player.shuffleModeEnabled);assertEquals(Player.REPEAT_MODE_OFF,h.service.player.repeatMode);assertTrue(h.service.grants.isEmpty())
 }}
 @Test fun eachModeListenerSavesPausedChangesIndependentlyAndRestoreDoesNotOverwriteBytes(){Harness().use {h->
 val original=h.seed();h.onMain{h.service.start()};h.settled();assertEquals(original,h.service.file().readText())
 h.onMain{h.service.player.shuffleModeEnabled=false};h.settled();var body=Json.parseToJsonElement(h.service.file().readText()).jsonObject
 assertFalse(body["shuffleEnabled"]!!.jsonPrimitive.boolean);assertEquals("all",body["loopMode"]!!.jsonPrimitive.content)
 h.onMain{h.service.player.repeatMode=Player.REPEAT_MODE_ONE};h.settled();body=Json.parseToJsonElement(h.service.file().readText()).jsonObject
 assertEquals("one",body["loopMode"]!!.jsonPrimitive.content);assertFalse(h.service.player.playing)
 }}
 @Test fun rejectedQueueBytesSurviveModeOnlyActions(){Harness().use {h->
 val original=h.seed().replace("\\"shuffleEnabled\\":true","\\"shuffleEnabled\\":\\"true\\"");h.service.file().writeText(original)
 h.onMain{h.service.start()};h.settled();assertTrue(h.service.rejectedQueue)
 h.onMain{h.service.player.repeatMode=Player.REPEAT_MODE_ONE};h.settled();assertEquals(original,h.service.file().readText());assertEquals(0,h.service.player.mediaItemCount)
 }}
 @Test fun startupReadCannotRestoreOldModesAfterNewSelectionClearedItsTimeline(){Harness().use {h->
 h.seed();Dispatchers.IO.hold=true;h.onMain{h.service.start()};assertTrue(Dispatchers.IO.entered.await(5,TimeUnit.SECONDS))
 h.onMain{h.service.transport.retire();h.service.player.setMediaItems(emptyList(),0,0);h.service.player.shuffleModeEnabled=false;h.service.player.repeatMode=Player.REPEAT_MODE_ONE}
 Dispatchers.IO.release();h.settled();h.onMain{assertEquals("new empty selection must not resurrect old timeline",0,h.service.player.mediaItemCount);assertFalse(h.service.player.shuffleModeEnabled);assertEquals(Player.REPEAT_MODE_ONE,h.service.player.repeatMode)}
 }}
 @Test fun modeOnlyPausedChangesPersistOneObservation(){Harness().use {h->
 h.seed(false,"off");h.onMain{h.service.start()};h.settled()
 h.onMain{h.service.player.shuffleModeEnabled=true;h.service.player.repeatMode=Player.REPEAT_MODE_ONE};h.settled()
 val raw=h.service.file().readText();val body=Json.parseToJsonElement(raw).jsonObject
 assertEquals("mode-only paused shuffle must save",true,body["shuffleEnabled"]!!.jsonPrimitive.boolean);assertEquals("one",body["loopMode"]!!.jsonPrimitive.content)
 assertEquals(2300L,body["position"]!!.jsonPrimitive.long);assertEquals(3,QueueSnapshotStore(h.service.file()).read(h.session.endpoint.identity,"A")!!.items.size);assertFalse(h.service.player.playing)
 }}
 @Test fun composedWriterRestoresExactJamBeyondFirstMetadataPageWithoutPrepareOrPlay(){Harness().use {h->
 val identity=com.soundq.android.data.jam.JamOccurrence("c".repeat(64),"123e4567-e89b-42d3-a456-426614174000","fixture-service:1")
 val rows=List(601){SavedOccurrence("paged-$it",7,"Same track","Fixture",it==600,durationMs=12000,jam=if(it==600)identity else null)}
 val expected=QueueSnapshot(h.session.endpoint.identity,"A",rows,600,1300)
 h.onMain{h.service.mount(expected);h.service.acknowledgeJam()};h.settled()
 assertEquals(expected,QueueSnapshotStore(h.service.file()).read(expected.endpoint,"A"))
 val restored=ExtractedService(Graph(h.session,h.directory),h.jobs)
 h.onMain{restored.start()};h.settled()
 h.onMain{val p=restored.player;assertEquals(rows.map{it.occurrence},p.items.map{it.mediaId});assertEquals(600,p.currentMediaItemIndex);assertEquals(1300L,p.currentPosition)
 assertEquals(identity,com.soundq.android.data.jam.JamOccurrence.decode(p.items[600].mediaMetadata.extras!!.getString("soundqJam")))
 assertTrue(p.items.take(600).all{it.mediaMetadata.extras!!.getString("soundqJam")==null})
 assertFalse(p.playing);assertEquals(0,p.prepares);assertEquals(0,p.plays)}
 }}
 @Test fun playbackResumptionRestoresModesPausedThenOnlyExplicitPlayStarts(){Harness().use {h->
 h.seed();h.onMain{h.service.onPlaybackResumption(MediaSession(),MediaSession.ControllerInfo(),true)};h.settled()
 h.onMain{val p=h.service.player;assertTrue(p.shuffleModeEnabled);assertEquals(Player.REPEAT_MODE_ALL,p.repeatMode);assertEquals(3,p.mediaItemCount);assertEquals(0,p.prepares);assertEquals(0,p.plays);assertFalse(p.playing)
 h.service.transport.play();assertEquals(1,p.plays);assertTrue(p.playing)}
 }}
 @Test fun savedModesRestoreThroughActualStartupWithoutPrepareOrPlay(){Harness().use {h->
 h.seed();h.onMain{h.service.start()};h.settled();h.onMain{
 val p=h.service.player;assertTrue("saved shuffle must reach existing player",p.shuffleModeEnabled);assertEquals(Player.REPEAT_MODE_ALL,p.repeatMode)
 assertEquals(1,p.currentMediaItemIndex);assertEquals(2300L,p.currentPosition);assertEquals(listOf("occ-context","occ-manual","occ-continuation"),p.items.map{it.mediaId})
 assertTrue(p.items[1].mediaMetadata.extras!!.getBoolean("localOnly"));assertEquals("Continuation",p.items[2].mediaMetadata.extras!!.getString("origin"))
 assertFalse(p.playing);assertEquals(0,p.prepares);assertEquals(0,p.plays)
 }
 }}
}
'''.replace('\n METHODS\n','\n'+methods+'\n').replace('\n RESUME\n','\n'+resume+'\n').replace('\n REPEAT\n','\n'+repeat+'\n').replace('\n SHUFFLE\n','\n'+shuffle+'\n')
# Only local boundary declarations differ; transport implementation bytes are exact.
transport_body=transport_body.replace('internal class ServiceTransportPlayer','private class ServiceTransportPlayer',1)
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'QueueModePersistenceExtractedTest.kt').write_text(prelude+'\n'+transport_body+'\n'+fixture)
(a.generate/'AtomicFile.kt').write_text('''package android.util
class AtomicFile(val file:java.io.File) {
 private val pending=java.io.File(file.path+".pending")
 fun startWrite()=java.io.FileOutputStream(pending)
 fun finishWrite(s:java.io.FileOutputStream){s.close();java.nio.file.Files.move(pending.toPath(),file.toPath(),java.nio.file.StandardCopyOption.REPLACE_EXISTING)}
 fun failWrite(s:java.io.FileOutputStream){s.close();pending.delete()}
}
''')
(a.generate/'source-manifest.json').write_text(json.dumps({'serviceSha256':hashlib.sha256(service.encode()).hexdigest(),'transportSha256':hashlib.sha256(transport.encode()).hexdigest(),'blocks':{m:hashlib.sha256(block(service,m).encode()).hexdigest() for m in markers}},indent=2))
print('Generated source-bound queue mode persistence probe',a.generate)
