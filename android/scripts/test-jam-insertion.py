#!/usr/bin/env python3
"""Compile the exact Media3 Jam insertion block against host boundary facades.

This does not simulate Android execution. It makes no-autoplay/manual identity
regressions in the production callback fail in the ordinary JVM gate.
"""
import argparse
import ast
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--generate', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
base = root / 'app/src/main/kotlin/com/soundq/android'


def block(path, marker):
    text = (base / path).read_text()
    start = text.index(marker)
    opening = text.index('{', start)
    depth, i = 1, opening + 1
    while depth:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
        i += 1
    return text[start:i]


# Reuse the already maintained minimal Media3/Android facade definitions.
tree = ast.parse((root / 'scripts/test-device-play.py').read_text())
prelude = next(ast.literal_eval(n.value) for n in tree.body
               if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'prelude' for t in n.targets))
prelude = prelude.replace('fun getLong(k:String)', 'fun getString(k:String)=fields[k] as? String;fun getLong(k:String)')
prelude = prelude.replace('class Graph {', 'class Graph {val jamAdmission=Port();')
prelude = prelude.replace('object QueuePolicy {', 'object QueuePolicy {' + block('playback/QueuePolicy.kt', '    fun manualInsert('))
# The device-download facade is not needed by this test.
prelude = prelude.replace('com.soundq.android.data.offline.DownloadStatus', 'DownloadStatus')
resolve = block('playback/SoundQLibraryService.kt', '    private fun resolve(')
admit = block('playback/SoundQLibraryService.kt', '            if(customCommand.customAction==JAM_ADMIT)')
grant = (base / 'playback/SignedAudioDataSource.kt').read_text().split('internal class MediaGrant', 1)[1].split('\n', 1)[0]
source = '''package com.soundq.android.extractedjam
''' + prelude + '''
enum class DownloadStatus {Complete}
class MediaGrant''' + grant + '''
class SessionResult(val resultCode:Int){companion object {const val RESULT_SUCCESS=0}}
object SessionError {const val ERROR_BAD_VALUE=-1;const val ERROR_PERMISSION_DENIED=-2}
object Futures {fun immediateFuture(value:SessionResult)=value}
class Command(val customAction:String)
class Port {var track:Track?=null;var admits=0;var provenance:com.soundq.android.data.jam.JamOccurrence?=null;var lookupOnly=false;fun refused(id:String){};fun consumeWithProvenance(id:String,insert:(Track,com.soundq.android.data.jam.JamOccurrence?,Boolean)->String):Boolean {if(id!="authorized")return false;val t=track ?: return false;admits++;return try {insert(t,provenance,lookupOnly);true}catch(_:Exception){false}}}
class PlayerFacade {val items=mutableListOf<MediaItem>();val mediaItemCount get()=items.size;val currentMediaItem get()=items.getOrNull(currentMediaItemIndex);var currentMediaItemIndex=-1;var playing=false;var prepareCalls=0;var playCalls=0;fun pause(){playing=false};fun prepare(){prepareCalls++};fun play(){playing=true;playCalls++};fun getMediaItemAt(i:Int)=items[i];fun addMediaItem(i:Int,item:MediaItem){items.add(i,item)}}
// Hardware boundary facade only. The production ServiceTransportPlayer is qualified
// separately with its pinned Media3 continuations; no pending read leaves playback alone.
class TransportFacade(private val player:PlayerFacade){fun selectionCommitted(){};var pending=false;var retireCalls=0;fun retire(){retireCalls++;if(pending)player.pause();pending=false}}
class Service(val graph:Graph){fun validateSelection(items:List<MediaItem>,index:Int,position:Long){};fun supportsSourceActions()=true;var account:AccountScope?=graph.session.capture();val grants=ConcurrentHashMap<String,MediaGrant>();val player=PlayerFacade();val transport=TransportFacade(player);val JAM_ADMIT="soundq.jam.admit";var saveCalls=0;var saveFails=false;fun saveJamQueue(){saveCalls++;check(!saveFails)}
''' + resolve + '''
fun command(id:String):SessionResult {val args=Bundle().apply {putString("ticket",id)};val customCommand=Command(JAM_ADMIT)
''' + admit + '''
return SessionResult(-1)
}}
class JamServiceInsertionExtractedTest {
 @org.junit.Test fun exactProductionCallbackInsertsIndependentManualOccurrencesWithoutAutoplay() {
  val graph=Graph();val service=Service(graph);val track=Track(TrackId(7),"Owned");graph.jamAdmission.track=track
  check(service.command("authorized").resultCode==0)
  check(service.command("authorized").resultCode==0)
  check(service.player.items.size==2)
  check(service.player.items.map {it.mediaId}.distinct().size==2)
  check(service.player.items.all {it.mediaMetadata.extras!!.getBoolean("manual")})
  check(service.player.items.all {it.mediaMetadata.extras!!.getLong("trackId")==7L})
  check(!service.player.playing && service.player.prepareCalls==0 && service.player.playCalls==0)
 }
 @org.junit.Test fun rejectedTicketNeverInsertsAndExistingPlayingOwnerDoesNotRestart() {
  val graph=Graph();val service=Service(graph);graph.jamAdmission.track=Track(TrackId(7),"Owned")
  check(service.command("foreign").resultCode==-2);check(service.player.items.isEmpty())
  service.command("authorized");service.player.playing=true;service.player.currentMediaItemIndex=0
  service.command("authorized")
  check(service.player.playing);check(service.player.items.size==2);check(service.player.playCalls==0 && service.player.prepareCalls==0)
 }
 @org.junit.Test fun serviceHasNotAdmittedCurrentAccountCannotInsert() {
  val graph=Graph();val service=Service(graph);graph.jamAdmission.track=Track(TrackId(7),"Owned");service.account=null
  check(service.command("authorized").resultCode==-2);check(service.player.items.isEmpty())
 }
 @org.junit.Test fun acceptedJamInsertionRetiresPendingReadWithoutStartingPlayback() {
  val graph=Graph();val service=Service(graph);graph.jamAdmission.track=Track(TrackId(7),"Owned")
  service.transport.pending=true
  check(service.command("authorized").resultCode==0)
  check(!service.transport.pending && service.transport.retireCalls==1)
  check(service.player.items.size==1 && !service.player.playing)
  check(service.player.prepareCalls==0 && service.player.playCalls==0)
 }
 @org.junit.Test fun canonicalKeyDedupePreservesOccurrenceUriAndPersistsBeforeAcknowledgement() {
  val graph=Graph();val service=Service(graph);graph.jamAdmission.track=Track(TrackId(7),"Owned")
  val identity=com.soundq.android.data.jam.JamOccurrence("c".repeat(64),"123e4567-e89b-42d3-a456-426614174000","fixture-service:1")
  graph.jamAdmission.provenance=identity
  check(service.command("authorized").resultCode==0);val first=service.player.items.single()
  check(first.localConfiguration!!.uri.toString().endsWith("/"+first.mediaId))
  check(com.soundq.android.data.jam.JamOccurrence.decode(first.mediaMetadata.extras!!.getString("soundqJam"))==identity)
  check(service.command("authorized").resultCode==0)
  check(service.player.items.single()===first && service.saveCalls==2)
  check(!service.player.playing && service.player.prepareCalls==0 && service.player.playCalls==0)
 }
 @org.junit.Test fun lookupAbsenceNeverInsertsAndSameKeyCannotChangeTrackOrHostBinding() {
  val graph=Graph();val service=Service(graph);graph.jamAdmission.track=Track(TrackId(7),"Owned")
  val identity=com.soundq.android.data.jam.JamOccurrence("c".repeat(64),"123e4567-e89b-42d3-a456-426614174000","fixture-service:1")
  graph.jamAdmission.provenance=identity;graph.jamAdmission.lookupOnly=true
  check(service.command("authorized").resultCode==-2);check(service.player.items.isEmpty())
  graph.jamAdmission.lookupOnly=false;check(service.command("authorized").resultCode==0)
  graph.jamAdmission.lookupOnly=true;graph.jamAdmission.track=Track(TrackId(8),"Different")
  check(service.command("authorized").resultCode==-2);check(service.player.items.size==1)
  graph.jamAdmission.track=Track(TrackId(7),"Owned");graph.jamAdmission.provenance=identity.copy(sessionId="different-service:1")
  check(service.command("authorized").resultCode==-2);check(service.player.items.size==1)
 }
 @org.junit.Test fun persistenceFailureIsUncertainThenLookupRecoversActualExistingOccurrenceWithoutReplay() {
  val graph=Graph();val service=Service(graph);graph.jamAdmission.track=Track(TrackId(7),"Owned")
  graph.jamAdmission.provenance=com.soundq.android.data.jam.JamOccurrence("c".repeat(64),"123e4567-e89b-42d3-a456-426614174000","fixture-service:1")
  service.saveFails=true;check(service.command("authorized").resultCode==-2)
  val existing=service.player.items.single();service.saveFails=false;graph.jamAdmission.lookupOnly=true
  check(service.command("authorized").resultCode==0);check(service.player.items.single()===existing)
  check(service.player.prepareCalls==0 && service.player.playCalls==0)
 }
}
'''
a.generate.mkdir(parents=True, exist_ok=True)
(a.generate / 'JamServiceInsertionExtractedTest.kt').write_text(source)
