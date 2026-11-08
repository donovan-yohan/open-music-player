#!/usr/bin/env python3
"""Execute exact production device-play action/controller/service/source blocks on a JVM.

Android/Media3 boundary facades only; mounted framework acceptance stays separate.
"""
from pathlib import Path
import argparse, os, subprocess, tempfile
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=Path(__file__).resolve().parents[1]);p.add_argument('--kotlinc',default='kotlinc');p.add_argument('--generate',type=Path);p.add_argument('--case',choices=['all','artwork','custody'],default='all');args=p.parse_args()
base=args.source/'app/src/main/kotlin/com/soundq/android'
def block(file,marker):
    text=(base/file).read_text();start=text.index(marker);opening=text.index('{',start);depth=1;i=opening+1
    while depth:
        if text[i]=='{':depth+=1
        elif text[i]=='}':depth-=1
        i+=1
    return text[start:i]
action=block('product/ProductViewModel.kt','    fun playDownload(')
controller=block('playback/ControllerProjection.kt','    fun playContext(')
resolve=block('playback/SoundQLibraryService.kt','    private fun resolve(').replace('private fun resolve','fun resolve')
source=block('playback/SignedAudioDataSource.kt','    override fun open(').replace('override fun open','fun open')
grant=(base/'playback/SignedAudioDataSource.kt').read_text().split('internal class MediaGrant',1)[1].split('\n',1)[0]
prelude=r'''
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
object C {const val LENGTH_UNSET=-1}
class SafeFailure(val reason:Reason):java.io.IOException(reason.message) {enum class Reason(val message:String){Retired("Session changed. Sign in again."),AudioUnavailable("Audio is unavailable for this track.")}}
data class TrackId(val value:Long)
data class Track(val id:TrackId,val title:String,val artist:String="",val album:String="",val artwork:String?=null,val durationMs:Long=0)
class AccountScope
class Session {val scope=AccountScope();var remote=true;fun capture()=scope;fun current(s:AccountScope)=s===scope;fun remoteCurrent(s:AccountScope)=current(s)&&remote;fun checkScope(s:AccountScope){if(!current(s))throw SafeFailure(SafeFailure.Reason.Retired)};fun checkRemote(s:AccountScope){if(!remoteCurrent(s))throw SafeFailure(SafeFailure.Reason.Retired)}}
class Bundle {private val fields=mutableMapOf<String,Any>();fun putLong(k:String,v:Long){fields[k]=v};fun getLong(k:String)=fields[k] as Long;fun putString(k:String,v:String){fields[k]=v};fun putBoolean(k:String,v:Boolean){fields[k]=v};fun getBoolean(k:String)=fields[k] as? Boolean ?: false}
class Uri private constructor(val value:String){val scheme get()=value.substringBefore(':');override fun toString()=value;companion object {fun parse(v:String)=Uri(v)}}
class MediaMetadata {var title="";var artist="";var album="";var artwork:Uri?=null;var extras:Bundle?=null
 class Builder {val m=MediaMetadata();fun setTitle(v:String)=apply{m.title=v};fun setArtist(v:String)=apply{m.artist=v};fun setAlbumTitle(v:String)=apply{m.album=v};fun setArtworkUri(v:Uri?)=apply{m.artwork=v};fun setIsPlayable(v:Boolean)=this;fun setIsBrowsable(v:Boolean)=this;fun setExtras(v:Bundle)=apply{m.extras=v};fun build()=m}}
class LocalConfiguration(val uri:Uri)
class MediaItem {class RequestMetadata(val extras:Bundle?=null){class Builder {var extras:Bundle?=null;fun setExtras(v:Bundle)=apply{extras=v};fun build()=RequestMetadata(extras)}}
 var mediaId="";var localConfiguration:LocalConfiguration?=null;var mediaMetadata=MediaMetadata();var requestMetadata=RequestMetadata()
 class Builder {val m=MediaItem();fun setMediaId(v:String)=apply{m.mediaId=v};fun setUri(v:Uri)=apply{m.localConfiguration=LocalConfiguration(v)};fun setMimeType(v:String)=this;fun setMediaMetadata(v:MediaMetadata)=apply{m.mediaMetadata=v};fun setRequestMetadata(v:RequestMetadata)=apply{m.requestMetadata=v};fun build()=m}}
class DataSpec(val uri:Uri,val position:Long=0,val length:Long=-1,val httpRequestHeaders:Map<String,String> = emptyMap()){fun withUri(u:Uri)=DataSpec(u,position,length);fun withRequestHeaders(v:Map<String,String>)=this}
interface DataSource {fun open(s:DataSpec):Long;fun close()}
interface TransferListener
class Lease(val bytes:ByteArray){val size get()=bytes.size.toLong();var offset=0;fun seek(p:Long){require(p in 0..size);offset=p.toInt()};fun close(){}}
class DeviceDownload(val track:Track,val status:com.soundq.android.data.offline.DownloadStatus)
class State(var rows:List<DeviceDownload> = emptyList())
class Value(val value:State)
class Downloads {val state=Value(State());var bytes:ByteArray?=byteArrayOf(1,2,3,4);fun load(s:AccountScope){};fun acquire(s:AccountScope,id:TrackId)=if(id.value==7L)bytes?.let(::Lease) else null}
class Descriptor(val url:String,val sizeBytes:Long?=null)
class Api {var calls=0;fun descriptor(s:AccountScope,id:TrackId):Descriptor{calls++;return Descriptor("https://media.invalid/audio")}}
class Request {fun header(v:String):String?=null}
class Chain {fun request()=Request();fun proceed(r:Request)=r}
class Client {fun newBuilder()=this;fun addNetworkInterceptor(f:(Chain)->Request)=this;fun build()=this}
class OkHttpDataSource:DataSource {class Factory(c:Client){fun createDataSource()=OkHttpDataSource()};fun addTransferListener(l:TransferListener){};override fun open(s:DataSpec)=4L;override fun close(){}}
object HttpDataSource {class InvalidResponseCodeException(val responseCode:Int):Exception()}
class TemporaryCache {fun acquire(s:AccountScope,t:TrackId):Lease?=null;fun begin(s:AccountScope,t:TrackId,n:Long):CacheWrite?=null}
class CacheWrite
class StoragePreferences {class State {val temporaryAudioEnabled=false};class Value {val value=State()};val state=Value()}
class Graph {val temporaryAudio=TemporaryCache();val storagePreferences=StoragePreferences();val session=Session();val downloads=Downloads();val api=Api();val mediaClient=Client();val known=mutableMapOf<TrackId,Track>();fun rememberTracks(t:List<Track>){t.forEach{known[it.id]=it}};fun track(id:TrackId)=known[id]}
object QueuePolicy {const val MAX_CONTEXT_TRACKS=500;const val CONTEXT_LIMIT_MESSAGE="context budget";fun acceptsContext(n:Int)=com.soundq.android.playback.QueuePolicy.acceptsContext(n);fun acceptsAppend(n:Int,a:Int)=com.soundq.android.playback.QueuePolicy.acceptsAppend(n,a)}
'''
classes='class MediaGrant'+grant+'\nclass Source(val graph:Graph,val grants:ConcurrentHashMap<String,MediaGrant>){var grant:MediaGrant?=null;var internalUri:Uri?=null;var upstream:DataSource?=null;var local:Lease?=null;var remaining=0L;var writing:CacheWrite?=null;var expectedCacheBytes=0L;var readCacheBytes=0L;val listeners=mutableListOf<TransferListener>()\n'+source+'\n}\nclass Service(val graph:Graph){fun validateSelection(items:List<MediaItem>,index:Int,position:Long){};fun supportsSourceActions()=true;val grants=ConcurrentHashMap<String,MediaGrant>()\n'+resolve+'\n}\nclass Controller(val graph:Graph,val service:Service){var contextIntent=0L;var contextError:String?=null;fun refuseContext(message:String){error(message)};fun startLargeContext(t:List<Track>,i:Int,l:Boolean,v:()->Boolean){error("Large context outside single-device fixture")};var controller:Facade?=Facade(graph,service)\n'+controller+'\n}\nclass Model(val graph:Graph,val controller:Controller){val downloads get()=graph.downloads.state\n'+action+'\n}\n'
fixture=r'''
class Facade(val graph:Graph,val service:Service) {var resolved=listOf<MediaItem>();var failure:Exception?=null;var opened:Source?=null
 fun setMediaItems(items:List<MediaItem>,index:Int,position:Long){resolved=service.resolve(items)}
 fun prepare(){try {val item=resolved.first();val s=Source(graph,service.grants);opened=s;s.open(DataSpec(item.localConfiguration!!.uri))}catch(e:Exception){failure=e}}
 fun play(){}
}
fun main(){
 val graph=Graph();val service=Service(graph);val controller=Controller(graph,service);val model=Model(graph,controller)
 val track=Track(TrackId(7),"Device track","Fixture",artwork="https://art.invalid/private");val row=DeviceDownload(track,com.soundq.android.data.offline.DownloadStatus.Complete)
 graph.downloads.state.value.rows=listOf(row)
 model.playDownload(graph.session.scope,row){true}
 check(controller.controller!!.resolved.single().mediaMetadata.artwork==null){"OFF-2: explicit device action published remote artwork"}
 check(graph.api.calls==0);check(controller.controller!!.opened!!.local!!.bytes.contentEquals(byteArrayOf(1,2,3,4)))
 println("PASS valid-device-action-no-artwork-or-descriptor")
 graph.downloads.bytes=null
 model.playDownload(graph.session.scope,row){true}
 check(graph.api.calls==0){"OFF-3: displayed Complete row fell back to descriptor after artifact loss"}
 check(controller.controller!!.failure is SafeFailure);check(controller.controller!!.failure!!.message!!.contains("unavailable"))
 println("PASS displayed-complete-then-invalidate-refuses-locally")
 graph.downloads.bytes=byteArrayOf(9,8,7,6);controller.controller!!.failure=null
 controller.playContext(listOf(track),0)
 check(graph.api.calls==0);check(controller.controller!!.opened!!.local!=null)
 println("PASS generic-local-first")
 graph.downloads.bytes=null;controller.playContext(listOf(track),0)
 check(graph.api.calls==1);check(controller.controller!!.opened!!.upstream!=null)
 check(controller.controller!!.resolved.single().mediaMetadata.artwork!=null)
 println("PASS generic-remote-fallback-and-artwork")
 graph.session.remote=false;controller.playContext(listOf(track),0)
 check(graph.api.calls==1)
 println("PASS device-auth-generic-miss-no-network")
}
'''
if args.case=='custody':
    fixture=fixture.replace('check(controller.controller!!.resolved.single().mediaMetadata.artwork==null){"OFF-2: explicit device action published remote artwork"}', 'check(controller.controller!!.resolved.isNotEmpty())')
