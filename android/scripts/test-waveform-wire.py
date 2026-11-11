#!/usr/bin/env python3
"""No Gradle/network/account: exact canonical wire via real OkHttp loopback.

The retained six-minute bytes were emitted by the integrated Go producer probe,
with synthetic PCM and declared six-decimal MIR inputs. Not recorded user audio.
Tests copy the production wire/client verbatim; only AccountSession is a facade.
"""
from pathlib import Path
import argparse, gzip, subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--api',type=Path)
p.add_argument('--okhttp-jar',type=Path,required=True,help='OkHttp 5.5.1 JVM jar (Android runtime variant cannot run on host)')
a=p.parse_args()
r=Path(__file__).resolve().parents[1]; out=a.output;out.mkdir(parents=True,exist_ok=True)
s=(a.api or r/'app/src/main/kotlin/com/soundq/android/data/SoundQApi.kt').read_text()
client=s[s.index('    private class WireGuard'):s.index('    private val json')]
wire=s[s.index('    private class Reply'):s.index('    fun authenticate')]
fixture=r/'app/src/test/resources/waveform/producer-six-minute.json.gz'
raw=gzip.decompress(fixture.read_bytes());assert len(raw)==2_400_029
(out/'producer-six-minute.json').write_bytes(raw)
(out/'WireTest.kt').write_text('''package probe
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.serialization.json.*
import java.util.concurrent.TimeUnit
import java.io.File
import com.sun.net.httpserver.HttpServer
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.AnalysisWaveformJson
import java.net.InetSocketAddress
class SafeFailure(val reason:Reason):RuntimeException(reason.name) {enum class Reason {Retired,Endpoint,InvalidResponse,Network,Uncertain}}
class Endpoint(val base:HttpUrl) {val identity=base.toString().removeSuffix("/")}
class AccountSession(val endpoint:Endpoint)
class Probe(val session:AccountSession,client:OkHttpClient=OkHttpClient()) {
CLIENT
    private val json=Json {ignoreUnknownKeys=true}
WIRE
    fun consume(path:String,method:String="GET",valid:()->Boolean={true})=wire(path,method,access="synthetic",valid=valid).body
}
fun main(args:Array<String>) {
 var calls=0;var body=byteArrayOf();var status=200;var responseHook:()->Unit={}
 val server=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
 server.createContext("/") { x ->
  calls++;check(x.requestHeaders.getFirst("Authorization")=="Bearer synthetic")
  responseHook();x.sendResponseHeaders(status,body.size.toLong());x.responseBody.use {it.write(body)}
 }
 server.start()
 try {
  val api=Probe(AccountSession(Endpoint(("http://127.0.0.1:${server.address.port}/api/v1").toHttpUrlOrNull()!!)))
  fun padded(n:Int)=("{}"+" ".repeat(n-2)).toByteArray()
  fun refused(path:String,reason:SafeFailure.Reason,method:String="GET",valid:()->Boolean={true}) {
   val failure=runCatching {api.consume(path,method,valid)}.exceptionOrNull()
   check(failure is SafeFailure&&failure.reason==reason) {"Expected $reason for $path; got $failure"}
  }
  body=padded(2_000_000);check(api.consume("/library").isEmpty())
  body=padded(2_000_001);refused("/library",SafeFailure.Reason.InvalidResponse)
  val previous=calls;refused("/tracks/7/analysis",SafeFailure.Reason.Retired,valid={false});check(calls==previous)
  check(runCatching {api.consume("/../outside")}.exceptionOrNull() is IllegalArgumentException)
  body=File(args[0]).readBytes()
  val result=runCatching {api.consume("/tracks/7/analysis")}
  check(result.isSuccess) {"Valid exact-producer ${body.size}-byte analysis rejected: ${result.exceptionOrNull()}"}
  check(result.getOrThrow().containsKey("artifacts"))
  val wave=AnalysisWaveformJson.parse(result.getOrThrow(),TrackId(7),360000)
  check(wave.tiers.isNotEmpty()&&wave.tiers.any {it.spectral!=null})
  println("PASS production parser after canonical wire: ${wave.tiers.map {it.name to it.minima.size}} signed RGB tiers")
  println("PASS exact producer six-minute analysis: ${body.size} bytes via authenticated canonical wire")
  for(path in listOf("/library","/tracks/7/analysis?other=1","/tracks/0/analysis","/tracks/7/analysis/overrides"))refused(path,SafeFailure.Reason.InvalidResponse)
  refused("/tracks/7/analysis",SafeFailure.Reason.InvalidResponse,method="POST")
  body=padded(16*1024*1024);check(api.consume("/tracks/7/analysis").isEmpty())
  body=padded(16*1024*1024+1);refused("/tracks/7/analysis",SafeFailure.Reason.InvalidResponse)
  body="{}".toByteArray();var live=true;responseHook={live=false}
  refused("/tracks/7/analysis",SafeFailure.Reason.Retired,valid={live})
  responseHook={};status=302;refused("/tracks/7/analysis",SafeFailure.Reason.Endpoint)
  println("PASS generic 2MB, analysis 16MiB exact/+1, route/method scope, auth, dispatch/publication retirement and redirect guards")
 }finally {server.stop(0)}
}
'''.replace('CLIENT',client).replace('WIRE',wire))
cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
def jar(group,name,version):return next((cache/group/name/version).glob('*/*.jar'))
okhttp=a.okhttp_jar
cp=':'.join(map(str,[okhttp,jar('com.squareup.okio','okio-jvm','3.18.1'),jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.7.3'),jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.7.3')]))
(out/'IdentityFacade.kt').write_text('package com.soundq.android.data\n@JvmInline value class TrackId(val value:Long)\n')
data=r/'app/src/main/kotlin/com/soundq/android/data/timeline'
parsers=[data/n for n in ['Timeline.kt','TimelineOwner.kt','Waveform.kt','LinkedPhase.kt','TimelineGeometry.kt','TempoTransition.kt']]
cp+=':'+str(jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.1'))
(out/'ExchangeFacade.kt').write_text('package com.soundq.android.data.mix\nclass ExchangeRefusal {enum class Code { conflict }}\n')
for cmd in [['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',str(out/'WireTest.kt'),str(out/'ExchangeFacade.kt'),str(out/'IdentityFacade.kt'),*map(str,parsers),'-cp',cp,'-include-runtime','-d',str(out/'wire.jar')],['java','-XX:ActiveProcessorCount=1','-cp',str(out/'wire.jar')+':'+cp,'probe.WireTestKt',str(out/'producer-six-minute.json')]]:
 result=subprocess.run(cmd,capture_output=True,text=True);print(result.stdout+result.stderr)
 if result.returncode:raise SystemExit(result.returncode)
