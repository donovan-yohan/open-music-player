#!/usr/bin/env python3
"""Exact service listener/resolve and continuation body, real TLS/API/session on JVM.
Only Android/Media3 boundaries are facades. --service permits identical baseline replay.
"""
import argparse, hashlib, json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--service',type=Path);a=p.parse_args()
base=Path(__file__).resolve().parents[1]/'app/src/main/kotlin/com/soundq/android'
def block(text,marker):
 s=text.index(marker);i=text.index('{',s)+1;depth=1
 while depth:
  depth+=(text[i]=='{')-(text[i]=='}');i+=1
 return text[s:i]
service=(a.service or base/'playback/SoundQLibraryService.kt').read_text()
callbacks=block(service,'        override fun onPlayerCommandRequest(').replace('override fun','fun',1)
listener=block(service,'        player.addListener(object:Player.Listener').replace('player.addListener(','',1)
resolve=block(service,'    private fun resolve(').replace('private fun resolve','fun resolve',1)
# Boundaries are declared independently; no production callback bodies are rewritten.
prelude='''package com.soundq.android.continuationprobe
import com.soundq.android.data.*
import com.soundq.android.data.preferences.*
import com.google.common.util.concurrent.*
import kotlinx.coroutines.*
import org.junit.Test
import org.junit.Assert.*
import mockwebserver3.*
import okhttp3.OkHttpClient
import okhttp3.tls.*
import java.util.UUID
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicLong
private class Bundle {val b=mutableMapOf<String,Any>();fun putLong(k:String,v:Long){b[k]=v};fun getLong(k:String)=b[k] as? Long ?: 0L;fun putString(k:String,v:String){b[k]=v};fun getString(k:String)=b[k] as? String;fun putBoolean(k:String,v:Boolean){b[k]=v};fun getBoolean(k:String)=b[k] as? Boolean ?: false}
private class Uri(val raw:String){val scheme get()=raw.substringBefore(':');override fun toString()=raw;companion object {fun parse(v:String)=Uri(v)}}
private class MediaMetadata {var title:CharSequence?=null;var artist:CharSequence?=null;var extras:Bundle?=null
 class Builder {val m=MediaMetadata();fun setTitle(v:CharSequence?)=apply{m.title=v};fun setArtist(v:CharSequence?)=apply{m.artist=v};fun setAlbumTitle(v:String)=this;fun setArtworkUri(v:Uri?)=this;fun setIsPlayable(v:Boolean)=this;fun setIsBrowsable(v:Boolean)=this;fun setExtras(v:Bundle)=apply{m.extras=v};fun build()=m}}
private class MediaItem {class LocalConfiguration(val uri:Uri);class RequestMetadata(val extras:Bundle?=null){class Builder {var e:Bundle?=null;fun setExtras(v:Bundle)=apply{e=v};fun build()=RequestMetadata(e)}}
 var mediaId="";var localConfiguration:LocalConfiguration?=null;var mediaMetadata=MediaMetadata();var requestMetadata=RequestMetadata()
 class Builder {val m=MediaItem();fun setMediaId(v:String)=apply{m.mediaId=v};fun setUri(v:Uri)=apply{m.localConfiguration=LocalConfiguration(v)};fun setMimeType(v:String)=this;fun setMediaMetadata(v:MediaMetadata)=apply{m.mediaMetadata=v};fun setRequestMetadata(v:RequestMetadata)=apply{m.requestMetadata=v};fun build()=m}}
private class PlaybackException:Exception()
private class Timeline
private open class Player {
 class Commands
 class Events {fun containsAny(vararg events:Int)=false}
 interface Listener {fun onEvents(player:Player,events:Events){};fun onAvailableCommandsChanged(availableCommands:Commands){};fun onPlayerError(error:PlaybackException){};fun onTimelineChanged(timeline:Timeline,reason:Int){};fun onIsPlayingChanged(isPlaying:Boolean){};fun onPositionDiscontinuity(oldPosition:PositionInfo,newPosition:PositionInfo,reason:Int){};fun onPlaybackStateChanged(playbackState:Int){};fun onMediaItemTransition(mediaItem:MediaItem?,reason:Int){};fun onRepeatModeChanged(repeatMode:Int){};fun onShuffleModeEnabledChanged(shuffleModeEnabled:Boolean){}}
 class PositionInfo
 companion object {const val EVENT_TIMELINE_CHANGED=1;const val EVENT_MEDIA_ITEM_TRANSITION=2;const val EVENT_POSITION_DISCONTINUITY=3;const val EVENT_SHUFFLE_MODE_ENABLED_CHANGED=4;const val TIMELINE_CHANGE_REASON_PLAYLIST_CHANGED=1;const val STATE_IDLE=1;const val STATE_READY=3;const val STATE_ENDED=4;const val REPEAT_MODE_OFF=0;const val REPEAT_MODE_ONE=1;const val REPEAT_MODE_ALL=2;const val DISCONTINUITY_REASON_SEEK=1}
 val listeners=mutableListOf<Listener>();var items=listOf<MediaItem>();var currentMediaItemIndex=0;var currentPosition=0L;var repeatMode=0;var playbackState=STATE_IDLE;var playWhenReady=false;var isPlaying=false;var plays=0;var prepares=0
 val changingTraversal=false
 val mediaItemCount get()=items.size;val currentMediaItem get()=items.getOrNull(currentMediaItemIndex)
 fun getMediaItemAt(i:Int)=items[i];fun hasNextMediaItem()=currentMediaItemIndex<items.lastIndex
 fun addListener(v:Listener){listeners.add(v)};fun removeListener(v:Listener){listeners.remove(v)}
 fun addMediaItems(v:List<MediaItem>){items=items+v;listeners.toList().forEach{it.onTimelineChanged(Timeline(),0)}}
 fun seekTo(i:Int,p:Long){currentMediaItemIndex=i;currentPosition=p;listeners.toList().forEach{it.onPositionDiscontinuity(PositionInfo(),PositionInfo(),DISCONTINUITY_REASON_SEEK);it.onMediaItemTransition(currentMediaItem,0)}}
 fun prepare(){prepares++;playbackState=STATE_READY};fun play(){check(playbackState==STATE_READY);plays++;playWhenReady=true;isPlaying=true;listeners.toList().forEach{it.onIsPlayingChanged(true)}}
 fun pause(){isPlaying=false;playWhenReady=false;listeners.toList().forEach{it.onIsPlayingChanged(false)}}
 fun naturalEnd(){isPlaying=false;playbackState=STATE_ENDED;listeners.toList().forEach{it.onIsPlayingChanged(false);it.onPlaybackStateChanged(STATE_ENDED)}}
}
private class ServiceQueuePlayer:Player()
private class ListeningServicePlayer:Player() {fun continueExhaustedQueue(items:List<MediaItem>,accepted:()->Boolean,current:()->Boolean):Deferred<Boolean>?=error("Rolling owner outside sequential fixture")}
// The retained sequential player facade keeps its eager 500-item capacity.
private object QueuePolicy {const val MAX_CONTEXT_TRACKS=500;fun acceptsAppend(n:Int,a:Int)=n.toLong()+a<=MAX_CONTEXT_TRACKS}
private class MediaGrant(val scope:AccountScope,val id:TrackId,val localOnly:Boolean)
private class Jam {fun replaceOwner(){}}
private class TimelinePort {fun cancelAudition(){}}
private class ContextStartsBoundary {fun retire(){}}
private class Graph(val session:AccountSession,val api:SoundQApi,val listeningPreferences:EndOfQueuePreferences){val contextStarts=ContextStartsBoundary();var trackRead:(()->Unit)?=null;val jamAdmission=Jam();val timeline=TimelinePort();val known=mutableMapOf<TrackId,Track>();fun rememberTracks(v:List<Track>){v.forEach{known[it.id]=it}};fun track(id:TrackId):Track? {trackRead?.invoke();return known[id]}}
private class Transport {private val counter=AtomicLong();val revision get()=counter.get();var onIntentChanged:()->Unit={};fun retire(){counter.incrementAndGet();onIntentChanged()};fun pause(){retire()}}
private class ArrangementIdentity(val install:String)
private class AcceptedArrangement(val identity:ArrangementIdentity)
private class ExtractedService(val graph:Graph,val jobs:CoroutineScope) {
 var clockRevision=0L
 fun validateSelection(items:List<MediaItem>,index:Int,position:Long){}
 fun updatePlaybackWakeLock(){} // OS power ownership is outside this continuation fixture.
 fun supportsSourceActions()=true
 // Arrangement grant retention is composed into the listener, not exercised here.
 var acceptedArrangement:AcceptedArrangement?=null;var pendingArrangement:Any?=null;var arrangementItems:List<MediaItem>?=null;var arrangementReadyCalls=0;var likeRefreshCalls=0
 fun arrangementReady(){arrangementReadyCalls++};fun refreshLikeButton(){likeRefreshCalls++};fun retireArrangement():Unit=error("Arrangement retirement outside continuation fixture")
 val player=Player();val transport=Transport();val grants=ConcurrentHashMap<String,MediaGrant>();val mixGrants=ConcurrentHashMap<String,AutoCloseable>();fun publishSessionExtras(){};fun scheduleSave(){}
 val continuation=ServiceLibraryContinuation(player,transport,graph,jobs){tracks,_ -> graph.rememberTracks(tracks);resolve(tracks.map{MediaItem.Builder().setMediaId(it.id.value.toString()).build()})}
 fun bind(){transport.onIntentChanged=continuation::command;player.addListener(LISTENER)}
 RESOLVE
}
'''.replace('LISTENER',listener).replace('RESOLVE',resolve)
fixture='''
private class Store:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
private class Harness:AutoCloseable {
 val server=MockWebServer();val entered=CountDownLatch(1);val release=CountDownLatch(1);var held=false;var failure=false;var rows=listOf(2L);var total=1;val requests=CopyOnWriteArrayList<RecordedRequest>()
 val main=Executors.newSingleThreadExecutor().asCoroutineDispatcher();val jobs=CoroutineScope(SupervisorJob()+main);val graph:Graph;val service:ExtractedService
 val directory=java.nio.file.Files.createTempDirectory(java.nio.file.Path.of(System.getenv("TMPDIR")),"continuation-probe-").toFile()
 init {
 val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build();server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory())
 server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {requests.add(r);check(r.url.encodedPath=="/api/v1/library");check(r.headers["Authorization"]=="Bearer synthetic-access");entered.countDown();if(held)check(release.await(30,TimeUnit.SECONDS));if(failure)return MockResponse.Builder().code(503).build()
 val offset=r.url.queryParameter("offset")!!.toInt();val body=rows.joinToString(","){"{\\"id\\":$it,\\"title\\":\\"Track $it\\",\\"duration_ms\\":2000}"};return MockResponse.Builder().body("{\\"tracks\\":[$body],\\"total\\":$total,\\"limit\\":100,\\"offset\\":$offset}").build()}}
 server.start();val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build();val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),Store());check(session.accept(session.beginIntent(),SecretTokens("synthetic-access","synthetic-refresh","fixture")))
 val prefs=EndOfQueuePreferences(directory.resolve("mode.json"));prefs.load();graph=Graph(session,SoundQApi(session,OkHttpClient.Builder().readTimeout(30,TimeUnit.SECONDS).sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()),prefs)
 service=ExtractedService(graph,jobs);onMain {service.bind();val t=Track(TrackId(1),"Original",durationMs=2000);graph.rememberTracks(listOf(t));service.player.items=service.resolve(listOf(MediaItem.Builder().setMediaId("1").build()));service.player.prepare();service.player.play()}
 }
 fun <T> onMain(b:()->T):T=runBlocking{withContext(main){b()}}
 fun end(){onMain{service.player.naturalEnd()}}
 fun settled(){runBlocking {withTimeout(5000){while(onMain{service.continuation.pending} || jobs.coroutineContext[Job]!!.children.any{it.isActive})delay(5)}}}
 override fun close(){release.countDown();onMain{service.continuation.close()};runBlocking{jobs.coroutineContext[Job]!!.cancelAndJoin()};main.close();server.close();directory.deleteRecursively()}
}
class LibraryContinuationExtractedTest {
 @Test fun combinedListenerKeepsArrangementReadyAndLikeRefreshAlongsideNaturalContinuation(){Harness().use {h->
 val before=h.service.likeRefreshCalls
 h.onMain {h.service.player.listeners.forEach {it.onPlaybackStateChanged(Player.STATE_READY);it.onMediaItemTransition(h.service.player.currentMediaItem,0)}}
 assertTrue(h.service.arrangementReadyCalls>0);assertTrue(h.service.likeRefreshCalls>before)
 h.end();h.settled();assertEquals(2,h.service.player.items.size);assertTrue(h.service.arrangementReadyCalls>=2)
 }}
 @Test fun acceptedArrangementCannotInvokeOwnedLibraryContinuationEvenWithOrdinarySourceMetadata(){Harness().use {h->
 h.onMain{h.service.acceptedArrangement=AcceptedArrangement(ArrangementIdentity("arrangement"))};h.end();h.settled();assertEquals(0,h.requests.size);assertEquals(1,h.service.player.items.size)
 }}
 @Test fun realTransportRetirementHookDisarmsBeforeALaterEndedCallback(){Harness().use {h->
 h.onMain{h.service.transport.retire()};h.end();h.settled();assertEquals(0,h.requests.size);assertEquals(1,h.service.player.items.size)
 }}
 @Test fun naturalCallbackTraversesTlsResolveCanonicalAppendAndSamePlayerPlayExactlyOnce(){Harness().use {h->
 val old=h.service.player.items.single();h.end();h.settled();h.onMain {
 assertEquals(listOf(1L,2L),h.service.player.items.map{it.mediaMetadata.extras!!.getLong("trackId")});assertSame(old,h.service.player.items.first());assertEquals(1,h.service.player.currentMediaItemIndex);assertTrue(h.service.player.isPlaying);assertEquals(2,h.service.player.plays);assertEquals(2,h.service.grants.size)
 assertEquals("Continuation",h.service.player.items.last().mediaMetadata.extras!!.getString("origin"))
 };assertEquals(1,h.requests.size);assertEquals("100",h.requests.single().url.queryParameter("limit"))
 }}
 @Test fun heldTlsCannotAppendGrantOrAutostartAfterPauseEvenWithPlayAba(){Harness().use {h->
 h.held=true;h.end();assertTrue(h.entered.await(5,TimeUnit.SECONDS));val before=h.onMain{h.service.player.items};val grants=h.service.grants.size;val plays=h.service.player.plays
 h.onMain{h.service.transport.retire();h.service.player.pause();h.service.player.prepare();h.service.player.play();h.service.player.pause()};h.release.countDown();h.settled()
 h.onMain{assertEquals(before,h.service.player.items);assertEquals(grants,h.service.grants.size);assertEquals(plays+1,h.service.player.plays);assertFalse(h.service.player.isPlaying)}
 }}
 @Test fun heldTlsCannotAppendAfterSameOccurrenceSeek(){Harness().use {h->
 h.held=true;h.end();assertTrue(h.entered.await(5,TimeUnit.SECONDS));h.onMain{h.service.transport.retire();h.service.player.seekTo(0,123)};h.release.countDown();h.settled();assertEquals(1,h.service.player.items.size);assertEquals(123L,h.service.player.currentPosition);assertEquals(1,h.service.grants.size)
 }}
 @Test fun heldTlsCannotSurviveOffOnAba(){Harness().use {h->
 h.held=true;h.end();assertTrue(h.entered.await(5,TimeUnit.SECONDS));val p=h.graph.listeningPreferences;assertTrue(p.setMode(p.capture()!!,EndOfQueue.Off){true});assertTrue(p.setMode(p.capture()!!,EndOfQueue.ShuffleLibrary){true});h.release.countDown();h.settled();assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.grants.size)
 }}
 @Test fun heldTlsCannotSurviveAccountRetirement(){Harness().use {h->
 h.held=true;h.end();assertTrue(h.entered.await(5,TimeUnit.SECONDS));h.graph.session.retire();h.release.countDown();h.settled();assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.grants.size)
 }}
 @Test fun offAndRepeatModesDoNotFetch(){for(mode in listOf(-1,1,2))Harness().use {h->
 h.onMain{if(mode<0)h.graph.listeningPreferences.setMode(h.graph.listeningPreferences.capture()!!,EndOfQueue.Off){true} else h.service.player.repeatMode=mode};h.end();h.settled();assertTrue(h.requests.isEmpty());assertEquals(1,h.service.player.items.size)
 }}
 @Test fun manualPauseStopAndSeekDoNotFetch(){Harness().use {h->h.onMain{h.service.player.pause();h.service.player.seekTo(0,1000)};h.end();h.settled();assertTrue(h.requests.isEmpty())}}
 @Test fun emptyAndFailureStopSilentlyWithoutGrantMutation(){for(failure in listOf(false,true))Harness().use {h->h.rows=emptyList();h.failure=failure;h.end();h.settled();assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.grants.size);assertFalse(h.service.player.isPlaying);assertEquals(1,h.service.player.plays)}}
 @Test fun capacityRefusesWholeBatchBeforeGrantsOrAppend(){Harness().use {h->h.onMain{
 val t=Track(TrackId(1),"History",durationMs=2000);h.graph.rememberTracks(listOf(t));h.service.player.items=h.service.resolve(List(500){MediaItem.Builder().setMediaId("1").build()});h.service.player.currentMediaItemIndex=499
 };val original=h.service.player.items;val grants=h.service.grants.size;h.end();h.settled();assertEquals(original,h.service.player.items);assertEquals(grants,h.service.grants.size);assertEquals(499,h.service.player.currentMediaItemIndex)}}
 @Test fun localOnlyAndMixedQueuesNeverFetch(){for(scheme in listOf("soundq","soundqmix"))Harness().use {h->h.onMain{val item=h.service.player.items.single();if(scheme=="soundq")item.mediaMetadata.extras!!.putBoolean("localOnly",true) else item.localConfiguration=MediaItem.LocalConfiguration(Uri.parse("soundqmix://fixture"))};h.end();h.settled();assertTrue(h.requests.isEmpty())}}
 @Test fun repeatedEndedCallbackFetchesOnlyOnceAndSecondNaturalBatchGetsIndependentOccurrences(){Harness().use {h->
 h.rows=listOf(1,2);h.total=2;h.end();h.settled();h.onMain{h.service.continuation.ended(Player.STATE_ENDED)};h.settled();assertEquals(1,h.requests.size)
 h.rows=listOf(1,2);h.end();h.settled();assertEquals(2,h.requests.size);assertEquals(listOf(1L,2L,1L),h.service.player.items.map{it.mediaMetadata.extras!!.getLong("trackId")});assertEquals(3,h.service.player.items.map{it.mediaId}.distinct().size)
 }}
 @Test fun staleEndedArgumentWhileCanonicalPlayerIsReadyOrIdleCannotReadOrConsumeNaturalCompletion(){
 for(state in listOf(Player.STATE_READY,Player.STATE_IDLE))Harness().use {h->
 h.onMain {val p=h.service.player;p.playbackState=state;if(state==Player.STATE_IDLE){p.isPlaying=false;p.listeners.forEach{it.onIsPlayingChanged(false)}};p.listeners.forEach{it.onPlaybackStateChanged(Player.STATE_ENDED)}}
 h.settled();assertTrue(h.requests.isEmpty());assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.grants.size);assertEquals(1,h.service.player.plays)
 h.onMain{h.service.player.prepare();h.service.player.play()};h.end();h.settled()
 assertEquals(1,h.requests.size);assertEquals(2,h.service.player.items.size)
 }}
 @Test fun automaticItemTransitionWhileStillPlayingRearmsTheFinalExhaustion(){Harness().use {h->h.onMain {
 val next=h.service.resolve(listOf(MediaItem.Builder().setMediaId("1").build())).single();h.service.player.items=h.service.player.items+next;h.service.player.currentMediaItemIndex=1
 h.service.continuation.transition()
 };h.end();h.settled();assertEquals(3,h.service.player.items.size);assertEquals(1,h.requests.size)}}
 @Test fun admittedPauseCommandRevokesHeldContinuationBeforeActualPauseRuns(){Harness().use {h->h.held=true;h.end();assertTrue(h.entered.await(5,TimeUnit.SECONDS));h.onMain{h.service.continuation.command()};h.release.countDown();h.settled();assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.player.plays)}}
 @Test fun repeatAndShuffleIntentWhilePlayingDoNotDisableLaterNaturalCompletion(){Harness().use {h->h.onMain {h.service.continuation.repeatChanged();h.service.continuation.shuffleChanged()};h.end();h.settled();assertEquals(2,h.service.player.items.size)}}
 @Test fun heldTlsIsRevokedByLockEvenBeforeTheServiceCollectorRuns(){Harness().use {h->h.held=true;h.end();assertTrue(h.entered.await(5,TimeUnit.SECONDS));assertTrue(h.graph.session.lockLocal());h.release.countDown();h.settled();assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.grants.size)}}
 @Test fun heldTlsIsRevokedAtActualSkipRepeatStopAdmissions(){for(command in listOf(Player.COMMAND_STOP,Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,Player.COMMAND_SET_REPEAT_MODE))Harness().use {h->h.held=true;h.end();assertTrue(h.entered.await(5,TimeUnit.SECONDS));h.onMain{h.service.onPlayerCommandRequest(MediaSession(),MediaSession.ControllerInfo(),command)};h.release.countDown();h.settled();assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.grants.size);assertEquals(1,h.service.player.plays)}}
 @Test fun aggregateDeadlineReleasesAdmissionWithoutWaitingForHeldSocket(){Harness().use {h->h.held=true;val start=System.nanoTime();h.end();assertTrue(h.entered.await(5,TimeUnit.SECONDS));runBlocking{withTimeout(17000){while(h.onMain{h.service.continuation.pending})delay(20)}};assertTrue(System.nanoTime()-start>=14_000_000_000L);assertEquals(1L,h.release.count);assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.grants.size);h.release.countDown();h.settled();assertEquals(1,h.service.player.plays)}}
 @Test fun accountRevocationDuringActualResolverCannotLeaveOrphanGrants(){Harness().use {h->h.graph.trackRead={h.graph.session.lockLocal()};h.end();h.settled();assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.grants.size)}}
 @Test fun noProgressPageTerminatesAndInitialTotalDoesNotMove(){Harness().use {h->h.total=1000;h.end();h.settled();assertEquals(2,h.requests.size);assertEquals(listOf("0","1"),h.requests.map{it.url.queryParameter("offset")});assertEquals(2,h.service.player.items.size)}}
 @Test fun heldTimelineAbaAndServiceCloseRetireTheExactAttempt(){for(close in listOf(false,true))Harness().use {h->h.held=true;h.end();assertTrue(h.entered.await(5,TimeUnit.SECONDS));h.onMain{if(close)h.service.continuation.close() else {h.service.continuation.timelineChanged();h.service.continuation.timelineChanged()}};h.release.countDown();h.settled();assertEquals(1,h.service.player.items.size);assertEquals(1,h.service.grants.size)}}
}
'''
constants=['COMMAND_CHANGE_MEDIA_ITEMS','COMMAND_PLAY_PAUSE','COMMAND_STOP','COMMAND_SEEK_TO_DEFAULT_POSITION','COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM','COMMAND_SEEK_TO_MEDIA_ITEM','COMMAND_SEEK_TO_NEXT','COMMAND_SEEK_TO_PREVIOUS','COMMAND_SEEK_TO_NEXT_MEDIA_ITEM','COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM','COMMAND_SEEK_BACK','COMMAND_SEEK_FORWARD','COMMAND_GET_TIMELINE','COMMAND_GET_CURRENT_MEDIA_ITEM','COMMAND_GET_METADATA','COMMAND_PREPARE','COMMAND_SET_REPEAT_MODE']
prelude=prelude.replace('const val STATE_IDLE=1;', ';'.join(f'const val {v}={100+i}' for i,v in enumerate(constants))+';const val STATE_IDLE=1;')
prelude=prelude.replace('fun retire(){counter.incrementAndGet()}}','fun retire(){counter.incrementAndGet()};fun pause(){retire()}}')
prelude=prelude.replace('private class ExtractedService(', 'private object SessionError {const val ERROR_PERMISSION_DENIED=-4;const val ERROR_INVALID_STATE=-5};private object SessionResult {const val RESULT_SUCCESS=0};private class MediaSession {class ControllerInfo};private class Interruptions {fun command(){}}\nprivate class ExtractedService(')
prelude=prelude.replace(' fun bind(){', ' var account=graph.session.capture();var selectionEpoch=0L;val interruptions=Interruptions();var undoScope:AccountScope?=null;var undo:List<MediaItem>?=null;var undoIndex=0;var undoPosition=0L;fun admitted(c:MediaSession.ControllerInfo)=true\n'+callbacks+'\n fun bind(){')
fixture=fixture.replace('h.service.continuation.command()', 'h.service.onPlayerCommandRequest(MediaSession(),MediaSession.ControllerInfo(),Player.COMMAND_PLAY_PAUSE)')
helper=(base/'playback/ServiceLibraryContinuation.kt').read_text() if (base/'playback/ServiceLibraryContinuation.kt').exists() else ''
selector=(base/'playback/LibraryShuffleContinuationSource.kt').read_text()
selector='\n'.join(l for l in selector.splitlines() if not l.startswith(('package ','import '))).replace('internal class LibraryShuffleContinuationSource','private class LibraryShuffleContinuationSource')
prelude=prelude.replace('import java.util.UUID','import java.util.UUID\nimport java.util.concurrent.atomic.AtomicBoolean\nimport kotlin.random.Random')
if '        continuation=ServiceLibraryContinuation(' in service:
 init=block(service,'        continuation=ServiceLibraryContinuation(').replace('continuation=','val continuation=',1)
 start=prelude.index(' val continuation=');end=prelude.index('\n var account=',start)
 prelude=prelude[:start]+init+prelude[end:]
