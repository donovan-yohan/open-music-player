#!/usr/bin/env python3
"""Exact production Radar/CAA host tests. TLS and Bitmap facades are not Android paint.
No SDK, Gradle, install, external network or dependency fetch. One 512MiB compiler.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',required=True,type=Path)
p.add_argument('--metadata-only',action='store_true')
p.add_argument('--mutation',choices=['no-redirects','revive-owner','stale-publication','free-running-job','unchecked-draw'])
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
r=Path(__file__).resolve().parents[1];main=r/'app/src/main/kotlin/com/soundq/android';test=r/'app/src/test/kotlin/com/soundq/android'
cache=Path(os.environ.get('GRADLE_USER_HOME') or Path.home()/'.gradle')/'caches'
modules=cache/'modules-2/files-2.1'
def jar(g,n,v):
 paths=list((modules/g/n/v).glob('**/*.jar'));assert len(paths)==1,(n,paths);return paths[0]
jars=[jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.12.0'),jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.12.0'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2'),jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3')]
if not a.metadata_only:
 jars += [next((cache/'9.7.0/transforms').glob('*/transformed/okhttp-runtime.jar')),jar('com.squareup.okio','okio-jvm','3.18.1'),jar('com.squareup.okhttp3','okhttp-tls','5.5.1'),jar('com.squareup.okhttp3','mockwebserver3','5.5.1')]
inputs={}
def copy(path):
 inputs[str(path.relative_to(r))]=hashlib.sha256(path.read_bytes()).hexdigest();shutil.copyfile(path,out/path.name)
def emit(name,text):(out/name).write_text(text)
copy(main/'data/discovery/ReleaseRadar.kt');copy(main/'data/catalog/Catalog.kt')
emit('OwnerBoundary.kt','''package com.soundq.android.data.discovery
class DiscoveryView
class DiscoveryDraft
''')
emit('FailureBoundary.kt','''package com.soundq.android.data
class SafeFailure(val reason:Reason):Exception(){enum class Reason {InvalidResponse}}
class ApiEndpoint {companion object {fun parse(raw:String)=ApiEndpoint()}}
''')
classes=['com.soundq.android.data.RadarMetadataV2Test','com.soundq.android.data.ReleaseRadarWireTest']
for name in ['RadarMetadataV2Test','ReleaseRadarWireTest']:copy(test/f'data/{name}.kt')
if not a.metadata_only:
 emit('AndroidLog.kt','''package android.util
object Log {
 @JvmStatic fun isLoggable(tag:String,level:Int)=false
 @JvmStatic fun println(priority:Int,tag:String,message:String)=0
 @JvmStatic fun getStackTraceString(error:Throwable)=error.stackTraceToString()
}
''')
 emit('AndroidBuild.kt','''package android.os
object Build {object VERSION {@JvmField val SDK_INT=0}}
''')
 for name in ['SourceArtworkRead.kt','CaaArtworkRead.kt']:copy(main/'data/discovery'/name)
 for name in ['CaaArtworkReadTest.kt','DiscoverArtworkReadTest.kt']:copy(test/'data'/name)
 classes+=['com.soundq.android.data.CaaArtworkReadTest','com.soundq.android.data.DiscoverArtworkReadTest']
 api=(main/'data/SoundQApi.kt').read_text();start=api.index('        fun safeMediaUrl(value: String)')
 policy=api[start:api.index('\n    }\n}',start)]
 emit('MediaPolicy.kt','''package com.soundq.android.data
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import kotlinx.serialization.json.*
import com.soundq.android.data.discovery.*
class LibraryCollection
class SoundQApi(val session:AccountSession,val client:OkHttpClient) {
 // Host-only authorized transport boundary; the releaseRadar method below is unmodified production.
 private fun authorized(scope:AccountScope,path:String,valid:()->Boolean,expectedStatus:Int,headers:Map<String,String>):JsonObject {
  check(session.remoteCurrent(scope)&&valid())
  val req=Request.Builder().url(session.endpoint.identity+path).header("Authorization","Bearer "+session.access(scope))
  headers.forEach {(k,v)->req.header(k,v)}
  return client.newCall(req.build()).execute().use {response->check(response.code==expectedStatus&&session.remoteCurrent(scope)&&valid());Json.parseToJsonElement(response.body.string()).jsonObject}
 }
'''+api[api.index('    fun releaseRadar('):api.index('    fun radarMembership(')]+'''
 fun radarMembership(scope:AccountScope,id:com.soundq.android.data.catalog.RecordingMbid,valid:()->Boolean):Boolean=error("unrelated membership boundary")
 fun discoverySearch(scope:AccountScope,q:String,valid:()->Boolean,grouped:Boolean):SourceResults=error("unrelated search boundary")
 fun resolveSource(scope:AccountScope,s:com.soundq.android.data.imports.ImportSource,valid:()->Boolean):SourceResults=error("unrelated resolve boundary")
 companion object {
'''+policy+'\n}\n}\n')
 for name in ['data/Contracts.kt','data/AccountSession.kt','data/discovery/Discovery.kt','data/discovery/DiscoveryRepository.kt','data/discovery/DiscoveryHistory.kt','data/imports/Imports.kt']:copy(main/name)
 (out/'OwnerBoundary.kt').unlink();(out/'FailureBoundary.kt').unlink()
 scope=(test/'data/ScopeRaceTest.kt').read_text();start=scope.index('internal class HttpsFixture');end=scope.index('\nclass ',start)
 emit('HttpsFixture.kt','package com.soundq.android.data\nimport okhttp3.*\nimport okhttp3.tls.*\nimport mockwebserver3.*\n'+scope[start:end])
dependency_manifest=[];private_jars=[]
(out/'dependencies').mkdir()
for dependency in jars:
 target=out/'dependencies'/dependency.name;shutil.copyfile(dependency,target)
 digest=hashlib.sha256(target.read_bytes()).hexdigest();assert digest==hashlib.sha256(dependency.read_bytes()).hexdigest()
 dependency_manifest.append({'origin':str(dependency),'private':str(target),'sha256':digest});private_jars.append(target)
(out/'dependencies.json').write_text(json.dumps(dependency_manifest,indent=2))
cp=os.pathsep.join(map(str,private_jars))
if not a.metadata_only:
 store=main/'product/discovery/RadarArtwork.kt'
 inputs[str(store.relative_to(r))]=hashlib.sha256(store.read_bytes()).hexdigest()
 text=store.read_text();body=text[text.index('/** Memory-only'):text.index('private val radarArtworkPool=')]
 copy(store)
 emit('ComposeBoundary.kt','''package androidx.compose.runtime
import kotlinx.coroutines.flow.StateFlow
import kotlin.reflect.KProperty
@Target(AnnotationTarget.FUNCTION,AnnotationTarget.TYPE) annotation class Composable
class MutableState<T>(var value:T)
operator fun <T> MutableState<T>.getValue(owner:Any?,property:KProperty<*>):T=value
operator fun <T> MutableState<T>.setValue(owner:Any?,property:KProperty<*>,v:T){value=v}
fun <T> mutableStateOf(value:T)=MutableState(value)
fun <T> StateFlow<T>.collectAsState()=MutableState(value)
object HostComposition {
 data class Cell(val keys:List<Any?>,val value:Any?)
 var index=0;val cells=mutableMapOf<Int,Cell>();val effects=mutableMapOf<Int,Pair<List<Any?>,()->Unit>>()
 val pending=mutableListOf<()->Unit>()
 fun render(body:()->Unit){index=0;body();pending.toList().also {pending.clear()}.forEach {it()}}
 fun dispose(){effects.values.toList().forEach {it.second()};effects.clear();cells.clear();pending.clear()}
}
fun <T> remember(vararg keys:Any?,block:()->T):T {
 val n=HostComposition.index++;val old=HostComposition.cells[n]
 if(old!=null&&old.keys==keys.toList()){@Suppress("UNCHECKED_CAST") return old.value as T}
 return block().also {HostComposition.cells[n]=HostComposition.Cell(keys.toList(),it)}
}
class DisposeScope {fun onDispose(body:()->Unit)=body}
fun DisposableEffect(vararg keys:Any?,body:DisposeScope.()->(()->Unit)) {
 val n=HostComposition.index++;val old=HostComposition.effects[n]
 if(old!=null&&old.first==keys.toList())return
 HostComposition.pending.add {old?.second?.invoke();HostComposition.effects[n]=keys.toList() to DisposeScope().body()}
}
fun LaunchedEffect(vararg keys:Any?,body:()->Unit) {
 val n=HostComposition.index++;val old=HostComposition.cells[n]
 if(old!=null&&old.keys==keys.toList())return
 HostComposition.cells[n]=HostComposition.Cell(keys.toList(),null);HostComposition.pending.add(body)
}
''')
 emit('LifecycleBoundary.kt','''package androidx.lifecycle
class Lifecycle {
 enum class State {CREATED,STARTED,RESUMED;fun isAtLeast(other:State)=ordinal>=other.ordinal}
 var currentState=State.RESUMED
 private val observers=mutableListOf<LifecycleEventObserver>()
 fun addObserver(o:LifecycleEventObserver){observers.add(o)}
 fun removeObserver(o:LifecycleEventObserver){observers.remove(o)}
 fun dispatch(state:State){currentState=state;observers.toList().forEach {it.event(Unit,Unit)}}
}
fun interface LifecycleEventObserver {fun event(owner:Any,event:Any)}
class LifecycleOwner {val lifecycle=Lifecycle()}
''')
 emit('LocalLifecycleBoundary.kt','''package androidx.lifecycle.compose
object LocalLifecycleOwner {var current=androidx.lifecycle.LifecycleOwner()}
''')
 emit('DpBoundary.kt','''package androidx.compose.ui.unit
class Dp(val value:Int)
val Int.dp get()=Dp(this)
''')
 emit('PaintBinding.kt','''package com.soundq.android.product.artwork
import android.graphics.Bitmap
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.atomic.AtomicBoolean
import androidx.compose.ui.unit.Dp
object PaintBinding {var bitmap:()->Bitmap?={null}}
fun ArtworkPaint(state:StateFlow<Bitmap?>,bitmap:()->Bitmap?,mounted:AtomicBoolean,size:Dp){PaintBinding.bitmap={if(mounted.get())bitmap()else null}}
''')
 admission=main/'product/discovery/DiscoveryArtwork.kt';inputs[str(admission.relative_to(r))]=hashlib.sha256(admission.read_bytes()).hexdigest()
 emit('Admission.kt','package com.soundq.android.product.discovery\nimport kotlinx.coroutines.sync.Semaphore\n'+next(x for x in admission.read_text().splitlines() if x.startswith('internal val discoveryArtworkWorkers=')))
 decode=main/'product/artwork/LibraryArtwork.kt';inputs[str(decode.relative_to(r))]=hashlib.sha256(decode.read_bytes()).hexdigest()
 emit('Decode.kt','package com.soundq.android.product.artwork\nimport android.graphics.*\nobject LibraryArtwork {const val MAX_BYTES=4_000_000}\n'+decode.read_text().split('internal fun decodeArtwork(',1)[1].join(['internal fun decodeArtwork(','']))
 emit('Bitmap.kt','''package android.graphics
// Explicit host-only bounds/sample facade, not Android BitmapFactory or raster.
class Bitmap(val width:Int,val height:Int,val allocationByteCount:Int=width*height*4){enum class Config {ARGB_8888}}
object BitmapFactory {
 class Options {var inJustDecodeBounds=false;var outWidth=0;var outHeight=0;var inSampleSize=1;var inPreferredConfig:Bitmap.Config?=null}
 fun decodeByteArray(data:ByteArray,offset:Int,length:Int,o:Options):Bitmap? {
  javax.imageio.ImageIO.createImageInputStream(java.io.ByteArrayInputStream(data,offset,length)).use {input->
   val readers=javax.imageio.ImageIO.getImageReaders(input);if(!readers.hasNext())return null
   val reader=readers.next()
   try {reader.input=input;o.outWidth=reader.getWidth(0);o.outHeight=reader.getHeight(0)
    return if(o.inJustDecodeBounds)null else Bitmap(((o.outWidth.toLong()+o.inSampleSize-1)/o.inSampleSize).toInt(),((o.outHeight.toLong()+o.inSampleSize-1)/o.inSampleSize).toInt())
   }finally {reader.dispose()}
  }
 }
}
''')
 paint=main/'product/artwork/TrackArtwork.kt';inputs[str(paint.relative_to(r))]=hashlib.sha256(paint.read_bytes()).hexdigest()
 text=paint.read_text();start=text.index('{',text.index('Canvas(Modifier.fillMaxSize())'));end=start+1;depth=1
 while depth:
  depth+=(text[end]=='{')-(text[end]=='}');end+=1
 emit('DrawBoundary.kt','''package com.soundq.android.product.discovery
import android.graphics.Bitmap
import java.util.concurrent.atomic.AtomicBoolean
class IntOffset(val x:Int,val y:Int)
class IntSize(val width:Int,val height:Int)
class DrawSize(val width:Float,val height:Float)
fun Bitmap.asImageBitmap()=this
class DrawBoundary {
 val size=DrawSize(72f,72f);val background=0;var images=0
 fun drawRect(color:Int){}
 fun drawImage(image:Bitmap,srcOffset:IntOffset,srcSize:IntSize,dstSize:IntSize){images++}
 fun paint(pixels:Bitmap?,bitmap:()->Bitmap?) {val mounted=AtomicBoolean(true)
'''+text[start+1:end-1]+'\n}\n}\n')
 copy(r/'scripts/radar-artwork-tests/RadarArtworkPoolTest.kt');classes+=['com.soundq.android.product.discovery.RadarArtworkPoolTest']
 copy(r/'scripts/radar-artwork-tests/RadarAcceptedArtworkTest.kt');classes+=['com.soundq.android.product.discovery.RadarAcceptedArtworkTest']
if a.mutation:
 mutations={
  'no-redirects':('CaaArtworkRead.kt','val redirect=response.code in setOf(301,302,303,307,308)','val redirect=false'),
  'revive-owner':('RadarArtwork.kt','if(alive&&(key==null||!valid()))close()','if(alive&&key==null)close()'),
  'stale-publication':('RadarArtwork.kt','if(valid()) {retain(key,image);','if(true) {retain(key,image);'),
  'free-running-job':('RadarArtwork.kt','fun cancel() {closed=true;','fun cancel() {jobs.remove(this);closed=true;'),
  'unchecked-draw':('DrawBoundary.kt','bitmap()?.let {image->','pixels?.let {image->'),
 }
 name,old,new=mutations[a.mutation];target=out/name;text=target.read_text();assert text.count(old)==1
 target.write_text(text.replace(old,new));(out/'mutation.json').write_text(json.dumps({'name':a.mutation,'file':name,'old':old,'new':new},indent=2))
for path in [Path(__file__),main/'data/SoundQApi.kt',test/'data/ScopeRaceTest.kt',r/'app/src/test/resources/release-radar-wire.json']:
 inputs[str(path.relative_to(r))]=hashlib.sha256(path.read_bytes()).hexdigest()
emit('Runner.kt','''import org.junit.runner.*
import org.junit.runner.notification.*
import org.junit.internal.TextListener
import kotlinx.serialization.json.*
fun main(args:Array<String>) {
 val events=mutableListOf<JsonObject>();val failed=mutableSetOf<Description>();val core=JUnitCore()
 core.addListener(TextListener(System.out))
 core.addListener(object:RunListener(){
  override fun testFailure(f:Failure){failed.add(f.description)}
  override fun testFinished(d:Description){events.add(buildJsonObject {put("class",d.className);put("method",d.methodName);put("passed",d !in failed)})}
 })
 val result=core.run(*args.map {Class.forName(it)}.toTypedArray())
 java.io.File(System.getProperty("soundq.radar.results")).writeText(buildJsonObject {put("executed",result.runCount);put("failures",result.failureCount);put("ignored",result.ignoreCount);put("cases",JsonArray(events))}.toString())
 kotlin.system.exitProcess(if(result.wasSuccessful())0 else 1)
}
''')
(out/'generated-inputs.json').write_text(json.dumps({x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in out.glob('*.kt')},indent=2))
env=dict(os.environ,TMPDIR=str(out),JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2 -Xmx512m')
commands=[['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=2',*[str(x) for x in out.glob('*.kt')],'-cp',cp,'-include-runtime','-d',str(out/'tests.jar')],['java','-Xmx512m','-XX:ActiveProcessorCount=2','-Djava.io.tmpdir='+str(out),'-Dsoundq.radar.wire='+str(r/'app/src/test/resources/release-radar-wire.json'),'-Dsoundq.radar.results='+str(out/'results.json'),'-cp',str(out/'tests.jar')+os.pathsep+cp,'RunnerKt',*classes]]
(out/'inputs.json').write_text(json.dumps(inputs,indent=2));(out/'commands.json').write_text(json.dumps(commands,indent=2))
for name,cmd in zip(['compile','test'],commands):
 result=subprocess.run(cmd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 (out/(name+'.log')).write_text(result.stdout);print(result.stdout,end='')
 if result.returncode:raise SystemExit(result.returncode)