if args.generate:
    args.generate.mkdir(parents=True,exist_ok=True)
    generated=(prelude+classes+fixture).replace('class DeviceDownload(val track:Track,val status:com.soundq.android.data.offline.DownloadStatus)','class DeviceDownload(val track:Track,val status:DownloadStatus)').replace('com.soundq.android.data.offline.DownloadStatus','DownloadStatus').replace('com.soundq.android.data.offline.DeviceDownload','DeviceDownload')
    (args.generate/'DevicePlayExtractedTest.kt').write_text('package com.soundq.android.extracted\n'+generated+'\nenum class DownloadStatus {Complete,Failed}\nclass DevicePlayExtractedTest {@org.junit.Test fun actualActionControllerServiceSource(){main()}}\n')
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='device-play-',dir=os.environ['TMPDIR']) as temp:
    temp=Path(temp);probe=temp/'Probe.kt';probe.write_text(prelude+classes+fixture)
    enum=temp/'Status.kt';enum.write_text('package com.soundq.android.data.offline\nimport Track\nenum class DownloadStatus {Complete,Failed}\nclass DeviceDownload(val track:Track,val status:DownloadStatus)\n')
    probe.write_text((prelude+classes+fixture).replace('class DeviceDownload(val track:Track,val status:com.soundq.android.data.offline.DownloadStatus)','typealias DeviceDownload = com.soundq.android.data.offline.DeviceDownload'))
    java=Path(os.environ['JAVA_HOME'])/'bin/java';env=os.environ.copy();env['JAVA_OPTS']='-Xmx768m -XX:ActiveProcessorCount=1'
    subprocess.run([args.kotlinc,str(probe),str(enum),'-include-runtime','-d',str(temp/'probe.jar')],check=True,env=env)
    subprocess.run([str(java),'-jar',str(temp/'probe.jar')],check=True,env=env)
