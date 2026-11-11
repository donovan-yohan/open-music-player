#!/usr/bin/env python3
"""Run exact service metadata construction and native state publication on host facades.

The pure resolver is production code. Timeline/Media3 boundary types are facades;
this is not mounted Android or notification delivery proof.
"""
import argparse
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--build', type=Path, required=True)
p.add_argument('--source-root', type=Path)
a = p.parse_args()
root = a.source_root or Path(__file__).resolve().parents[1]
base = root / 'app/src/main/kotlin/com/soundq/android/playback'
service = (base / 'SoundQLibraryService.kt').read_text()
native = (base / 'nativeengine/NativeCallbackPlayer.kt').read_text()


def block(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    depth, at = 1, brace + 1
    while depth:
        depth += (text[at] == '{') - (text[at] == '}')
        at += 1
    return text[start:at]


start = service.index('                    val item=MediaItem.Builder().setMediaId(identity.install)')
end = service.index('\n                    require(graph.session.current(scope)', start)
item = service[start:end]
metadata = re.search(r'^                    val metadata=.*$', service[:start], re.M)
metadata = metadata.group(0) if metadata else ''
state = block(native, '    override fun getState(): State').replace('override fun', 'fun')
helper = base / 'ArrangementMetadata.kt'
production = helper.read_text() if helper.exists() else 'package com.soundq.android.playback\n'
adapter_source = (base / 'Arrangement.kt').read_text()
adapter = block(adapter_source, 'fun TimelineDocument.arrangementMetadata(') if 'fun TimelineDocument.arrangementMetadata(' in adapter_source else ''
commands = sorted(set(re.findall(r'Player\.(COMMAND_\w+)', state)))
fixture = r'''
package com.soundq.android.playback
object Player {
 const val STATE_IDLE=1; const val STATE_BUFFERING=2; const val STATE_READY=3
 const val PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST=1
 const val PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS=1; const val PLAYBACK_SUPPRESSION_REASON_NONE=0
 const val DISCONTINUITY_REASON_SEEK=1
 const val DISCONTINUITY_REASON_INTERNAL=5
 COMMANDS
 class Commands {class Builder {fun addAll(vararg v:Int)=this;fun build()=Commands()}}
}
object C {const val TIME_UNSET=-9223372036854775807L;const val USAGE_MEDIA=1;const val AUDIO_CONTENT_TYPE_MUSIC=1}
fun interface PositionSupplier {fun get():Long}
class AudioAttributes {class Builder {fun setUsage(v:Int)=this;fun setContentType(v:Int)=this;fun build()=AudioAttributes()}}
data class MediaMetadata(val title:String="",val artist:String="",val playable:Boolean=false,val browsable:Boolean=true) {
 fun buildUpon()=Builder().setTitle(title).setArtist(artist).setIsPlayable(playable).setIsBrowsable(browsable)
 class Builder {var title="";var artist="";var playable=false;var browsable=true
  fun setTitle(v:String)=apply{title=v};fun setArtist(v:String)=apply{artist=v};fun setIsPlayable(v:Boolean)=apply{playable=v};fun setIsBrowsable(v:Boolean)=apply{browsable=v}
  fun build()=MediaMetadata(title,artist,playable,browsable)
 }
}
data class Uri(val value:String) {val scheme get()=value.substringBefore(":")}
data class MediaItem(val mediaId:String,val uri:Uri,val mediaMetadata:MediaMetadata,val mime:String="") {
 class Builder {var id="";var uri=Uri("");var metadata=MediaMetadata();var mime=""
  fun setMediaId(v:String)=apply{id=v};fun setUri(v:Uri)=apply{uri=v};fun setMimeType(v:String)=apply{mime=v};fun setMediaMetadata(v:MediaMetadata)=apply{metadata=v}
  fun build()=MediaItem(id,uri,metadata,mime)
 }
}
data class MediaItemData(val uid:String,val item:MediaItem,val durationUs:Long) {
 class Builder(val id:String) {lateinit var item:MediaItem;var duration=0L
  fun setMediaItem(v:MediaItem)=apply{item=v};fun setIsSeekable(v:Boolean)=this;fun setDurationUs(v:Long)=apply{duration=v};fun build()=MediaItemData(id,item,duration)
 }
}
open class Timeline(val rows:List<MediaItemData>)
class TraversalTimeline(source:Timeline,order:List<Int>):Timeline(source.rows)
class State(val timeline:Timeline,val currentTracks:Any,val currentMetadata:MediaMetadata) {
 fun buildUpon()=Builder().setPlaylist(timeline,currentTracks,currentMetadata)
 class Builder {
  var timeline=Timeline(emptyList());var tracks:Any=Unit;var metadata=MediaMetadata()
  fun setPlaylist(rows:List<MediaItemData>)=apply{timeline=Timeline(rows);metadata=rows.firstOrNull()?.item?.mediaMetadata ?: MediaMetadata()}
  fun setPlaylist(v:Timeline,t:Any,m:MediaMetadata)=apply{timeline=v;tracks=t;metadata=m}
  fun setAvailableCommands(v:Player.Commands)=this;fun setPlayWhenReady(v:Boolean,r:Int)=this
  fun setPlaybackSuppressionReason(v:Int)=this;fun setPlaybackState(v:Int)=this;fun setIsLoading(v:Boolean)=this
  fun setPlayerError(v:Any?)=this;fun setRepeatMode(v:Int)=this;fun setShuffleModeEnabled(v:Boolean)=this
  fun setVolume(v:Float)=this;fun setAudioAttributes(v:AudioAttributes)=this;fun setPositionDiscontinuity(r:Int,p:Long)=this
  fun setCurrentMediaItemIndex(v:Int)=this;fun setContentPositionMs(v:PositionSupplier)=this
  fun setContentBufferedPositionMs(v:PositionSupplier)=this;fun setTotalBufferedDurationMs(v:PositionSupplier)=this
  fun build()=State(timeline,tracks,metadata)
 }
}
data class Clip(val occurrence:String,val globalStartMs:Long,val globalEndMs:Long,val title:String="Fallback title")
data class TimelineDocument(val clips:List<Clip>,val revision:Long=53)
data class Source(val occurrenceId:String,val title:String,val artist:String)
data class Identity(val install:String)
class NativeCallbackArrangement(val document:TimelineDocument)
data class MetadataPerformanceTarget(val occurrence:String)
data class MetadataPerformanceDeck(val playing:Boolean,val target:MetadataPerformanceTarget)
ADAPTER
fun installed(document:TimelineDocument,sources:List<Source>,position:Long):MediaItem {
 val identity=Identity("internal-install-53");val uri=Uri("soundqarrangement://schedule/${identity.install}")
 METADATA
 ITEM
 return item
}
class Probe(val arrangement:NativeCallbackArrangement?,val arrangementSourceItems:List<MediaItem>,val items:List<MediaItem>) {
 var position=0L;var intent=false;var acknowledgedPlaying=false;var playback=Player.STATE_READY
 var error:Any?=null;var repeat=0;var shuffle=false;var volume=1f;var index=0;var acknowledgedSeekPosition:Long?=null
 var acknowledgedPausePosition:Long?=null
 val performanceDecks=emptyMap<String,MetadataPerformanceDeck>()
 fun duration(item:MediaItem)=20000L
 fun activeOrder()=listOf(0)
 STATE
}
fun requireMetadata(actual:MediaMetadata,title:String,artist:String) {
 check(actual.title==title && actual.artist==artist) {"Expected '$title' / '$artist', got '${actual.title}' / '${actual.artist}'"}
 check("audition" !in actual.title.lowercase() && "frozen revision" !in actual.artist.lowercase())
}
fun main() {
 val sources=listOf(Source("a","First song","First artist"),Source("b","Second song","Second artist"))
 // Deliberately not document-list order. Metadata must follow playback placement.
 val document=TimelineDocument(listOf(Clip("b",5000,12000),Clip("a",0,8000)))
 val installed=installed(document,sources,0)
 requireMetadata(installed.mediaMetadata,"First song","First artist")
 check(installed.mediaId=="internal-install-53" && installed.uri.value=="soundqarrangement://schedule/internal-install-53")
 requireMetadata(installed(document,sources,5000).mediaMetadata,"First song → Second song","First artist → Second artist")
 val originalItems=sources.map {MediaItem(it.occurrenceId,Uri("soundq://source/${it.occurrenceId}"),MediaMetadata(it.title,it.artist))}
 val probe=Probe(NativeCallbackArrangement(document),originalItems,listOf(installed))
 for((position,title,artist) in listOf(Triple(0L,"First song","First artist"),Triple(4999L,"First song","First artist"),Triple(5000L,"First song → Second song","First artist → Second artist"),Triple(7999L,"First song → Second song","First artist → Second artist"),Triple(8000L,"Second song","Second artist"),Triple(12000L,"Second song","Second artist"),Triple(2500L,"First song","First artist"))) {
  probe.position=position
  val state=probe.getState()
  requireMetadata(state.currentMetadata,title,artist)
  check(state.timeline.rows.single().item === installed) {"Metadata publication replaced source item"}
  check(state.timeline.rows.single().uid==installed.mediaId && state.timeline.rows.single().durationUs==20000000L)
 }
 val ordinary=Probe(null,emptyList(),originalItems)
 requireMetadata(ordinary.getState().currentMetadata,"First song","First artist")
 println("PASS exact service metadata and native currentMetadata across zero, overlap, half-open end, completion and reverse cursor; original item/UID/URI/duration retained; ordinary playback unchanged")
}
'''
fixture = fixture.replace('COMMANDS', '\n'.join(' const val '+v+'='+str(100+i) for i,v in enumerate(commands)))
fixture = fixture.replace('\nADAPTER\n', '\n'+adapter+'\n').replace('\n METADATA\n', '\n'+metadata+'\n').replace('\n ITEM\n', '\n'+item+'\n').replace('\n STATE\n', '\n'+state+'\n')
a.build.mkdir(parents=True, exist_ok=True)
kt = a.build / 'ArrangementMetadataProbe.kt'
kt.write_text(fixture)
production_file = a.build / 'ArrangementMetadata.kt'
production_file.write_text(production)
jar = a.build / 'probe.jar'
subprocess.run(['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',str(kt),str(production_file),'-include-runtime','-d',str(jar)], check=True)
subprocess.run(['java','-XX:ActiveProcessorCount=1','-jar',str(jar)], check=True)