prelude=prelude.replace('private class Bundle {','private class Bundle() {constructor(other:Bundle?):this(){if(other!=null)b.putAll(other.b)};')
prelude=prelude.replace('private class MediaMetadata {','private class MediaMetadata {fun buildUpon()=Builder(this);').replace('class Builder {val m=MediaMetadata();','class Builder(val m:MediaMetadata=MediaMetadata()) {')
prelude=prelude.replace('private class MediaItem {','private class MediaItem {fun buildUpon()=Builder(this);').replace('class Builder {val m=MediaItem();','class Builder(val m:MediaItem=MediaItem()) {')
if helper:
 helper='\n'.join(l for l in helper.splitlines() if not l.startswith(('package ','import ','@androidx.'))).replace('internal class ServiceLibraryContinuation','private class ServiceLibraryContinuation').replace('ServiceTransportPlayer','Transport').replace('AppGraph','Graph')
else:
 helper='private class ServiceLibraryContinuation(p:Player,t:Transport,g:Graph,j:CoroutineScope,r:(List<Track>)->List<MediaItem>) {val pending=false;fun close(){}}'
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'LibraryContinuationExtractedTest.kt').write_text(prelude+selector+helper+fixture)
(a.generate/'extraction.json').write_text(json.dumps({'serviceSha256':hashlib.sha256(service.encode()).hexdigest(),'listenerSha256':hashlib.sha256(listener.encode()).hexdigest(),'resolveSha256':hashlib.sha256(resolve.encode()).hexdigest(),'helperSha256':hashlib.sha256(helper.encode()).hexdigest(),'boundaryOnlyTransformations':True},indent=2))
